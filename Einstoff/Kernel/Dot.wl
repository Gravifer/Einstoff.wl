(* ::Package:: *)

(* Dot path: Einstoff[Dot] / EinstoffDot (einx.dot — einsum-style contraction).

   Two-tensor Einstein summation.  Each LHS axis is classified by where it
   appears:

     batch  (B)  in both operands AND on the output  — paired, not contracted
     contr  (K)  in both operands, NOT on the output  — summed over (the dot)
     free1  (M)  in operand 1 only, on the output
     free2  (N)  in operand 2 only, on the output

   Brackets (`Slot[...]`) are the einx way to mark the contracted axes; they are
   simply unwrapped here, since the classification above already determines which
   axes contract — a shared, non-output axis (SPEC 5.2, ex 10).

   Lowering: reshape each operand to its atomic axes, transpose operand 1 to
   [B, M, K] and operand 2 to [B, K, N], flatten each group so the operands
   become 3-D [b, m, k] / [b, k, n], batched-matmul with MapThread[Dot], then
   permute/recompose the [B, M, N] result onto the output shape.  prod of an
   empty axis group is 1, so outer products (no K), missing batch, and one-sided
   free axes all fall out of the same code.

   First cut: exactly two input tensors, one output; every non-output axis must
   be a shared (contracted) axis — a single-operand axis dropped before the
   contraction (within-operand reduction) is rejected, as is a CirclePlus or a
   variable-arity bracket ellipsis.  Shared helpers live in Lowering.wl. *)

PackageExported[{EinstoffDot}]

EinstoffDot::usage =
  "EinstoffDot[desc, tensors, bindings] realizes an einsum-style contraction \
(einx.dot) of two tensors: axes shared between the operands and absent from the \
output are contracted (summed), shared axes kept on the output are batch dims, \
and one-sided output axes are free. Lowers to ArrayReshape/Transpose/Dot. desc \
is held.";

Einstoff[Dot] := EinstoffDot;
Einstoff["Dot"] := EinstoffDot;

SetAttributes[EinstoffDot, HoldFirst];

EinstoffDot[desc_, tensors_, bindings_List : {}] :=
  Module[{parts, lhs, rhs, shp, env, op1, op2, outA, both, b, k, m, n,
          sz, prod, t1, t2, perm1, perm2, t1r, t2r, res, order, srcOut, outDims},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;
    If[! MatchQ[tensors, {_, _}],
      Message[Einstoff::unsupp,
        "Dot lowering currently supports exactly two input tensors"];
      Return[$Failed]];
    If[! MatchQ[lhs, {_List, _List}] || ! MatchQ[rhs, {_List}],
      Message[Einstoff::unsupp,
        "Dot lowering needs two input shapes and one output shape"];
      Return[$Failed]];

    shp = EinstoffShapes[desc, Dimensions /@ tensors, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    (* Atomic axes of each operand (brackets unwrapped) and of the output. *)
    {op1, op2} = Catch[{
      (Join @@ Table[reduceAtoms[t], {t, lhs[[1]]}])[[All, 1]],
      (Join @@ Table[reduceAtoms[t], {t, lhs[[2]]}])[[All, 1]]}];
    If[op1 === $Failed, Return[$Failed]];
    outA = Catch[Join @@ Table[rearrangeAtoms[t], {t, First[rhs]}]];
    If[outA === $Failed, Return[$Failed]];

    both = Intersection[op1, op2];
    b = Select[op1, MemberQ[both, #] && MemberQ[outA, #] &];   (* batch  *)
    k = Select[op1, MemberQ[both, #] && ! MemberQ[outA, #] &]; (* contr  *)
    m = Select[op1, ! MemberQ[op2, #] && MemberQ[outA, #] &];  (* free 1 *)
    n = Select[op2, ! MemberQ[op1, #] && MemberQ[outA, #] &];  (* free 2 *)

    (* A single-operand axis that is dropped would be a within-operand reduction
       before the contraction — not supported in this first cut. *)
    If[AnyTrue[op1, ! MemberQ[op2, #] && ! MemberQ[outA, #] &] ||
       AnyTrue[op2, ! MemberQ[op1, #] && ! MemberQ[outA, #] &],
      Message[Einstoff::unsupp,
        "an input axis appears in only one operand and is dropped — a \
within-operand reduction before contraction is not supported yet"];
      Return[$Failed]];
    (* Every output axis must come from some operand (else it is repeat). *)
    If[! SubsetQ[Union[op1, op2], outA],
      Message[Einstoff::unsupp,
        "an output axis is on neither input — introducing an axis is repeat, \
not contraction"];
      Return[$Failed]];

    sz[atoms_] := atomSize[#, env] & /@ atoms;
    prod[atoms_] := Times @@ sz[atoms];   (* 1 for an empty group *)

    res = Catch[
      t1 = ArrayReshape[tensors[[1]], sz[op1]];
      t2 = ArrayReshape[tensors[[2]], sz[op2]];
      (* operand 1 -> [B, M, K] ; operand 2 -> [B, K, N] *)
      perm1 = Flatten[FirstPosition[op1, #] & /@ Join[b, m, k]];
      perm2 = Flatten[FirstPosition[op2, #] & /@ Join[b, k, n]];
      If[Length[perm1] > 1, t1 = Transpose[t1, InversePermutation[perm1]]];
      If[Length[perm2] > 1, t2 = Transpose[t2, InversePermutation[perm2]]];
      t1r = ArrayReshape[t1, {prod[b], prod[m], prod[k]}];
      t2r = ArrayReshape[t2, {prod[b], prod[k], prod[n]}];
      MapThread[Dot, {t1r, t2r}]   (* -> {prod[b], prod[m], prod[n]} *)
    ];
    If[res === $Failed,
      Message[Einstoff::unsat, "an axis size is unbound"]; Return[$Failed]];

    (* Full contraction to a scalar (no surviving output axis). *)
    If[outA === {}, Return[First @ Flatten[res]]];

    (* Recompose: atomic [B, M, N] -> permute to output atom order -> output shape. *)
    res = ArrayReshape[res, sz[Join[b, m, n]]];
    order = Join[b, m, n];
    srcOut = Flatten[FirstPosition[order, #] & /@ outA];
    If[Length[srcOut] > 1, res = Transpose[res, InversePermutation[srcOut]]];
    outDims = Catch[(Times @@ (atomSize[#, env] & /@ rearrangeAtoms[#])) & /@ First[rhs]];
    If[outDims === $Failed,
      Message[Einstoff::unsat, "an output axis size is unbound"]; Return[$Failed]];
    ArrayReshape[res, outDims]
  ];
