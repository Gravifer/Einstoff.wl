(* ::Package:: *)

(* Contraction path: Einstoff[Dot] and its generalization Einstoff[Inner].

   Einstoff[Dot] is einsum-style contraction (einx.dot): sum of products. It is the
   (Times, Plus) special case of Einstoff[Inner][mul, add], which contracts with an
   arbitrary "multiply" mul and "combine" add (cf. WL Inner — Dot == Inner[Times, _,
   _, Plus]).  Inner is curried: Einstoff[Inner][mul, add][desc, tensors, bindings].

   N-ary over two or more operands. An atomic axis is:
     contracted  if it is absent from the output (combined over),
     kept         if it is on the output — batch (shared across operands) or free.
   Brackets (Slot[...]) are the einx way to mark contracted axes; they are unwrapped
   here, since whether an axis contracts already follows from "shared & not on the
   output" (SPEC 5.2, ex 10).

   Lowering — pairwise left fold. `contractPair` contracts two atomic-axis tensors,
   keeping a given set of axes, by classifying their axes into batch B / contract K /
   free M,N, reshaping to [B,M,K] and [B,K,N], and a batched generalized inner
   product (MapThread of Inner[mul, …, add], or Dot for the Times/Plus fast path)
   -> [B,M,N]. The fold contracts operand 1·2, then ·3, … ; at each step the *kept*
   set is the global output axes plus every axis a later operand still needs, so an
   axis is combined only once nothing downstream needs it. For a semiring (mul, add)
   — (Times,Plus), tropical (Plus,Min), … — the fold is associative; the left-to-
   right order is the defined semantics regardless. The single remaining tensor is
   permuted/recomposed onto the output by the shared materializeOutput (which also
   broadcasts any output-only repetition axis, SPEC 5.5).

   An axis appearing in only one operand and neither kept nor shared would be a
   within-operand reduction before contraction — rejected (use ArrayReduce). A
   CirclePlus or variable-arity bracket ellipsis in a contraction shape is also
   rejected. Shared helpers live in Lowering.wl. *)

PackageExported[{EinstoffDot, EinstoffInner}]

EinstoffDot::usage =
  "EinstoffDot[desc, tensors, bindings] realizes an einsum-style contraction \
(einx.dot) of two or more tensors: shared axes absent from the output are summed, \
shared output axes are batch dims, one-sided output axes are free. It is the \
Times/Plus case of EinstoffInner.";

EinstoffInner::usage =
  "EinstoffInner[mul, add][desc, tensors, bindings] generalizes EinstoffDot: it \
contracts with an arbitrary elementwise mul and combiner add (cf. WL Inner) — e.g. \
{Times, Plus} is Dot, {Plus, Min} is min-plus (tropical) contraction. Curried in \
(mul, add).";

Einstoff[Dot] := EinstoffDot;
Einstoff["Dot"] := EinstoffDot;
Einstoff[Inner] := EinstoffInner;
Einstoff["Inner"] := EinstoffInner;

(* Contract two atomic-axis tensors with combiner (mul, add), keeping the axes in
   `keep`; return {tensor, labels} reshaped to atomic axes (label order B,M,N).
   Emits a message and Throws $Failed on a within-operand drop. *)
