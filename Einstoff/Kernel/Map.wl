(* ::Package:: *)

(* Map path: Einstoff[Map] / EinstoffMap (einx miscellaneous / shape-preserving
   elementary ops — https://einx.readthedocs.io/en/stable/api/operations/misc.html:
   flip, roll, sort, softmax, log_softmax, id).  The kept-target sibling of
   Einstoff[ArrayReduce]: a *reduction* drops the targeted axes (f: block ->
   scalar); a *map* keeps them (f: block -> same-length block), vmapping the op
   over every untargeted axis.  einx has no generic vmap entry point — each named
   op carries its own targeted signature — so this is the single generic operator
   that realizes all of them, with f supplied (curried) by the caller.

   Einstoff[Map][f][desc, tensors, bindings].  f receives the targeted axes as
   one rectangular Wolfram block, preserving nested list structure, and must return
   a same-shape block.  Examples:
     Einstoff[Map]["flip"]     reverse along the target   (einx.flip)
     Einstoff[Map]["sort"]     sort along the target       (einx.sort)
     Einstoff[Map]["softmax"]  softmax along the target    (einx.softmax)
     Einstoff[Map][RotateLeft[#, 2] &]   roll               (einx.roll; the shift
       is a parameter, so roll is expressed as a function rather than a name).

   As with the reducer (and for the same reason — a hold attribute cannot survive
   the compound head EinstoffMap[f][…]), desc is NOT held; that is the uniform
   convention (a globally bound axis symbol substitutes, a bound integer reads as a
   literal dimension, illegal values are rejected by the matcher).

   Shared shape helpers (descParts, distinctAxesQ) live in ShapeChecker.wl; atom and
   materialization helpers live in Lowering.wl. *)

PackageExported[{EinstoffMap}]

EinstoffMap::usage =
  "EinstoffMap[f][desc, tensors, bindings] realizes a shape-preserving \
elementary op (einx flip/roll/sort/softmax/log_softmax, einx.misc): the \
targeted axes are fed to f as one rectangular block and f returns a \
same-shape block, while every untargeted axis is vmapped.  f may be a \
function (Reverse, Sort, a custom block map) or a name \
(\"flip\"/\"sort\"/\"softmax\"/\"log_softmax\"/\"id\").  The targeted axes are \
kept on the output; dropping an axis is a reduction (use Einstoff[ArrayReduce]).";

Einstoff[Map] := EinstoffMap;
Einstoff["Map"] := EinstoffMap;

Options[EinstoffMap] = {TraceAction -> None};

mapSoftmaxBlock[x_] :=
  Module[{v = Flatten[x], y},
    y = Exp[v - Max[v]];
    ArrayReshape[y/Total[y], Dimensions[x]]];

mapLogSoftmaxBlock[x_] :=
  Module[{v = Flatten[x], y},
    y = (v - Max[v]) - Log[Total[Exp[v - Max[v]]]];
    ArrayReshape[y, Dimensions[x]]];

(* Resolve a map spec to a target-block -> same-shape block function.  A raw function is used as-is;
   a convenience string is matched case-insensitively to the einx misc op of that
   name.  softmax/log_softmax use the max-shift stable form.  roll is omitted (its
   shift is a parameter — pass RotateLeft[#, k]& directly). *)
mapFunction[s_String] := Replace[ToLowerCase[s], {
  "id" | "identity" -> Identity,
  "flip" | "reverse" -> Reverse,
  "sort" -> Sort,
  "softmax" -> mapSoftmaxBlock,
  "log_softmax" | "logsoftmax" -> mapLogSoftmaxBlock,
  (* An unknown string is a typo, not a function: flag it so the caller rejects it. *)
  _ :> Missing["UnknownMapOp", s]}];
mapFunction[f_] := f;

(* Curried: Einstoff[Map][f] is the operator, applied to [desc, tensors, bindings].
   A subvalue of EinstoffMap, exactly as EinstoffReduce[reducer][…]. *)
EinstoffMap[fSpec_][desc_, tensors_, bindings_List : {},
    opts : OptionsPattern[EinstoffMap]] := withAxisScope @
  Module[{parts, lhs, rhs, inShapes, m, env, f, x, decomp, rhsTerms,
          lhsTagged, lhsAtoms, lhsBr, rhsAtoms, brAtoms, vmapAtoms,
          decompDims, order, srcPerm, xr, vmapDims, brDims,
          mapped, recombined, result, traceAction, h},
    traceAction = OptionValue[EinstoffMap, {opts}, TraceAction];
    parts = descParts[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    {lhs, rhs} = parts;
    If[! MatchQ[tensors, {__}],
      Message[Einstoff::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[Einstoff::unsupp,
        "Map lowering supports exactly one input and one output tensor"];
      Return[$Failed]];

    f = mapFunction[fSpec];
    If[MissingQ[f],
      Message[Einstoff::unsupp,
        "unknown map op name \"" <> ToString[fSpec] <> "\"; use one of \
flip/sort/softmax/log_softmax/id, or pass a function"];
      Return[$Failed]];

    If[Cases[lhs, t_ /; bracketWrapperQ[t] && ! FreeQ[t, CirclePlus], {0, Infinity}] =!= {},
      Message[Einstoff::unsupp,
        "Einstoff[Map] does not map over a targeted direct sum (CirclePlus); use \
Einstoff[Join]/[Split] structurally, then map the resulting tensor(s)"];
      Return[$Failed]];

    (* A name repeated within an input shape is within-tensor contraction (Massage/
       Contract/einsum only); the resolver no longer rejects it, so guard here before the
       layout builds an invalid permutation (InversePermutation on a duplicated index). *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> axisDisplayName[firstDuplicateAxis[lhs]] <> " repeats within an input \
shape; Map is shape-preserving and does not contract. Within-tensor contraction is \
Einstoff[\"ArrayContract\"] / Einstoff[\"einsum\"]"];
      Return[$Failed]];

    inShapes = Dimensions /@ tensors;
    m = EinstoffMatch[lhs, inShapes, bindings];
    If[! TrueQ[m["ok"]],
      Message[Einstoff::unsat, m["reason"]]; Return[$Failed]];
    env = m["env"];

    (* Decompose: LHS bracket-aware (tagged), RHS plain (reuse rearrangeAtoms). *)
    decomp = einCatch[targetDecomposeTerms[First[lhs], First[inShapes], env]];
    If[decomp === $Failed,
      Message[Einstoff::unsat, "an input axis size is unbound or inconsistent"];
      Return[$Failed]];
    lhsTagged = decomp["Tagged"]; env = decomp["Env"];
    If[plainSequenceCount[First[rhs]] > 0 && plainSequenceCount[First[lhs]] == 0,
      Message[Einstoff::unsupp,
        "a plain anonymous sequence (__ / ___) on the output needs a corresponding \
plain sequence in the input shape"];
      Return[$Failed]];
    rhsTerms = einCatch[expandAnonymousTargetRhs[First[rhs], decomp["AnonymousTargetAtoms"]]];
    If[rhsTerms === $Failed, Return[$Failed]];
    If[lhsTagged === $Failed, Return[$Failed]];
    rhsAtoms = einCatch[Join @@ Table[rearrangeAtoms[t], {t, rhsTerms}]];
    If[rhsAtoms === $Failed, Return[$Failed]];
    lhsAtoms = lhsTagged[[All, 1]]; lhsBr = lhsTagged[[All, 2]];
    brAtoms = Pick[lhsAtoms, lhsBr];
    vmapAtoms = Pick[lhsAtoms, lhsBr, False];

    (* Map acts *along* a targeted axis (the op signature); with no target the
       desc is a pure rearrange. *)
    If[brAtoms === {},
      Message[Einstoff::unsupp,
        "Einstoff[Map] needs a targeted axis (the op acts along it); a desc with \
no target is a pure rearrange; use Einstoff[ArrayReshape]"];
      Return[$Failed]];

    (* Map preserves every axis (keeps the target, vmaps the rest); RHS-only axes are
       repetition.  A dropped input axis of size > 1 is a reduction (not map); a dropped
       size-1 (unit) axis carries no data and is squeezed by materializeOutput (einx
       allows e.g. 'a () [b] -> a [b]'), so the guard is size-aware, like Massage/Dot. *)
    If[AnyTrue[lhsAtoms, ! MemberQ[rhsAtoms, #] && atomSize[#, env] > 1 &],
      Message[Einstoff::unsupp,
        "an input axis of size > 1 is dropped on the output; dropping a size > 1 axis \
is a reduction, use Einstoff[ArrayReduce] (a size-1 unit axis is squeezed)"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = einCatch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[Einstoff::unsat, "an input axis size is unbound"];
      Return[$Failed]];
    xr = ArrayReshape[x, decompDims];

    (* Permute so the vmapped (untargeted) atoms lead and the targeted atoms trail.
       f is applied once to each targeted rectangular block. *)
    order = Join[vmapAtoms, brAtoms];
    srcPerm = Flatten[FirstPosition[lhsAtoms, #] & /@ order];
    If[Length[srcPerm] > 1, xr = Transpose[xr, InversePermutation[srcPerm]]];
    vmapDims = atomSize[#, env] & /@ vmapAtoms;
    brDims = atomSize[#, env] & /@ brAtoms;
    mapped = If[vmapAtoms === {}, f[xr], Map[f, xr, {Length[vmapAtoms]}]];

    (* f must be shape-preserving on each targeted rectangular block. *)
    If[Dimensions[mapped] =!= Join[vmapDims, brDims],
      Message[Einstoff::unsupp,
        "the map function did not return the same target block shape \
(Einstoff[Map] needs a shape-preserving op; to collapse the axis use \
Einstoff[ArrayReduce])"];
      Return[$Failed]];

    recombined = mapped;
    If[traceActionEnabledQ[traceAction],
      h = heldReshape[heldValue[x], decompDims];
      If[Length[srcPerm] > 1, h = heldTranspose[h, InversePermutation[srcPerm]]];
      h = If[vmapAtoms === {}, heldApply[h, f], heldMapAt[h, f, Length[vmapAtoms]]];
      result = einCatch[
        traceReturnHeld[
          materializeOutputExprHeld[h, order, rhsTerms, env],
          traceAction]];
      If[result === $Failed,
        Message[Einstoff::unsat,
          "an output axis size is unbound (a repeated axis needs a binding)"];
        Return[$Failed]];
      Return[result]];
    (* order is recombined's atom order; materialize repeats, permute to RHS, recompose. *)
    With[{recombined0 = recombined, order0 = order, rhs0 = rhsTerms, env0 = env},
      result = einCatch[
        materializeOutputTrace[recombined0, order0, rhs0, env0, traceAction]]];
    If[result === $Failed,
      Message[Einstoff::unsat,
        "an output axis size is unbound (a repeated axis needs a binding)"];
      Return[$Failed]];
    result
  ];
