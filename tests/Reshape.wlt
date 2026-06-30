(* ::Package:: *)

(* Tests for the rearrange/reshape lowering path (Einstoff[ArrayReshape]).
   One file per lowering path under tests/; future paths get Reduce.wlt etc.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`
   so they carry section semantics. The .wlt itself does not import MUnit`. *)

BeginTestSection["Einstoff`Lowering`Reshape"];

ClearAll[a, b, c];

(* ===================== rearrange / reshape (einx.id) =============== *)

(* 1. Plain rearrange a b c -> c a b matches native Transpose. *)
VerificationTest[
  With[{x = ArrayReshape[Range[2*3*4], {2, 3, 4}]},
    Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {x}]],
  Transpose[ArrayReshape[Range[2*3*4], {2, 3, 4}], {2, 3, 1}],
  TestID -> "lower-rearrange-permute"
];

(* 2. Split + permute + merge a (b c) -> (b a) c, b=2. *)
VerificationTest[
  With[{y = ArrayReshape[Range[4*8], {4, 8}]},
    Einstoff[ArrayReshape][
      {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {y}, {b -> 2}]],
  ArrayReshape[
    Transpose[ArrayReshape[Range[4*8], {4, 2, 4}], {2, 1, 3}], {8, 4}],
  TestID -> "lower-split-permute-merge"
];

(* 3. Output shape is correct for split+permute+merge. *)
VerificationTest[
  Dimensions @ With[{y = ArrayReshape[Range[4*8], {4, 8}]},
    Einstoff[ArrayReshape][
      {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {y}, {b -> 2}]],
  {8, 4},
  TestID -> "lower-split-permute-merge-dims"
];

(* 4. Single-axis identity (Length<=1 transpose short-circuit). *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a}}, {Range[5]}],
  Range[5],
  TestID -> "lower-identity"
];

(* 5. Pure merge a b -> (a b) flattens row-major. *)
VerificationTest[
  With[{m = Partition[Range[6], 3]},
    Einstoff[ArrayReshape][{{a_, b_}} :> {{CircleTimes[a, b]}}, {m}]],
  Range[6],
  TestID -> "lower-merge"
];

(* 6. Pure split (a b) -> a b round-trips with merge. *)
VerificationTest[
  Einstoff[ArrayReshape][{{CircleTimes[a_, b_]}} :> {{a, b}}, {Range[6]}, {a -> 2}],
  Partition[Range[6], 3],
  TestID -> "lower-split"
];

(* ===================== rejection paths ============================= *)

(* 7. Brackets (reduce) are not in the rearrange subset. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][
    {{a_, Slot["b"]}} :> {{a}}, {Partition[Range[6], 3]}],
  $Failed,
  TestID -> "lower-reject-bracket"
];

(* 8. Dropping an axis (reduce) is rejected as non-permutation. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][
    {{a_, b_}} :> {{a}}, {Partition[Range[6], 3]}],
  $Failed,
  TestID -> "lower-reject-drop-axis"
];

(* 9. Unsatisfiable desc (rank mismatch) returns $Failed. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][
    {{a_, b_, c_}} :> {{c, a, b}}, {ArrayReshape[Range[8], {4, 2}]}],
  $Failed,
  TestID -> "lower-reject-unsat"
];

(* 10. Multi-tensor input is rejected (separate path). *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][
    {{a_}, {b_}} :> {{a, b}}, {Range[4], Range[5]}],
  $Failed,
  TestID -> "lower-reject-multitensor"
];

(* ===================== repetition (SPEC 5.5) ====================== *)

(* 11. Repeat a vector along a new trailing axis: 'a -> a c', c=3. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}],
  Table[Range[4][[i]], {i, 4}, {j, 3}],
  TestID -> "repeat-trailing"
];

(* 12. Repeat + permute: 'a -> c a', c=3 (new axis leads). *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{c, a}}, {Range[4]}, {c -> 3}],
  ConstantArray[Range[4], 3],
  TestID -> "repeat-leading"
];

(* 13. einops.repeat 2D -> 3D: 'a b -> a b c', c=2. *)
VerificationTest[
  With[{m = Partition[Range[6], 3]},
    Einstoff[ArrayReshape][{{a_, b_}} :> {{a, b, c}}, {m}, {c -> 2}]],
  Table[Partition[Range[6], 3][[i, j]], {i, 2}, {j, 3}, {k, 2}],
  TestID -> "repeat-einops-2d-3d"
];

(* 14. An unbound repeat axis (no binding) is unsatisfiable. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{a_}} :> {{a, c}}, {Range[4]}],
  $Failed,
  TestID -> "repeat-reject-unbound"
];

