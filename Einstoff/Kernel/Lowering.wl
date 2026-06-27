(* ::Package:: *)

(* Einstoff lowering — turning a satisfiable description into actual array
   operations.  This first cut implements the pure rearrange / reshape path
   (einx.id / einops.rearrange), i.e. permute + split + merge with no axis
   introduced or dropped.  It lowers to the native trio

       ArrayReshape  (decompose composites into atomic axes)
       Transpose     (permute atomic axes from LHS order to RHS order)
       ArrayReshape  (recompose composites on the output side)

   Reduction (brackets / Slot, CirclePlus), repeat (RHS-only axes), and the
   multi-tensor contraction / broadcast paths are deliberately out of scope
   here; they are separate compiled code paths (SPEC 5.2, 9) and will get
   their own lowering.  Anything outside the rearrange subset is rejected
   loudly rather than mis-compiled.

   Public surface: `Einstoff[ArrayReshape]` is the operator form demanded by
   CLAUDE.md; it resolves to `EinstoffRearrange[desc, tensors, bindings]`. *)

PackageExported[{
  Einstoff,
  EinstoffRearrange
}]

Einstoff::usage =
  "Einstoff[op] yields the Einstoff operator implementing op. \
Einstoff[ArrayReshape] gives the rearrange/reshape operator, applied as \
Einstoff[ArrayReshape][desc, tensors, bindings].";

EinstoffRearrange::usage =
  "EinstoffRearrange[desc, tensors, bindings] realizes a pure \
rearrange/reshape (einx.id / einops.rearrange) of a single tensor: it \
matches desc against the tensor shape to bind axis sizes, then emits \
ArrayReshape/Transpose/ArrayReshape to produce the output array. desc is \
held.";

EinstoffRearrange::unsupp = "`1`";
EinstoffRearrange::unsat =
  "description is not satisfiable against the given tensor(s): `1`";

(* ------------------------------------------------------------------ *)
(* Operator dispatch.                                                  *)
(* ------------------------------------------------------------------ *)

Einstoff[ArrayReshape] := EinstoffRearrange;
Einstoff["Reshape"] := EinstoffRearrange;
Einstoff["Rearrange"] := EinstoffRearrange;

(* ------------------------------------------------------------------ *)
(* Atomic-axis decomposition of one dimension term.                    *)
(* A "rearrange atom" is an axis that survives the transform unchanged  *)
(* (only its position / grouping changes).  Composites expand to their  *)
(* factors in order; everything else in the rearrange subset is a       *)
(* single atom.  Out-of-subset heads Throw[$Failed] (caught by caller). *)
(* ------------------------------------------------------------------ *)

rearrangeAtoms[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]]] := {s};
rearrangeAtoms[s_Symbol] := {s};
rearrangeAtoms[n_Integer] := {n};
rearrangeAtoms[CircleTimes[fs__]] := Join @@ (rearrangeAtoms /@ {fs});
rearrangeAtoms[other_] := (
  Message[EinstoffRearrange::unsupp,
    "unsupported term in ArrayReshape lowering: " <>
      ToString[other, InputForm] <>
      " (brackets, direct sums and ellipses are not part of the rearrange \
subset yet)"];
  Throw[$Failed]);

atomSize[n_Integer, _] := n;
atomSize[s_, env_] := Lookup[env, s, Throw[$Failed]];

(* ------------------------------------------------------------------ *)
(* The rearrange operator.                                             *)
(* desc reaches us held (HoldFirst); pattern substitution injects the  *)
(* actual rule wherever `desc` appears, so Extract[Hold[desc], ...] and *)
(* the EinstoffShapes call below both see the real lhs :> rhs.          *)
(* ------------------------------------------------------------------ *)

SetAttributes[EinstoffRearrange, HoldFirst];

EinstoffRearrange[desc_, tensors_, bindings_ : {}] :=
  Module[{lhs, heldRhs, rhs, inShapes, shp, env, x,
          lhsAtoms, rhsAtoms, decompDims, srcOrder, xr, xt, outDims},
    If[! MatchQ[Hold[desc], Hold[_Rule | _RuleDelayed]],
      Message[EinstoffRearrange::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    lhs = Extract[Hold[desc], {1, 1}];
    heldRhs = Extract[Hold[desc], {1, 2}, Hold];
    rhs = ReleaseHold[heldRhs];
    If[! MatchQ[tensors, {__}],
      Message[EinstoffRearrange::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[EinstoffRearrange::unsupp,
        "ArrayReshape lowering currently supports exactly one input and one \
output tensor (multi-tensor contraction/broadcast is a separate path)"];
      Return[$Failed]];

    inShapes = Dimensions /@ tensors;
    shp = EinstoffShapes[desc, inShapes, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[EinstoffRearrange::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    {lhsAtoms, rhsAtoms} = Catch[
      {Join @@ (rearrangeAtoms /@ First[lhs]),
       Join @@ (rearrangeAtoms /@ First[rhs])}];
    If[lhsAtoms === $Failed, Return[$Failed]];
    If[Sort[lhsAtoms] =!= Sort[rhsAtoms],
      Message[EinstoffRearrange::unsupp,
        "axes are not a permutation between input and output — an axis is \
introduced or dropped, which is repeat/reduce, not rearrange"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = Catch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[EinstoffRearrange::unsat, "an input axis size is unbound"];
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
