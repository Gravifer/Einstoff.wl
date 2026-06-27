(* ::Package:: *)

(* Test suite for the Einstoff rearrange/reshape lowering (Einstoff[ArrayReshape]).
   Run via: wolframscript -file scripts/run-tests.wls *)

BeginTestSection["Einstoff`Lowering"];

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
    {{a_, Slot[b_]}} :> {{a}}, {Partition[Range[6], 3]}],
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

EndTestSection[];