contractPair[mul_, add_, t1_, l1_, t2_, l2_, keep_, env_] :=
  Module[{both, b, k, m, n, sz, prod, x1, x2, p1, p2, x1r, x2r, mm, lab},
    sz[atoms_] := atomSize[#, env] & /@ atoms;
    prod[atoms_] := Times @@ sz[atoms];
    both = Intersection[l1, l2];
    b = Select[l1, MemberQ[both, #] && MemberQ[keep, #] &];     (* batch   *)
    k = Select[l1, MemberQ[both, #] && ! MemberQ[keep, #] &];   (* contract *)
    m = Select[l1, ! MemberQ[l2, #] && MemberQ[keep, #] &];     (* free 1  *)
    n = Select[l2, ! MemberQ[l1, #] && MemberQ[keep, #] &];     (* free 2  *)
    If[AnyTrue[l1, ! MemberQ[l2, #] && ! MemberQ[keep, #] &] ||
       AnyTrue[l2, ! MemberQ[l1, #] && ! MemberQ[keep, #] &],
      Message[Einstoff::unsupp,
        "an input axis appears in only one operand and is dropped — a \
within-operand reduction before contraction is not supported (use ArrayReduce)"];
      Throw[$Failed, einThrowTag]];
    x1 = If[l1 === {}, t1, ArrayReshape[t1, sz[l1]]];
    x2 = If[l2 === {}, t2, ArrayReshape[t2, sz[l2]]];
    p1 = Flatten[FirstPosition[l1, #] & /@ Join[b, m, k]];
    p2 = Flatten[FirstPosition[l2, #] & /@ Join[b, k, n]];
    If[Length[p1] > 1, x1 = Transpose[x1, InversePermutation[p1]]];
    If[Length[p2] > 1, x2 = Transpose[x2, InversePermutation[p2]]];
    (* a scalar operand (no axes) becomes the 1x1x1 block {{{v}}} *)
    x1r = If[l1 === {}, ArrayReshape[{t1}, {1, 1, 1}], ArrayReshape[x1, {prod[b], prod[m], prod[k]}]];
    x2r = If[l2 === {}, ArrayReshape[{t2}, {1, 1, 1}], ArrayReshape[x2, {prod[b], prod[k], prod[n]}]];
    (* batched generalized inner product -> {prodB, prodM, prodN};
       Dot is the optimized Times/Plus path. *)
    mm = If[mul === Times && add === Plus,
      MapThread[Dot, {x1r, x2r}],
      MapThread[Inner[mul, #1, #2, add] &, {x1r, x2r}]];
    lab = Join[b, m, n];
    {If[lab === {}, First @ Flatten[mm], ArrayReshape[mm, sz[lab]]], lab}];

(* Option A in the contraction path: a literal input axis is anonymous, so it cannot be
   a shared/contracted/batch/free identity.  A size-1 literal is a UNIT axis (carries no
   data) — squeeze it; a size-(>1) literal has no carryable identity — reject (cf.
   einx.dot rejecting 'a 2, 2 b -> a b': "contracted axes must appear in exactly two
   inputs").  Otherwise two equal integer literals in different operands would be treated
   as the same axis by contractPair's Intersection.  Returns {tensor, atoms} with unit
   literals squeezed away (reshapeTo drops them) and no integer atoms remaining. *)
sanitizeOperand[t_, atoms_, env_] :=
  (If[AnyTrue[atoms, IntegerQ[#] && # > 1 &],
     Message[Einstoff::unsupp,
       "a literal axis of size > 1 in a contraction operand has no carryable identity \
(a shared/contracted axis must be named); only a unit (size-1) axis may be a literal"];
     Throw[$Failed, einThrowTag]];
   With[{keep = DeleteCases[atoms, _Integer]},
     If[keep === atoms, {t, atoms},
       {reshapeTo[t, atomSize[#, env] & /@ keep], keep}]]);

(* The shared lowering, parameterized by the (mul, add) combiner.  desc is NOT held
   (uniform convention): a globally bound axis symbol substitutes — a bound integer
   reads as a literal dimension, illegal values rejected downstream; Pattern still
   holds each binding `name_` and `:>` holds the RHS. *)
innerLower[mul_, add_, desc_, tensors_, bindings_] :=
  Module[{parts, lhs, rhs, shp, env, labs, outA, sanitized, stensors, slabs, result},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;
    If[! MatchQ[tensors, {_, __}],
      Message[Einstoff::unsupp,
        "contraction needs at least two input tensors (use ArrayReduce/ArrayReshape \
for one)"];
      Return[$Failed]];
    If[! MatchQ[lhs, {__List}] || ! MatchQ[rhs, {_List}] ||
       Length[lhs] =!= Length[tensors],
      Message[Einstoff::unsupp,
        "contraction needs one input shape per tensor and exactly one output shape"];
      Return[$Failed]];

    shp = EinstoffShapes[desc, Dimensions /@ tensors, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    (* Atomic axes of each operand (brackets unwrapped) and of the output. *)
    labs = einCatch[Table[
      (Join @@ Table[reduceAtoms[t], {t, lhs[[j]]}])[[All, 1]], {j, Length[lhs]}]];
    outA = einCatch[Join @@ Table[rearrangeAtoms[t], {t, First[rhs]}]];
    If[labs === $Failed || outA === $Failed, Return[$Failed]];

    (* Sanitize each operand for Option A: squeeze unit literals, reject size > 1
       literals, so contractPair only ever sees named (identity-bearing) axes. *)
    sanitized = einCatch[Table[sanitizeOperand[tensors[[j]], labs[[j]], env], {j, Length[lhs]}]];
    If[sanitized === $Failed, Return[$Failed]];
    stensors = sanitized[[All, 1]]; slabs = sanitized[[All, 2]];

    (* A contracted axis must be shared by *exactly two* operands.  A named axis that is
       absent from the output (contracted) and appears in more than two operands is an
       N-way same-index contraction — a super-diagonal, non-tensorial (cf. einx.dot
       "contracted axes must appear in exactly two input expressions", and the within-
       tensor >2 reject in selfContract).  Keeping the axis on the output (an elementwise
       / batch product across operands, e.g. 'a, a, a -> a') is fine and not caught here.
       The one-operand dropped case is a within-operand reduction, caught in contractPair. *)
    If[AnyTrue[DeleteDuplicates[Flatten[slabs]],
        Function[ax, ! MemberQ[outA, ax] && Count[slabs, l_ /; MemberQ[l, ax]] > 2]],
      Message[Einstoff::unsupp,
        "a contracted axis appears in more than two operands — an N-way (>2) same-index \
contraction is a super-diagonal, not a pairwise tensor contraction (keep it on the \
output for an elementwise/batch product, or contract pairwise)"];
      Return[$Failed]];

    (* Pairwise left fold: contract operand i into the accumulator, keeping the
       global output axes plus anything a later operand still needs. *)
    result = einCatch @ Module[{accT = First[stensors], accL = First[slabs], keep},
      Do[
        keep = Union[outA, Join @@ slabs[[i + 1 ;;]]];
        {accT, accL} = contractPair[mul, add, accT, accL, stensors[[i]], slabs[[i]], keep, env],
        {i, 2, Length[stensors]}];
      materializeOutput[accT, accL, First[rhs], env]];
    If[result === $Failed, Return[$Failed]];
    result
  ];

EinstoffDot[desc_, tensors_, bindings_List : {}] :=
  innerLower[Times, Plus, desc, tensors, bindings];

EinstoffInner[mul_, add_][desc_, tensors_, bindings_List : {}] :=
  innerLower[mul, add, desc, tensors, bindings];
