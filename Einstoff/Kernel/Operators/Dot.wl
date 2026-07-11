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
   rejected. Shared shape helpers live in ShapeChecker.wl; atom/materialization helpers
   live in Lowering.wl. *)

PackageExported[{EinstoffDot, EinstoffInner}]

EinstoffDot::usage =
  "EinstoffDot[desc, tensors, bindings] realizes an einsum-style contraction \
(einx.dot) of two or more tensors: shared axes absent from the output are summed, \
shared output axes are batch dims, one-sided output axes are free. It is the \
Times/Plus case of EinstoffInner.";

EinstoffInner::usage =
  "EinstoffInner[mul, add][desc, tensors, bindings] generalizes EinstoffDot: it \
contracts with an arbitrary elementwise mul and combiner add (cf. WL Inner), e.g. \
{Times, Plus} is Dot, {Plus, Min} is min-plus (tropical) contraction. Curried in \
(mul, add).";

Einstoff[Dot] := EinstoffDot;
Einstoff["Dot"] := EinstoffDot;
Einstoff[Inner] := EinstoffInner;
Einstoff["Inner"] := EinstoffInner;

Options[EinstoffDot] = {TraceAction -> None, "Targeting" -> Automatic};
Options[EinstoffInner] = {TraceAction -> None, "Targeting" -> Automatic};

dotDescPartsHeldRhs[h : Hold[_Rule | _RuleDelayed]] :=
  Module[{hr = canonHeld[h]},
    If[hr === $Failed, $Failed,
      {normShapes @ Extract[hr, {1, 1}],
       normHeldShapes @ Extract[hr, {1, 2}, Hold]}]];
dotDescPartsHeldRhs[_] := ($descRejectReason = None; $Failed);

dotSequenceAtomRules[namedAtoms_Association] :=
  Table[k -> Apply[Sequence, anonymousCaptureAtomList[{namedAtoms[k]}]],
    {k, Keys[namedAtoms]}];

dotSequenceRepeatRules[namedAtoms_Association] := {
  Verbatim[Repeated][sym_Symbol] :>
    RuleCondition[
      If[KeyExistsQ[namedAtoms, sym],
        Apply[Sequence, anonymousCaptureAtomList[{namedAtoms[sym]}]],
        Repeated[sym]]],
  Verbatim[RepeatedNull][sym_Symbol] :>
    RuleCondition[
      If[KeyExistsQ[namedAtoms, sym],
        Apply[Sequence, anonymousCaptureAtomList[{namedAtoms[sym]}]],
        RepeatedNull[sym]]]};

dotEvalRhsTerms[heldRhs_Hold, namedAtoms_Association] :=
  ReleaseHold[(heldRhs /. dotSequenceRepeatRules[namedAtoms]) /.
    dotSequenceAtomRules[namedAtoms]];

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
        "an input axis appears in only one operand and is dropped; a \
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

heldScalarBlock[HoldComplete[e_]] := HoldComplete[ArrayReshape[{e}, {1, 1, 1}]];

