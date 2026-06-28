(* ::Package:: *)

(* Tests for the reduce lowering path (Einstoff[ArrayReduce]).
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
    Einstoff[ArrayReduce][{{a_, Slot[b_]}} :> {{a}}, {x}]],
  Total[ArrayReshape[Range[12], {3, 4}], {2}],
  TestID -> "reduce-bracket-sum"
];

(* 2. einops-style bare drop 'a b -> a' reduces too (no bracket needed). *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][{{a_, b_}} :> {{a}}, {x}]],
  Total[ArrayReshape[Range[12], {3, 4}], {2}],
  TestID -> "reduce-bare-sum"
];

(* 3. Reducer -> Mean. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][{{a_, b_}} :> {{a}}, {x}, Reducer -> Mean]],
  Mean /@ ArrayReshape[Range[12], {3, 4}],
  TestID -> "reduce-mean"
];

(* 4. Reducer -> Max. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][{{a_, b_}} :> {{a}}, {x}, Reducer -> Max]],
  Max /@ ArrayReshape[Range[12], {3, 4}],
  TestID -> "reduce-max"
];

(* 5. Reduce then permute survivors: 'a b [c] -> b a'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReduce][{{a_, b_, Slot[c_]}} :> {{b, a}}, {x}]],
  Transpose[Total[ArrayReshape[Range[24], {2, 3, 4}], {3}]],
  TestID -> "reduce-then-permute"
];

(* 6. Reduce then merge survivors: 'a b [c] -> (a b)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReduce][{{a_, b_, Slot[c_]}} :> {{CircleTimes[a, b]}}, {x}]],
  Flatten[Total[ArrayReshape[Range[24], {2, 3, 4}], {3}]],
  TestID -> "reduce-then-merge"
];

(* 7. All axes reduced -> scalar. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[ArrayReduce][{{Slot[a_], Slot[b_]}} :> {{}}, {x}]],
  Total[Range[12]],
  TestID -> "reduce-full-scalar"
];

(* 8. Reduce a bracketed composite '(c d)' as a whole, d=2. *)
VerificationTest[
  With[{x = ArrayReshape[Range[18], {3, 6}]},
    Einstoff[ArrayReduce][{{a_, Slot[CircleTimes[c_, d_]]}} :> {{a}}, {x}, {d -> 2}]],
  Total[ArrayReshape[Range[18], {3, 6}], {2}],
  TestID -> "reduce-composite-axis"
];

(* 9. Output dims of reduce-then-permute are correct. *)
VerificationTest[
  Dimensions @ With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReduce][{{a_, b_, Slot[c_]}} :> {{b, a}}, {x}]],
  {3, 2},
  TestID -> "reduce-then-permute-dims"
];

(* ===================== rejection paths ============================= *)

(* 10. A bracketed axis kept on output is the feed-to-elementary path, not reduce. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][{{a_, Slot[b_]}} :> {{a, b}}, {ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "reduce-reject-kept-bracket"
];

(* 11. A new output axis (not on input) is repeat, not reduce. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][{{a_, Slot[b_]}} :> {{a, c}}, {ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "reduce-reject-new-axis"
];

(* 12. Unsatisfiable desc (rank mismatch) returns $Failed. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][{{a_, b_, Slot[c_]}} :> {{a, b}}, {ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "reduce-reject-unsat"
];

(* 13. Variable-arity bracket ellipsis is out of scope for now. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][{{a_, Slot[___], c_}} :> {{a, c}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  $Failed,
  TestID -> "reduce-reject-ellipsis"
];

(* 14. Multi-tensor input is rejected. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReduce][{{a_, Slot[b_]}, {c_}} :> {{a, c}}, {ArrayReshape[Range[12], {3, 4}], Range[5]}],
  $Failed,
  TestID -> "reduce-reject-multitensor"
];

EndTestSection[];
