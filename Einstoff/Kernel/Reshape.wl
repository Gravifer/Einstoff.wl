(* ::Package:: *)

(* Reshape / rearrange path: Einstoff[ArrayReshape] / EinstoffRearrange
   (einx.id / einops.rearrange).  Pure permute + split + merge with no axis
   introduced or dropped.  Lowers to the native trio

       ArrayReshape  (decompose composites into atomic axes)
       Transpose     (permute atomic axes from LHS order to RHS order)
       ArrayReshape  (recompose composites on the output side)

   Shared helpers (descParts, rearrangeAtoms, atomSize) live in Lowering.wl. *)

PackageExported[{EinstoffRearrange}]

EinstoffRearrange::usage =
  "EinstoffRearrange[desc, tensors, bindings] realizes a pure \
rearrange/reshape (einx.id / einops.rearrange) of a single tensor: it \
matches desc against the tensor shape to bind axis sizes, then emits \
ArrayReshape/Transpose/ArrayReshape to produce the output array. desc is \
held.";

Einstoff[ArrayReshape] := EinstoffRearrange;
Einstoff["Reshape"] := EinstoffRearrange;
Einstoff["Rearrange"] := EinstoffRearrange;

SetAttributes[EinstoffRearrange, HoldFirst];

EinstoffRearrange[desc_, tensors_, bindings_List : {}] :=
  Module[{parts, lhs, rhs, inShapes, shp, env, x,
          lhsAtoms, rhsAtoms, decompDims, srcOrder, xr, xt, outDims},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;
    If[! MatchQ[tensors, {__}],
      Message[Einstoff::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[Einstoff::unsupp,
        "ArrayReshape lowering supports exactly one input and one output \
tensor (multi-tensor contraction/broadcast is a separate path)"];
      Return[$Failed]];

    inShapes = Dimensions /@ tensors;
    shp = EinstoffShapes[desc, inShapes, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    {lhsAtoms, rhsAtoms} = Catch[
      {Join @@ (rearrangeAtoms /@ First[lhs]),
       Join @@ (rearrangeAtoms /@ First[rhs])}];
    If[lhsAtoms === $Failed, Return[$Failed]];
    If[Sort[lhsAtoms] =!= Sort[rhsAtoms],
      Message[Einstoff::unsupp,
        "axes are not a permutation between input and output — an axis is \
introduced or dropped, which is repeat/reduce, not rearrange"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = Catch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[Einstoff::unsat, "an input axis size is unbound"];
      Return[$Failed]];
    srcOrder = Flatten[FirstPosition[lhsAtoms, #] & /@ rhsAtoms];
    outDims = Catch[
      (Times @@ (atomSize[#, env] & /@ rearrangeAtoms[#])) & /@ First[rhs]];
    If[outDims === $Failed, Return[$Failed]];

    xr = ArrayReshape[x, decompDims];
    xt = If[Length[srcOrder] <= 1, xr,
            Transpose[xr, InversePermutation[srcOrder]]];
    ArrayReshape[xt, outDims]
  ];
