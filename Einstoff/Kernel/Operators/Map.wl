(* ::Package:: *)

(* Map / Operate path.  Einstoff[Operate] is the shape-preserving targeted-block
   operation path for einx miscellaneous ops (flip, roll, sort, softmax,
   log_softmax, id): targeted axes are passed to f as one rectangular block, and
   f must return the same block shape.  Einstoff[Map] is the broader blockwise
   transform: the same target/vmap layout is used, but f may change the target
   block shape and the final result is validated against the RHS.

   Examples:
     Einstoff[Operate]["flip"]     reverse along the target   (einx.flip)
     Einstoff[Operate]["sort"]     sort along the target       (einx.sort)
     Einstoff[Operate]["softmax"]  softmax along the target    (einx.softmax)
     Einstoff[Operate][RotateLeft[#, 2] &]   roll              (einx.roll; the shift
       is a parameter, so roll is expressed as a function rather than a name).

   As with the reducer (and for the same reason — a hold attribute cannot survive
   the compound head EinstoffMap[f][…]), desc is NOT held; that is the uniform
   convention (a globally bound axis symbol substitutes, a bound integer reads as a
   literal dimension, illegal values are rejected by the matcher).

   Shared shape helpers (descParts, distinctAxesQ) live in ShapeChecker.wl; atom and
   materialization helpers live in Lowering.wl. *)

PackageExported[{EinstoffMap, EinstoffOperate}]

EinstoffMap::usage =
  "EinstoffMap[f][desc, tensors, bindings] realizes a blockwise transform of \
one tensor: targeted axes are fed to f as one rectangular block, every untargeted \
axis is vmapped, and the result is checked against the RHS shape. If there are no \
targets, f is mapped over scalar blocks.";

EinstoffOperate::usage =
  "EinstoffOperate[f][desc, tensors, bindings] realizes a shape-preserving \
targeted-block op (einx flip/roll/sort/softmax/log_softmax, einx.misc): the \
targeted axes are fed to f as one rectangular block and f must return the same \
block shape, while every untargeted axis is vmapped.";

Einstoff[Map] := EinstoffMap;
Einstoff["Map"] := EinstoffMap;
Einstoff[Operate] := EinstoffOperate;
Einstoff["Operate"] := EinstoffOperate;

Options[EinstoffMap] = {TraceAction -> None};
Options[EinstoffOperate] = {TraceAction -> None};

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

rhsProducedTerms[terms_List, vmapAtoms_, blockDims_, env_] :=
  Module[{env2 = env, produced, q, replace, rhsAtoms, nonVmap},
    rhsAtoms = Join @@ Table[rearrangeAtoms[t], {t, terms}];
    nonVmap = Select[rhsAtoms, ! MemberQ[vmapAtoms, #] &];
    If[Length[nonVmap] < Length[blockDims],
      Message[Einstoff::unsupp,
        "the map function returned more block axes than the RHS can receive"];
      Throw[$Failed, einThrowTag]];
    If[! And @@ Table[atomSize[nonVmap[[i]], env2] === blockDims[[i]],
        {i, Length[blockDims]}],
      Message[Einstoff::unsat,
        "the map function returned block dimensions that do not match the RHS"];
      Throw[$Failed, einThrowTag]];
    produced = Table[Unique["map$", {Temporary}], {Length[blockDims]}];
    Do[env2 = Append[env2, produced[[i]] -> blockDims[[i]]],
      {i, Length[blockDims]}];
    q = produced;
    replace[t_] := Which[
      MatchQ[t, Verbatim[Pattern][_Symbol, Verbatim[Blank[]]]],
        If[MemberQ[vmapAtoms, t[[1]]] || q === {}, t,
          With[{a = First[q]}, q = Rest[q]; a]],
      Head[t] === Symbol,
        If[MemberQ[vmapAtoms, t] || q === {}, t,
          With[{a = First[q]}, q = Rest[q]; a]],
      IntegerQ[t],
        If[MemberQ[vmapAtoms, t] || q === {}, t,
          With[{a = First[q]}, q = Rest[q]; a]],
      t === {},
        If[MemberQ[vmapAtoms, 1] || q === {}, t,
          With[{a = First[q]}, q = Rest[q]; a]],
      Head[t] === CircleTimes,
        CircleTimes @@ (replace /@ (List @@ t)),
      bracketWrapperQ[t],
        Head[t] @@ (replace /@ (List @@ t)),
      True, t];
    {replace /@ terms, env2, produced}];

mapLegacyCore[fSpec_, desc_, tensors_, bindings_List, traceAction_, strictQ_] :=
  withAxisScope @
  Module[{parts, lhs, rhs, inShapes, m, env, f, x, decomp, rhsTerms,
          lhsTagged, lhsAtoms, lhsBr, rhsAtoms, brAtoms, vmapAtoms,
          decompDims, order, srcPerm, xr, vmapDims, brDims,
          mapped, recombined, result, h, mappedDims, blockDims, produced,
          producedTerms, producedEnv, producedAtoms},
    parts = descParts[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    {lhs, rhs} = parts;
    If[! MatchQ[tensors, {__}],
      Message[Einstoff::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[Einstoff::unsupp,
        If[strictQ, "Operate", "Map"] <>
          " lowering supports exactly one input and one output tensor"];
      Return[$Failed]];

    f = mapFunction[fSpec];
    If[MissingQ[f],
      Message[Einstoff::unsupp,
        "unknown map op name \"" <> ToString[fSpec] <> "\"; use one of \
flip/sort/softmax/log_softmax/id, or pass a function"];
      Return[$Failed]];

    If[Cases[lhs, t_ /; bracketWrapperQ[t] && ! FreeQ[t, CirclePlus], {0, Infinity}] =!= {},
      Message[Einstoff::unsupp,
        "Einstoff[" <> If[strictQ, "Operate", "Map"] <>
          "] does not map over a targeted direct sum (CirclePlus); use \
Einstoff[Join]/[Split] structurally, then map the resulting tensor(s)"];
      Return[$Failed]];

    (* A name repeated within an input shape is within-tensor contraction (Massage/
       Contract/einsum only); the resolver no longer rejects it, so guard here before the
       layout builds an invalid permutation (InversePermutation on a duplicated index). *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> axisDisplayName[firstDuplicateAxis[lhs]] <> " repeats within an input \
shape; Map/Operate does not contract. Within-tensor contraction is \
Einstoff[\"ArrayContract\"] / Einstoff[\"einsum\"]"];
      Return[$Failed]];

    inShapes = Dimensions /@ tensors;
    m = EinstoffMatch[lhs, inShapes, bindings];
    If[! TrueQ[m["ok"]],
      Message[Einstoff::unsat, m["reason"]]; Return[$Failed]];
    env = m["env"];

    (* Decompose: LHS bracket-aware (tagged), RHS plain (reuse rearrangeAtoms). *)
    decomp = einCatch[
      targetDecomposeTerms[First[lhs], First[inShapes], env,
        Lookup[m, "seq", <||>]]];
    If[decomp === $Failed,
      Message[Einstoff::unsat, "an input axis size is unbound or inconsistent"];
      Return[$Failed]];
    lhsTagged = decomp["Tagged"]; env = decomp["Env"];
    If[plainSequenceCount[First[rhs]] > 0 && plainSequenceCount[First[lhs]] == 0,
      Message[Einstoff::unsupp,
        "a plain anonymous sequence (__ / ___) on the output needs a corresponding \
plain sequence in the input shape"];
      Return[$Failed]];
    rhsTerms = einCatch[
      expandAnonymousTargetRhs[First[rhs], decomp["AnonymousTargetAtoms"],
        decomp["NamedSequenceAtoms"]]];
    If[rhsTerms === $Failed, Return[$Failed]];
    If[lhsTagged === $Failed, Return[$Failed]];
    rhsAtoms = einCatch[Join @@ Table[rearrangeAtoms[t], {t, rhsTerms}]];
    If[rhsAtoms === $Failed, Return[$Failed]];
    lhsAtoms = lhsTagged[[All, 1]]; lhsBr = lhsTagged[[All, 2]];
    brAtoms = Pick[lhsAtoms, lhsBr];
    vmapAtoms = Pick[lhsAtoms, lhsBr, False];

    (* Operate is explicitly the targeted-block, shape-preserving path.  Generalized
       Map follows einx's no-bracket misc-op behavior: no targets means scalar blocks
       and every input axis is vmapped. *)
    If[strictQ && brAtoms === {},
      Message[Einstoff::unsupp,
        "Einstoff[Operate] needs a targeted axis (the op acts along it); a desc with \
no target is a pure rearrange; use Einstoff[ArrayReshape]"];
      Return[$Failed]];

    (* Operate preserves every input axis; broad Map may drop target axes if f
       collapses them, but still carries/vmaps every untargeted size > 1 axis. *)
    If[AnyTrue[If[strictQ, lhsAtoms, vmapAtoms],
        ! MemberQ[rhsAtoms, #] && atomSize[#, env] > 1 &],
      Message[Einstoff::unsupp,
        "an input axis of size > 1 is dropped on the output; dropping an untargeted \
size > 1 axis is not a blockwise map (a size-1 unit axis is squeezed)"];
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
    mappedDims = Dimensions[mapped];

    If[strictQ && mappedDims =!= Join[vmapDims, brDims],
      Message[Einstoff::unsupp,
        "the operation function did not return the same target block shape \
(Einstoff[Operate] needs a shape-preserving op; use Einstoff[Map] for \
shape-changing block maps)"];
      Return[$Failed]];
    If[! strictQ && (Length[mappedDims] < Length[vmapDims] ||
        Take[mappedDims, Length[vmapDims]] =!= vmapDims),
      Message[Einstoff::unsupp,
        "the map function changed the vmapped prefix shape; it may only change the \
target block shape"];
      Return[$Failed]];

    recombined = mapped;
    If[traceActionEnabledQ[traceAction],
      h = heldReshape[heldValue[x], decompDims];
      If[Length[srcPerm] > 1, h = heldTranspose[h, InversePermutation[srcPerm]]];
      h = If[vmapAtoms === {}, heldApply[h, f], heldMapAt[h, f, Length[vmapAtoms]]];
      If[! strictQ && mappedDims =!= Join[vmapDims, brDims],
        blockDims = Drop[mappedDims, Length[vmapDims]];
        produced = einCatch[rhsProducedTerms[rhsTerms, vmapAtoms, blockDims, env]];
        If[produced === $Failed, Return[$Failed]];
        {producedTerms, producedEnv, producedAtoms} = produced[[{1, 2, 3}]];
        result = einCatch[
          traceReturnHeld[
            materializeOutputExprHeld[h, Join[vmapAtoms, producedAtoms],
              producedTerms, producedEnv],
            traceAction]],
        result = einCatch[
          traceReturnHeld[
            materializeOutputExprHeld[h, order, rhsTerms, env],
            traceAction]]];
      If[result === $Failed,
        Message[Einstoff::unsat,
          "an output axis size is unbound (a repeated axis needs a binding)"];
        Return[$Failed]];
      Return[result]];
    (* Shape-preserving maps keep the current materialization behavior, including
       output-only broadcast axes around the target block.  Shape-changing maps expose
       the produced block suffix as anonymous internal axes and match it to the RHS. *)
    If[! strictQ && mappedDims =!= Join[vmapDims, brDims],
      blockDims = Drop[mappedDims, Length[vmapDims]];
      produced = einCatch[rhsProducedTerms[rhsTerms, vmapAtoms, blockDims, env]];
      If[produced === $Failed, Return[$Failed]];
      {producedTerms, producedEnv, producedAtoms} = produced[[{1, 2, 3}]];
      With[{recombined0 = recombined, atoms0 = Join[vmapAtoms, producedAtoms],
          rhs0 = producedTerms, env0 = producedEnv},
        result = einCatch[
          materializeOutputTrace[recombined0, atoms0, rhs0, env0, traceAction]]],
      With[{recombined0 = recombined, order0 = order, rhs0 = rhsTerms, env0 = env},
        result = einCatch[
          materializeOutputTrace[recombined0, order0, rhs0, env0, traceAction]]]];
    If[result === $Failed,
      Message[Einstoff::unsat,
        "an output axis size is unbound (a repeated axis needs a binding)"];
      Return[$Failed]];
    result
  ];

mapCore[fSpec_, desc_, tensors_, bindings_List, traceAction_, strictQ_] :=
  Module[{f = mapFunction[fSpec], planned},
    planned = If[MissingQ[f], Missing["UnsupportedIR"],
      tryMapIRPlan[Hold[desc], tensors, bindings, f, strictQ, traceAction]];
    Which[
      MissingQ[planned],
        mapLegacyCore[fSpec, desc, tensors, bindings, traceAction, strictQ],
      plannerFailureQ[planned],
        Message[Einstoff::unsupp,
          "the operation function did not return the statically expected target block shape"];
        $Failed,
      True,
        planned
    ]
  ];

(* Curried operators, like EinstoffReduce[reducer][…]. *)
EinstoffMap[fSpec_][desc_, tensors_, bindings_List : {},
    opts : OptionsPattern[EinstoffMap]] :=
  mapCore[fSpec, desc, tensors, bindings,
    OptionValue[EinstoffMap, {opts}, TraceAction], False];

EinstoffOperate[fSpec_][desc_, tensors_, bindings_List : {},
    opts : OptionsPattern[EinstoffOperate]] :=
  mapCore[fSpec, desc, tensors, bindings,
    OptionValue[EinstoffOperate, {opts}, TraceAction], True];