(* 15. An explicit integer axis on the output is repetition: 'a -> a 2'. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, 2}}, {Range[4]}],
  Table[Range[4][[i]], {i, 4}, {j, 2}],
  TestID -> "repeat-output-integer"
];

(* 16. A repeat axis inside an output composite: 'a -> (a c)', c=3. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{CircleTimes[a, c]}}, {Range[4]}, {c -> 3}],
  Flatten @ Table[Range[4][[i]], {i, 4}, {j, 3}],
  TestID -> "repeat-merge"
];

(* 17. Repeat axis as the leading composite factor: 'a -> (c a)', c=3. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{CircleTimes[c, a]}}, {Range[4]}, {c -> 3}],
  Flatten @ ConstantArray[Range[4], 3],
  TestID -> "repeat-merge-leading"
];

(* 18-20. An output axis must be a positive integer (Massage sizes via EinstoffMatch,
   so this positivity guard lives in materializeOutput, not EinstoffShapes). *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{a_}} :> {{a, 0}}, {Range[3]}],
  $Failed,
  TestID -> "reject-zero-output-integer"
];
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{a_}} :> {{a, c}}, {Range[3]}, {c -> 0}],
  $Failed,
  TestID -> "reject-zero-output-binding"
];
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{a_}} :> {{a, -1}}, {Range[3]}],
  $Failed,
  TestID -> "reject-negative-output-integer"
];

(* 21. Duplicate literal output axes BROADCAST as distinct anonymous axes (Option A,
   einx-faithful: 'a -> a 2 2' => (a,2,2)). *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, 2, 2}}, {Range[3]}],
  Table[Range[3][[i]], {i, 3}, {j, 2}, {k, 2}],
  TestID -> "repeat-duplicate-literal"
];

(* 22. A literal-integer INPUT axis cannot be carried to the output (it has no
   identity to permute — cf. einx rejecting 'a 2 -> a 2'); that is a drop = reduce. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{a_, 2}} :> {{2, a}}, {ArrayReshape[Range[6], {3, 2}]}],
  $Failed,
  TestID -> "reject-literal-carry"
];

(* ===================== unit axes & scalars (einx axis-squeezing) ====== *)
ClearAll[a, c];

(* 23. Squeeze a size-1 input axis dropped on the output: 'a 1 c -> a c' (einx). *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, 1, c_}} :> {{a, c}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
  ArrayReshape[Range[6], {2, 3}],
  TestID -> "unit-squeeze-input"
];

(* 24. ...and it composes with a permute: 'a 1 c -> c a'. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, 1, c_}} :> {{c, a}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
  Transpose[ArrayReshape[Range[6], {2, 3}]],
  TestID -> "unit-squeeze-permute"
];

(* 25. An in-shape {} term is the unit axis (einx '()'): 'a () c -> a c' == 'a 1 c -> a c'. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, {}, c_}} :> {{a, c}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
  ArrayReshape[Range[6], {2, 3}],
  TestID -> "unit-empty-term-squeeze"
];

(* 26. ...and {} is accepted in a non-output position by the matcher (Dimensions 1). *)
VerificationTest[
  Einstoff`EinstoffMatch[{{2, {}, 3}, {2, ___}}, {{2, 1, 3}, {2, 4, 5}}]["ok"],
  True,
  TestID -> "unit-empty-term-match"
];

(* 27-30. Scalars (rank 0): squeeze/insert a singleton, no leaked ArrayReshape[s,{}]. *)
VerificationTest[
  Einstoff[ArrayReshape][{{}} :> {{}}, {7}], 7, TestID -> "scalar-identity"];
VerificationTest[
  Einstoff[ArrayReshape][{{}} :> {{1}}, {7}], {7}, TestID -> "scalar-to-singleton"];
VerificationTest[
  Einstoff[ArrayReshape][{{1}} :> {{}}, {{7}}], 7, TestID -> "singleton-to-scalar"];
VerificationTest[
  Einstoff[ArrayReduce][Total][{{}} :> {{}}, {7}], 7, TestID -> "scalar-reduce"];

(* 31. A size > 1 literal still cannot be carried even with a {} unit beside it:
   '2 () 3 -> 2 1 3' rejects (anonymous 2 and 3 have no carryable identity; einx errors). *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{2, {}, 3}} :> {{2, 1, 3}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
  $Failed,
  TestID -> "reject-literal-carry-with-unit"
];

(* 32. {} and 1 are the same unit literal even for duplicate-output broadcast:
   'a -> a {} {}' == 'a -> a 1 1' (both two unit broadcast axes). *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, {}, {}}}, {Range[2]}],
  Einstoff[ArrayReshape][{{a_}} :> {{a, 1, 1}}, {Range[2]}],
  TestID -> "unit-empty-duplicate-output"
];

EndTestSection[];
