(* ::Package:: *)

(* Tests for the reduce lowering path (Einstoff[ArrayReduce]).
   The reducer is curried: Einstoff[ArrayReduce][reducer][desc, tensors, bindings].
   One file per lowering path under tests/; cf. Reshape.wlt.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`
   so they carry section semantics. The .wlt itself does not import MUnit`. *)

BeginTestSection["Einstoff`Lowering`Reduce"];

ClearAll[a, b, c, d];

(* ===================== reductions (einx reduce / einops.reduce) ===== *)

(* 1. einx-style bracket sum 'a [b] -> a' === native sum over axis 2. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a}}, {x}]],
  Total[ArrayReshape[Range[12], {3, 4}], {2}],
  TestID -> "reduce-bracket-sum"
];

(* 2. einops-style bare drop 'a b -> a' reduces too (no bracket needed). *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][Total][{{a_, b_}} :> {{a}}, {x}]],
  Total[ArrayReshape[Range[12], {3, 4}], {2}],
  TestID -> "reduce-bare-sum"
];

(* 3. Mean reducer. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][Mean][{{a_, b_}} :> {{a}}, {x}]],
  Mean /@ ArrayReshape[Range[12], {3, 4}],
  TestID -> "reduce-mean"
];

(* 4. Max reducer. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][Max][{{a_, b_}} :> {{a}}, {x}]],
  Max /@ ArrayReshape[Range[12], {3, 4}],
  TestID -> "reduce-max"
];

(* 4b. Reducer given a convenience string ("max"). *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce]["max"][{{a_, b_}} :> {{a}}, {x}]],
  Max /@ ArrayReshape[Range[12], {3, 4}],
  TestID -> "reduce-max-string"
];

(* 5. Reduce then permute survivors: 'a b [c] -> b a'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReduce][Total][{{a_, b_, Slot["c"]}} :> {{b, a}}, {x}]],
  Transpose[Total[ArrayReshape[Range[24], {2, 3, 4}], {3}]],
  TestID -> "reduce-then-permute"
];

(* 6. Reduce then merge survivors: 'a b [c] -> (a b)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReduce][Total][{{a_, b_, Slot["c"]}} :> {{CircleTimes[a, b]}}, {x}]],
  Flatten[Total[ArrayReshape[Range[24], {2, 3, 4}], {3}]],
  TestID -> "reduce-then-merge"
];

(* 7. All axes reduced -> scalar. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][Total][{{Slot["a"], Slot["b"]}} :> {{}}, {x}]],
  Total[Range[12]],
  TestID -> "reduce-full-scalar"
];

(* 7b-d. Targeted literals are anonymous target axes with concrete sizes. einx accepts
   the Slot spelling as 'a [2] -> a'; Highlighted/Framed are WL visual spellings. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}]},
    Einstoff[ArrayReduce][Total][{{a_, Slot[2]}} :> {{a}}, {x}]],
  Total[ArrayReshape[Range[6], {3, 2}], {2}],
  TestID -> "reduce-targeted-literal-slot"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}]},
    Einstoff[ArrayReduce][Total][{{a_, Highlighted[2]}} :> {{a}}, {x}]],
  Total[ArrayReshape[Range[6], {3, 2}], {2}],
  TestID -> "reduce-targeted-literal-highlighted"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}]},
    Einstoff[ArrayReduce][Total][{{a_, Framed[2]}} :> {{a}}, {x}]],
  Total[ArrayReshape[Range[6], {3, 2}], {2}],
  TestID -> "reduce-targeted-literal-framed"
];

(* 8. Reduce a targeted composite '(c d)' as a whole, with explicit string factor d=2. *)
VerificationTest[
  With[{x = ArrayReshape[Range[18], {3, 6}]},
    Einstoff[ArrayReduce][Total][{{a_, Highlighted[CircleTimes[c_, "d"]]}} :> {{a}}, {x}, {"d" -> 2}]],
  Total[ArrayReshape[Range[18], {3, 6}], {2}],
  TestID -> "reduce-composite-axis"
];

(* 9. Output dims of reduce-then-permute are correct. *)
VerificationTest[
  Dimensions @ With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReduce][Total][{{a_, b_, Slot["c"]}} :> {{b, a}}, {x}]],
  {3, 2},
  TestID -> "reduce-then-permute-dims"
];

(* ===================== rejection paths ============================= *)

