(* ::Package:: *)

(* Reshape / rearrange path: Einstoff[ArrayReshape] / EinstoffRearrange
   (einx.id / einops.rearrange).  Permute + split + merge, and — following einx's
   uniform treatment of repetition (SPEC 5.5) — repeat: an output-only axis is
   materialized by broadcasting (einops.repeat / einx.id with a new axis, e.g.
   {{a_}} :> {{a, c}} with c bound in `bindings`).  No input axis may be dropped
   (that is reduce).  Lowers to ArrayReshape (decompose) then materializeOutput
   (broadcast repeats, permute to RHS order, recompose).

   Shared helpers (descParts, rearrangeAtoms, atomSize, materializeOutput) live
   in Lowering.wl. *)

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

(* desc is NOT held (uniform convention across operators): Pattern holds each
   binding `name_` and `:>` holds the RHS, so only a bare reference to a globally
   bound symbol is substituted — a bound integer reads as a literal dimension, and
   anything not a valid size is rejected downstream. *)
EinstoffRearrange[desc_, tensors_, bindings_List : {}] :=
  Module[{parts, lhs, rhs, inShapes, shp, env, x,
          lhsAtoms, rhsAtoms, decompDims, result},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;
    (* Direct sum: einx folds `+` into id. A CirclePlus on the RHS is
       concatenation, on the LHS it is splitting — delegate either way. *)
    If[hasCirclePlus[rhs], Return[directSumConcat[desc, tensors, bindings]]];
    If[hasCirclePlus[lhs], Return[directSumSplit[desc, tensors, bindings]]];
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

    lhsAtoms = Catch[Join @@ (rearrangeAtoms /@ First[lhs])];
    rhsAtoms = Catch[Join @@ (rearrangeAtoms /@ First[rhs])];
    If[lhsAtoms === $Failed || rhsAtoms === $Failed, Return[$Failed]];
    (* Every input axis must survive to the output; a dropped axis is reduce.
       Output-only axes are allowed — they are repetition (materializeOutput). *)
    If[! SubsetQ[rhsAtoms, lhsAtoms],
      Message[Einstoff::unsupp,
        "an input axis is dropped on the output — that is reduce, not rearrange"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = Catch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[Einstoff::unsat, "an input axis size is unbound"];
      Return[$Failed]];

    result = Catch[
      materializeOutput[ArrayReshape[x, decompDims], lhsAtoms, First[rhs], env]];
    If[result === $Failed,
      Message[Einstoff::unsat,
        "an output axis size is unbound (a repeated axis needs a binding)"];
      Return[$Failed]];
    result
  ];
