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

(* 8. Reduce a bracketed composite '(c d)' as a whole, d=2. *)
VerificationTest[
  With[{x = ArrayReshape[Range[18], {3, 6}]},
    Einstoff[ArrayReduce][Total][{{a_, Slot[CircleTimes[c_, d_]]}} :> {{a}}, {x}, {d -> 2}]],
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

(* 10. A bracketed axis kept on output is the feed-to-elementary path, not reduce. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a, b}}, {ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "reduce-reject-kept-bracket"
];

(* 11. A new output axis is repetition (SPEC 5.5); without a binding it is
   unsatisfiable and rejected. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a, c}}, {ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "reduce-reject-unbound-repeat"
];

(* 12. Unsatisfiable desc (rank mismatch) returns $Failed. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][Total][{{a_, b_, Slot["c"]}} :> {{a, b}}, {ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "reduce-reject-unsat"
];

(* 13. Variable-arity bracket ellipsis is out of scope for now. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][Total][{{a_, SlotSequence[1], c_}} :> {{a, c}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  $Failed,
  TestID -> "reduce-reject-ellipsis"
];

(* 14. Multi-tensor input is rejected. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}, {c_}} :> {{a, c}}, {ArrayReshape[Range[12], {3, 4}], Range[5]}],
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
  Block[{k = 5}, Quiet @ With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][Total][{{a_, k}} :> {{a}}, {x}]]],
  $Failed,
  TestID -> "reduce-global-dim-mismatch"
];

(* 19. A globally bound non-size value is rejected by the existing checks. *)
VerificationTest[
  Block[{k = "oops"}, Quiet @ With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][Total][{{a_, k}} :> {{a}}, {x}]]],
  $Failed,
  TestID -> "reduce-global-illegal"
];

(* ===================== full einx reduction-op coverage =============
   Every named reducer at
   https://einx.readthedocs.io/en/stable/api/operations/reduction.html resolves to
   a list reducer; checked here against an independent WL reference over the
   bracketed axis. var/std are *population* (ddof = 0), matching numpy/einx. *)

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

(* 25. logsumexp via the stable max-shift form. *)
VerificationTest[
  With[{x = {{1., 2., 4., 8.}}, v = {1., 2., 4., 8.}},
    Einstoff[ArrayReduce]["logsumexp"][{{a_, Slot["b"]}} :> {{a}}, {x}]],
  {Max[{1., 2., 4., 8.}] + Log[Total[Exp[{1., 2., 4., 8.} - Max[{1., 2., 4., 8.}]]]]},
  TestID -> "reduce-logsumexp"
];

EndTestSection[];