(* 10. A targeted axis kept on output is the feed-to-elementary path, not reduce. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a, b}}, {ArrayReshape[Range[12], {3, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reduce-reject-kept-bracket"
];

(* 10b. A name repeated within an input shape is within-tensor contraction, not reduction
   — ArrayReduce rejects it (its own policy; EinstoffShapes no longer gates this). *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, b_, a_}} :> {{b}},
      {ArrayReshape[Range[12], {2, 3, 2}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reduce-reject-repeated-input-axis"
];

(* Named axis-sequences resolve shapes but runtime data lowering is deferred. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][
      {{a__, Slot["b"]}} :> {{a}},
      {ArrayReshape[Range[24], {2, 3, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reduce-reject-named-axis-sequence"
];

(* 11. A new output axis is repetition (SPEC 5.5); without a binding it is
   unsatisfiable and rejected. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a, c}}, {ArrayReshape[Range[12], {3, 4}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reduce-reject-unbound-repeat"
];

(* 12. Unsatisfiable desc (rank mismatch) returns $Failed. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, b_, Slot["c"]}} :> {{a, b}}, {ArrayReshape[Range[12], {3, 4}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reduce-reject-unsat"
];

(* 13. Variable-arity targets reduce all concrete axes they capture. *)
VerificationTest[
  Einstoff[ArrayReduce][Total][{{a_, SlotSequence[1], c_}} :> {{a, c}},
    {ArrayReshape[Range[24], {2, 3, 4}]}],
  Total[ArrayReshape[Range[24], {2, 3, 4}], {2}],
  TestID -> "reduce-slotsequence-target"
];

VerificationTest[
  Einstoff[ArrayReduce][Total][{{a_, ___, Slot["c"]}} :> {{a, ___}},
    {ArrayReshape[Range[24], {2, 3, 4}]}],
  Total[ArrayReshape[Range[24], {2, 3, 4}], {3}],
  TestID -> "reduce-blanknullsequence-carry"
];

VerificationTest[
  Einstoff[ArrayReduce][Total][{{a_, __, Slot["c"]}} :> {{a, __}},
    {ArrayReshape[Range[24], {2, 3, 4}]}],
  Total[ArrayReshape[Range[24], {2, 3, 4}], {3}],
  TestID -> "reduce-blanksequence-carry-nonempty"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, ___, c_}} :> {{a, c}},
      {ArrayReshape[Range[24], {2, 3, 4}]}],
    {Einstoff::unsupp, Einstoff::unsat}],
  $Failed,
  TestID -> "reduce-reject-dropped-plain-blanknullsequence"
];

VerificationTest[
  Einstoff[ArrayReduce][Total][{{a_, Highlighted[___], c_}} :> {{a, c}},
    {ArrayReshape[Range[120], {2, 3, 4, 5}]}],
  Total[ArrayReshape[Range[120], {2, 3, 4, 5}], {2, 3}],
  TestID -> "reduce-highlighted-blanknullsequence-target"
];

VerificationTest[
  Einstoff[ArrayReduce][Total][{{a_, Highlighted[3]}} :> {{a}},
    {ArrayReshape[Range[6], {2, 3}]}],
  Total[ArrayReshape[Range[6], {2, 3}], {2}],
  TestID -> "reduce-highlighted-literal"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, Highlighted[CirclePlus["b", c_]]}} :> {{a}},
      {ArrayReshape[Range[14], {2, 7}]}, {"b" -> 3}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reduce-reject-highlighted-direct-sum"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, Framed[CirclePlus["b", c_]]}} :> {{a}},
      {ArrayReshape[Range[14], {2, 7}]}, {"b" -> 3}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reduce-reject-framed-direct-sum"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, Slot[CirclePlus["b", "c"]]}} :> {{a}},
      {ArrayReshape[Range[14], {2, 7}]}, {"b" -> 3, "c" -> 4}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reduce-reject-slot-string-direct-sum"
];

(* 14. Multi-tensor input is rejected. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}, {c_}} :> {{a, c}}, {ArrayReshape[Range[12], {3, 4}], Range[5]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reduce-reject-multitensor"
];

(* ===================== reduce then repeat (SPEC 5.5) ============== *)

(* 15. Reduce b, then broadcast into a new axis c: 'a [b] -> a c', c=3. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {4, 3}]},
    Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a, c}}, {x}, {c -> 3}]],
  Table[Total[ArrayReshape[Range[12], {4, 3}], {2}][[i]], {i, 4}, {j, 3}],
  TestID -> "reduce-then-repeat"
];

(* 16. Reduce all axes, then broadcast the scalar into a vector: '[a] [b] -> c'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {4, 3}]},
    Einstoff[ArrayReduce][Total][{{Slot["a"], Slot["b"]}} :> {{c}}, {x}, {c -> 3}]],
  ConstantArray[Total[Range[12]], 3],
  TestID -> "reduce-all-then-repeat"
];

(* ===================== desc is not held (a feature) ============== *)
(* No operator holds desc, so a bare reference whose symbol is globally bound is
   substituted: a bound integer reads as a literal dimension; an illegal value is
   rejected by the existing checks. (Binding `name_` are still Pattern-held.) *)

(* 17. A globally bound integer reads as a literal axis size. *)
VerificationTest[
  Block[{k = 4}, With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][Total][{{a_, k}} :> {{a}}, {x}]]],
  Total[ArrayReshape[Range[12], {3, 4}], {2}],
  TestID -> "reduce-global-literal-dim"
];

(* 18. A globally bound integer that disagrees with the tensor is rejected. *)
VerificationTest[
  Block[{k = 5}, Quiet[
    With[{x = ArrayReshape[Range[12], {3, 4}]},
      Einstoff[ArrayReduce][Total][{{a_, k}} :> {{a}}, {x}]],
    {Einstoff::unsat}]],
  $Failed,
  TestID -> "reduce-global-dim-mismatch"
];

