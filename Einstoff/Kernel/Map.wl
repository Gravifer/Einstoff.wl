(* ::Package:: *)

(* Map path: Einstoff[Map] / EinstoffMap (einx miscellaneous / shape-preserving
   elementary ops — https://einx.readthedocs.io/en/stable/api/operations/misc.html:
   flip, roll, sort, softmax, log_softmax, id).  The kept-bracket sibling of
   Einstoff[ArrayReduce]: a *reduction* drops the bracketed axes (f: block ->
   scalar); a *map* keeps them (f: block -> same-length block), vmapping the op
   over every unbracketed axis.  einx has no generic vmap entry point — each named
   op carries its own bracketed signature — so this is the single generic operator
   that realizes all of them, with f supplied (curried) by the caller.

   Einstoff[Map][f][desc, tensors, bindings].  f receives the bracketed axes
   *flattened to one vector* (matching einx's grouped-bracket flattening, where
   [a b] == [a][b]) and must return a same-length vector.  Examples:
     Einstoff[Map]["flip"]     reverse along the bracket   (einx.flip)
     Einstoff[Map]["sort"]     sort along the bracket       (einx.sort)
     Einstoff[Map]["softmax"]  softmax along the bracket    (einx.softmax)
     Einstoff[Map][RotateLeft[#, 2] &]   roll               (einx.roll; the shift
       is a parameter, so roll is expressed as a function rather than a name).

   As with the reducer (and for the same reason — a hold attribute cannot survive
   the compound head EinstoffMap[f][…]), desc is NOT held; that is the uniform
   convention (a globally bound axis symbol substitutes, a bound integer reads as a
   literal dimension, illegal values are rejected by the matcher).

   Shared helpers (descParts, reduceAtoms, rearrangeAtoms, atomSize,
   materializeOutput) live in Lowering.wl. *)

PackageExported[{EinstoffMap}]

EinstoffMap::usage =
  "EinstoffMap[f][desc, tensors, bindings] realizes a shape-preserving \
elementary op (einx flip/roll/sort/softmax/log_softmax, einx.misc): the \
bracketed (Slot) axes are fed to f flattened to one vector and f returns a \
same-length vector, while every unbracketed axis is vmapped.  f may be a \
function (Reverse, Sort, a custom vector->vector map) or a name \
(\"flip\"/\"sort\"/\"softmax\"/\"log_softmax\"/\"id\").  The bracketed axes are \
kept on the output; dropping an axis is a reduction (use Einstoff[ArrayReduce]).";

Einstoff[Map] := EinstoffMap;
Einstoff["Map"] := EinstoffMap;

(* Resolve a map spec to a vector->vector function.  A raw function is used as-is;
   a convenience string is matched case-insensitively to the einx misc op of that
   name.  softmax/log_softmax use the max-shift stable form.  roll is omitted (its
   shift is a parameter — pass RotateLeft[#, k]& directly). *)
mapFunction[s_String] := Replace[ToLowerCase[s], {
  "id" | "identity" -> Identity,
  "flip" | "reverse" -> Reverse,
  "sort" -> Sort,
  "softmax" -> (Exp[# - Max[#]]/Total[Exp[# - Max[#]]] &),
  "log_softmax" | "logsoftmax" -> ((# - Max[#]) - Log[Total[Exp[# - Max[#]]]] &),
  (* An unknown string is a typo, not a function: flag it so the caller rejects it. *)
  _ :> Missing["UnknownMapOp", s]}];
mapFunction[f_] := f;

(* Curried: Einstoff[Map][f] is the operator, applied to [desc, tensors, bindings].
   A subvalue of EinstoffMap, exactly as EinstoffReduce[reducer][…]. *)
EinstoffMap[fSpec_][desc_, tensors_, bindings_List : {}] := withAxisScope @
  Module[{parts, lhs, rhs, inShapes, shp, env, f, x,
          lhsTagged, lhsAtoms, lhsBr, rhsAtoms, brAtoms, vmapAtoms,
          decompDims, order, srcPerm, xr, vmapDims, brDims, vmapProd, brProd,
          mat, mapped, recombined, result},
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

    (* A name repeated within an input shape is within-tensor contraction (Massage/
       Contract/einsum only); the resolver no longer rejects it, so guard here before the
       layout builds an invalid permutation (InversePermutation on a duplicated index). *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> axisDisplayName[firstDuplicateAxis[lhs]] <> " repeats within an input \
shape; Map is shape-preserving and does not contract — within-tensor contraction is \
Einstoff[\"ArrayContract\"] / Einstoff[\"einsum\"]"];
      Return[$Failed]];

    inShapes = Dimensions /@ tensors;
    shp = EinstoffShapes[desc, inShapes, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    (* Decompose: LHS bracket-aware (tagged), RHS plain (reuse rearrangeAtoms). *)
    lhsTagged = einCatch[Join @@ Table[reduceAtoms[t, False], {t, First[lhs]}]];
    If[lhsTagged === $Failed, Return[$Failed]];
    rhsAtoms = einCatch[Join @@ Table[rearrangeAtoms[t], {t, First[rhs]}]];
    If[rhsAtoms === $Failed, Return[$Failed]];
    lhsAtoms = lhsTagged[[All, 1]]; lhsBr = lhsTagged[[All, 2]];
    brAtoms = Pick[lhsAtoms, lhsBr];
    vmapAtoms = Pick[lhsAtoms, lhsBr, False];

    (* Map acts *along* a bracketed axis (the op signature); with no bracket the
       desc is a pure rearrange. *)
    If[brAtoms === {},
      Message[Einstoff::unsupp,
        "Einstoff[Map] needs a bracketed axis (the op acts along it); a desc with \
no bracket is a pure rearrange — use Einstoff[ArrayReshape]"];
      Return[$Failed]];

    (* Map preserves every axis (keeps the bracket, vmaps the rest); RHS-only axes are
       repetition.  A dropped input axis of size > 1 is a reduction (not map); a dropped
       size-1 (unit) axis carries no data and is squeezed by materializeOutput (einx
       allows e.g. 'a () [b] -> a [b]'), so the guard is size-aware, like Massage/Dot. *)
    If[AnyTrue[lhsAtoms, ! MemberQ[rhsAtoms, #] && atomSize[#, env] > 1 &],
      Message[Einstoff::unsupp,
        "an input axis of size > 1 is dropped on the output — dropping a size > 1 axis \
is a reduction, use Einstoff[ArrayReduce] (a size-1 unit axis is squeezed)"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = einCatch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[Einstoff::unsat, "an input axis size is unbound"];
      Return[$Failed]];
    xr = ArrayReshape[x, decompDims];

    (* Permute so the vmapped (unbracketed) atoms lead and the bracketed atoms
       trail, then collapse to a matrix {vmapProd, brProd}; f maps each row.
       (Same FirstPosition/InversePermutation idiom as materializeOutput.) *)
    order = Join[vmapAtoms, brAtoms];
    srcPerm = Flatten[FirstPosition[lhsAtoms, #] & /@ order];
    If[Length[srcPerm] > 1, xr = Transpose[xr, InversePermutation[srcPerm]]];
    vmapDims = atomSize[#, env] & /@ vmapAtoms;
    brDims = atomSize[#, env] & /@ brAtoms;
    vmapProd = Times @@ vmapDims;   (* 1 when there are no vmapped axes *)
    brProd = Times @@ brDims;
    mat = ArrayReshape[xr, {vmapProd, brProd}];
    mapped = f /@ mat;

    (* f must be shape-preserving along the bracket (block -> same-length block). *)
    If[! MatchQ[Dimensions[mapped], {vmapProd, brProd}],
      Message[Einstoff::unsupp,
        "the map function did not return a same-length block along the bracketed \
axis (Einstoff[Map] needs a shape-preserving op; to collapse the axis use \
Einstoff[ArrayReduce])"];
      Return[$Failed]];

    recombined = ArrayReshape[mapped, Join[vmapDims, brDims]];
    (* order is recombined's atom order; materialize repeats, permute to RHS, recompose. *)
    result = einCatch[materializeOutput[recombined, order, First[rhs], env]];
    If[result === $Failed,
      Message[Einstoff::unsat,
        "an output axis size is unbound (a repeated axis needs a binding)"];
      Return[$Failed]];
    result
  ];