contractPairHeld[mul_, add_, ht1_HoldComplete, l1_, ht2_HoldComplete, l2_, keep_, env_] :=
  Module[{both, b, k, m, n, sz, prod, x1, x2, p1, p2, x1r, x2r, mm, lab},
    sz[atoms_] := atomSize[#, env] & /@ atoms;
    prod[atoms_] := Times @@ sz[atoms];
    both = Intersection[l1, l2];
    b = Select[l1, MemberQ[both, #] && MemberQ[keep, #] &];
    k = Select[l1, MemberQ[both, #] && ! MemberQ[keep, #] &];
    m = Select[l1, ! MemberQ[l2, #] && MemberQ[keep, #] &];
    n = Select[l2, ! MemberQ[l1, #] && MemberQ[keep, #] &];
    If[AnyTrue[l1, ! MemberQ[l2, #] && ! MemberQ[keep, #] &] ||
       AnyTrue[l2, ! MemberQ[l1, #] && ! MemberQ[keep, #] &],
      Message[Einstoff::unsupp,
        "an input axis appears in only one operand and is dropped; a \
within-operand reduction before contraction is not supported (use ArrayReduce)"];
      Throw[$Failed, einThrowTag]];
    x1 = If[l1 === {}, ht1, heldReshape[ht1, sz[l1]]];
    x2 = If[l2 === {}, ht2, heldReshape[ht2, sz[l2]]];
    p1 = Flatten[FirstPosition[l1, #] & /@ Join[b, m, k]];
    p2 = Flatten[FirstPosition[l2, #] & /@ Join[b, k, n]];
    If[Length[p1] > 1, x1 = heldTranspose[x1, InversePermutation[p1]]];
    If[Length[p2] > 1, x2 = heldTranspose[x2, InversePermutation[p2]]];
    x1r = If[l1 === {}, heldScalarBlock[ht1], heldReshape[x1, {prod[b], prod[m], prod[k]}]];
    x2r = If[l2 === {}, heldScalarBlock[ht2], heldReshape[x2, {prod[b], prod[k], prod[n]}]];
    mm = If[mul === Times && add === Plus,
      heldMapThreadDot[x1r, x2r],
      heldMapThreadInner[mul, add, x1r, x2r]];
    lab = Join[b, m, n];
    {If[lab === {}, heldReshape[mm, {}], heldReshape[mm, sz[lab]]], lab}];

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

sanitizeOperandHeld[t_, atoms_, env_] :=
  (If[AnyTrue[atoms, IntegerQ[#] && # > 1 &],
     Message[Einstoff::unsupp,
       "a literal axis of size > 1 in a contraction operand has no carryable identity \
(a shared/contracted axis must be named); only a unit (size-1) axis may be a literal"];
     Throw[$Failed, einThrowTag]];
   With[{keep = DeleteCases[atoms, _Integer]},
     If[keep === atoms, {HoldComplete[t], atoms},
       {heldReshape[HoldComplete[t], atomSize[#, env] & /@ keep], keep}]]);

(* The shared lowering, parameterized by the (mul, add) combiner.  desc is NOT held
   (uniform convention): a globally bound axis symbol substitutes — a bound integer
   reads as a literal dimension, illegal values rejected downstream; Pattern still
   holds each binding `name_` and `:>` holds the RHS. *)
innerLegacyLower[mul_, add_, desc_, tensors_, bindings_, traceAction_, targeting_] := withAxisScope @
  Module[{parts, lhs, heldRhs, rhs, shp, m, env, seq, decomp, decompList = {},
          namedAtoms = <||>, rhsTerms, taggedLabs, labs, lhsBr, outA, sanitized,
          stensors, slabs, hsanitized, hstensors, hslabs, result, targetedOcc,
          contractedOcc, targetingMode},
    targetingMode = einCatch[validateTargetingOption[targeting]];
    If[targetingMode === $Failed, Return[$Failed]];
    parts = dotDescPartsHeldRhs[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    {lhs, heldRhs} = parts;
    rhs = Quiet @ Check[ReleaseHold[heldRhs], $Failed];
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

    (* A name repeated *within a single operand* is within-tensor contraction; Dot/Inner
       contracts *across* operands (a name shared by two operands), not within one.  The
       resolver no longer rejects a repeated LHS, so guard here before contractPair builds
       an invalid permutation.  (`firstDuplicateAxis` checks each operand shape
       independently, so a genuine cross-operand contracted axis is not flagged.) *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> axisDisplayName[firstDuplicateAxis[lhs]] <> " repeats within a single \
operand; Dot/Inner contracts across operands, not within one (the mixed within+cross \
case is unsupported); contract that operand first with Einstoff[\"ArrayContract\"] \
(or single-tensor Einstoff[\"einsum\"]), then Dot"];
      Return[$Failed]];

    shp = EinstoffShapes[desc, Dimensions /@ tensors, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];
    m = EinstoffMatch[lhs, Dimensions /@ tensors, bindings];
    If[! TrueQ[m["ok"]],
      Message[Einstoff::unsat, m["reason"]]; Return[$Failed]];
    seq = Lookup[m, "seq", <||>];

    (* Atomic axes of each operand (brackets unwrapped, with per-occurrence target
       metadata retained for "Targeting" validation) and of the output. *)
    Do[
      decomp = einCatch[
        targetDecomposeTerms[lhs[[j]], Dimensions[tensors[[j]]], env, seq]];
      If[decomp === $Failed,
        Message[Einstoff::unsat, "an input axis size is unbound or inconsistent"];
        Return[$Failed]];
      AppendTo[decompList, decomp];
      env = decomp["Env"];
      If[Intersection[Keys[namedAtoms], Keys[decomp["NamedSequenceAtoms"]]] =!= {},
        Message[Einstoff::unsupp,
          "a named axis-sequence capture is repeated across contraction operands"];
        Return[$Failed]];
      namedAtoms = Join[namedAtoms, decomp["NamedSequenceAtoms"]],
      {j, Length[lhs]}];
    taggedLabs = Lookup[decompList, "Tagged"];
    rhsTerms = einCatch[dotEvalRhsTerms[heldRhs, namedAtoms]];
    If[rhsTerms === $Failed || ! MatchQ[rhsTerms, {_List}],
      Message[Einstoff::unsupp,
        "contraction RHS must evaluate to exactly one output shape"];
      Return[$Failed]];
    rhsTerms = einCatch[expandAnonymousTargetRhs[First[rhsTerms], {}, namedAtoms]];
    If[rhsTerms === $Failed, Return[$Failed]];
    outA = einCatch[Join @@ Table[rearrangeAtoms[t], {t, rhsTerms}]];
    If[taggedLabs === $Failed || outA === $Failed, Return[$Failed]];
    labs = taggedLabs[[All, All, 1]];
    lhsBr = taggedLabs[[All, All, 2]];
    targetedOcc = Flatten[Table[
      If[TrueQ[lhsBr[[j, p]]], {{j, p}}, Nothing],
      {j, Length[lhsBr]}, {p, Length[lhsBr[[j]]]}], 1];
    contractedOcc = Flatten[Table[
      With[{ax = labs[[j, p]]},
        If[! IntegerQ[ax] && ! MemberQ[outA, ax] &&
            Count[labs, l_ /; MemberQ[l, ax]] === 2,
          {{j, p}}, Nothing]],
      {j, Length[labs]}, {p, Length[labs[[j]]]}], 1];
    If[einCatch[validateTargetingPositions[targetingMode, targetedOcc,
        contractedOcc, "Dot/Inner"]] === $Failed,
      Return[$Failed]];

    (* Sanitize each operand for Option A: squeeze unit literals, reject size > 1
       literals, so contractPair only ever sees named (identity-bearing) axes. *)
    sanitized = einCatch[Table[sanitizeOperand[tensors[[j]], labs[[j]], env], {j, Length[lhs]}]];
    If[sanitized === $Failed, Return[$Failed]];
    stensors = sanitized[[All, 1]]; slabs = sanitized[[All, 2]];
    hsanitized = If[traceActionEnabledQ[traceAction],
      einCatch[Table[sanitizeOperandHeld[tensors[[j]], labs[[j]], env], {j, Length[lhs]}]],
      {}];
    If[hsanitized === $Failed, Return[$Failed]];
    If[traceActionEnabledQ[traceAction], hstensors = hsanitized[[All, 1]]; hslabs = hsanitized[[All, 2]]];

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
        "a contracted axis appears in more than two operands; an N-way (>2) same-index \
contraction is a super-diagonal, not a pairwise tensor contraction (keep it on the \
output for an elementwise/batch product, or contract pairwise)"];
      Return[$Failed]];

    (* Pairwise left fold: contract operand i into the accumulator, keeping the
       global output axes plus anything a later operand still needs. *)
    If[traceActionEnabledQ[traceAction],
      result = einCatch @ Module[{accT = First[hstensors], accL = First[hslabs], keep},
        Do[
          keep = Union[outA, Join @@ hslabs[[i + 1 ;;]]];
          {accT, accL} = contractPairHeld[mul, add, accT, accL, hstensors[[i]], hslabs[[i]], keep, env],
          {i, 2, Length[hstensors]}];
        traceReturnHeld[materializeOutputExprHeld[accT, accL, rhsTerms, env], traceAction]];
      If[result === $Failed, Return[$Failed]];
      Return[result]];

    result = einCatch @ Module[{accT = First[stensors], accL = First[slabs], keep},
      Do[
        keep = Union[outA, Join @@ slabs[[i + 1 ;;]]];
        {accT, accL} = contractPair[mul, add, accT, accL, stensors[[i]], slabs[[i]], keep, env],
        {i, 2, Length[stensors]}];
      With[{accT0 = accT, accL0 = accL, rhs0 = rhsTerms, env0 = env},
        materializeOutputTrace[accT0, accL0, rhs0, env0, traceAction]]];
    If[result === $Failed, Return[$Failed]];
    result
  ];

innerLower[mul_, add_, desc_, tensors_, bindings_List, traceAction_, targeting_] :=
  Module[{planned = tryInnerIRPlan[Hold[desc], tensors, bindings, mul, add,
      targeting, traceAction]},
    Which[
      plannerFailureQ[planned],
        reportPlannerFailure[planned],
      True,
        planned
    ]
  ];

EinstoffDot[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  innerLower[Times, Plus, desc, tensors, bindings,
    OptionValue[TraceAction], OptionValue["Targeting"]];

EinstoffInner[mul_, add_][desc_, tensors_, bindings_List : {},
    opts : OptionsPattern[EinstoffInner]] :=
  innerLower[mul, add, desc, tensors, bindings,
    OptionValue[EinstoffInner, {opts}, TraceAction],
    OptionValue[EinstoffInner, {opts}, "Targeting"]];