(* 19. A globally bound non-size value is rejected by the existing checks.  NB the
   shadow value must be neither a valid size NOR a valid axis-name string (a string is
   now a legal axis spelling): a Real like 2.5 is a genuine non-size that env-captures
   into an illegal dimension term and is rejected. *)
VerificationTest[
  Block[{k = 2.5}, Quiet[
    With[{x = ArrayReshape[Range[12], {3, 4}]},
      Einstoff[ArrayReduce][Total][{{a_, k}} :> {{a}}, {x}]],
    {Einstoff::unsat}]],
  $Failed,
  TestID -> "reduce-global-illegal"
];

(* ===================== full einx reduction-op coverage =============
   Every named reducer at
   https://einx.readthedocs.io/en/stable/api/operations/reduction.html resolves to
   a list reducer; checked here against an independent WL reference over the
   targeted axis. var/std are *population* (ddof = 0), matching numpy/einx. *)

(* 20. Population variance (NOT WL's sample Variance). *)
VerificationTest[
  With[{x = {{1., 2., 4., 8.}}},
    Einstoff[ArrayReduce]["var"][{{a_, Slot["b"]}} :> {{a}}, {x}]],
  {Mean[({1., 2., 4., 8.} - Mean[{1., 2., 4., 8.}])^2]},
  TestID -> "reduce-var-population"
];

(* 21. Population standard deviation = Sqrt of population variance. *)
VerificationTest[
  With[{x = {{1., 2., 4., 8.}}},
    Einstoff[ArrayReduce]["std"][{{a_, Slot["b"]}} :> {{a}}, {x}]],
  {Sqrt @ Mean[({1., 2., 4., 8.} - Mean[{1., 2., 4., 8.}])^2]},
  TestID -> "reduce-std-population"
];

(* 22. prod (already aliased; confirm the einx name resolves). *)
VerificationTest[
  With[{x = {{1, 2, 3, 4}}},
    Einstoff[ArrayReduce]["prod"][{{a_, Slot["b"]}} :> {{a}}, {x}]],
  {24},
  TestID -> "reduce-prod-name"
];

(* 23. count_nonzero counts the nonzero entries along the axis. *)
VerificationTest[
  Einstoff[ArrayReduce]["count_nonzero"][{{a_, Slot["b"]}} :> {{a}}, {{{0, 1, 0, 2}}}],
  {2},
  TestID -> "reduce-count-nonzero"
];

(* 24. any / all test "nonzero" (numpy/einx truthiness). *)
VerificationTest[
  {Einstoff[ArrayReduce]["any"][{{a_, Slot["b"]}} :> {{a}}, {{{0, 0, 0}}}],
   Einstoff[ArrayReduce]["all"][{{a_, Slot["b"]}} :> {{a}}, {{{1, 2, 0}}}],
   Einstoff[ArrayReduce]["all"][{{a_, Slot["b"]}} :> {{a}}, {{{1, 2, 3}}}]},
  {{False}, {False}, {True}},
  TestID -> "reduce-any-all"
];

(* 25b. An unknown reducer name is rejected (not applied as "name"[slice]). *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReduce]["summ"][{{a_, Slot["b"]}} :> {{a}},
      {ArrayReshape[Range[12], {3, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reduce-reject-unknown-string"
];

(* 25. logsumexp via the stable max-shift form. *)
VerificationTest[
  With[{x = {{1., 2., 4., 8.}}, v = {1., 2., 4., 8.}},
    Einstoff[ArrayReduce]["logsumexp"][{{a_, Slot["b"]}} :> {{a}}, {x}]],
  {Max[{1., 2., 4., 8.}] + Log[Total[Exp[{1., 2., 4., 8.} - Max[{1., 2., 4., 8.}]]]]},
  TestID -> "reduce-logsumexp"
];

(* 26. A literal-integer axis may be REDUCED (summed) away. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}]},
    Einstoff[ArrayReduce][Total][{{a_, 2}} :> {{a}}, {x}]],
  Total /@ ArrayReshape[Range[6], {3, 2}],
  TestID -> "reduce-literal-axis"
];

(* 27. ...but a literal-integer axis cannot be KEPT (it has no carryable identity —
   shared materializeOutput guard, Option A); rejected rather than leaked. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReduce][Total][{{a_, 2}} :> {{a, 2}},
      {ArrayReshape[Range[6], {3, 2}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reduce-reject-kept-literal"
];

(* 28. TraceAction is a standard option even on the curried reducer subvalue, and it
   wraps the lowered expression itself rather than only proving that the head is Hold. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}]},
    With[{g = Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a}}, {x}, {},
        TraceAction -> Hold]},
      {MatchQ[g, Hold[_ArrayReshape]], ! FreeQ[g, _ArrayReduce],
       FreeQ[g, _Einstoff`PackageScope`materializeOutput]}]],
  {True, True, True},
  TestID -> "reduce-traceaction-holds-public-lowering"
];

EndTestSection[];
