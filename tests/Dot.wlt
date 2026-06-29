(* ::Package:: *)

(* Tests for the dot/contraction lowering path (Einstoff[Dot]).
   One file per lowering path under tests/; cf. Reshape.wlt, Reduce.wlt.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`
   so they carry section semantics. The .wlt itself does not import MUnit`. *)

BeginTestSection["Einstoff`Lowering`Dot"];

ClearAll[a, b, c, d, e, n, r];

(* ===================== einsum-style contraction (einx.dot) ========= *)

(* 1. Plain matmul 'a b, b c -> a c' === native Dot. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Dot][{{a_, b_}, {b, c_}} :> {{a, c}}, {x, y}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}],
  TestID -> "dot-matmul-bare"
];

(* 2. Bracketed matmul 'a [b], [b] c -> a c' (SPEC ex 10) === native Dot. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Dot][{{a_, Slot[b_]}, {Slot[b], c_}} :> {{a, c}}, {x, y}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}],
  TestID -> "dot-matmul-bracket"
];

(* 3. Batched matmul 'a b c, a c d -> a b d' === MapThread[Dot]. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
    Einstoff[Dot][{{a_, b_, c_}, {a, c, d_}} :> {{a, b, d}}, {x, y}]],
  MapThread[Dot, {ArrayReshape[Range[24], {2, 3, 4}], ArrayReshape[Range[40], {2, 4, 5}]}],
  TestID -> "dot-batched"
];

(* 4. Outer product 'a, b -> a b' (no contracted axis). *)
VerificationTest[
  Einstoff[Dot][{{a_}, {b_}} :> {{a, b}}, {Range[2], Range[3]}],
  Outer[Times, Range[2], Range[3]],
  TestID -> "dot-outer"
];

(* 5. Inner product 'a, a -> ' contracts everything to a scalar. *)
VerificationTest[
  Einstoff[Dot][{{a_}, {a}} :> {{}}, {Range[3], Range[3]}],
  Range[3] . Range[3],
  TestID -> "dot-inner-scalar"
];

(* 6. Contract then merge survivors 'a b, b c -> (a c)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Dot][{{a_, Slot[b_]}, {Slot[b], c_}} :> {{CircleTimes[a, c]}}, {x, y}]],
  Flatten[ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}]],
  TestID -> "dot-contract-merge"
];

(* 7. Batched + permuted survivors 'a b c, a c d -> a d b'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
    Einstoff[Dot][{{a_, b_, c_}, {a, c, d_}} :> {{a, d, b}}, {x, y}]],
  Transpose[MapThread[Dot, {ArrayReshape[Range[24], {2, 3, 4}], ArrayReshape[Range[40], {2, 4, 5}]}], {1, 3, 2}],
  TestID -> "dot-batched-permute"
];

(* 8. Output dims of batched matmul are correct. *)
VerificationTest[
  Dimensions @ With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
    Einstoff[Dot][{{a_, b_, c_}, {a, c, d_}} :> {{a, b, d}}, {x, y}]],
  {2, 3, 5},
  TestID -> "dot-batched-dims"
];

(* ===================== rejection paths ============================= *)

(* 9. Three input tensors are rejected (first cut is two-operand). *)
VerificationTest[
  Quiet @ Einstoff[Dot][{{a_, b_}, {b, c_}} :> {{a, c}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}], ArrayReshape[Range[6], {2, 3}]}],
  $Failed,
  TestID -> "dot-reject-three-tensor"
];

(* 10. A single-operand axis dropped before contraction is rejected. *)
VerificationTest[
  Quiet @ Einstoff[Dot][{{a_, b_}, {b, c_}} :> {{a}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "dot-reject-within-drop"
];

(* 11. A new output axis is repetition (SPEC 5.5); unbound it is rejected. *)
VerificationTest[
  Quiet @ Einstoff[Dot][{{a_, b_}, {b, c_}} :> {{a, c, d}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "dot-reject-unbound-repeat"
];

(* 12. Unsatisfiable desc (shared axis size disagrees) returns $Failed. *)
VerificationTest[
  Quiet @ Einstoff[Dot][{{a_, b_}, {b, c_}} :> {{a, c}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[20], {5, 4}]}],
  $Failed,
  TestID -> "dot-reject-unsat"
];

(* ===================== contract then repeat (SPEC 5.5) =========== *)

(* 13. Matmul, then broadcast the result into a new axis r: 'a [b], [b] c -> a c r', r=2. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Dot][{{a_, Slot[b_]}, {Slot[b], c_}} :> {{a, c, r}}, {x, y}, {r -> 2}]],
  With[{mm = ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}]},
    Table[mm[[i, j]], {i, 2}, {j, 4}, {k, 2}]],
  TestID -> "dot-then-repeat"
];

(* ===================== variadic (N operands) ===================== *)

(* 14. Three-operand chain 'a b, b c, c d -> a d' === iterated native Dot. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}], z = ArrayReshape[Range[20], {4, 5}]},
    Einstoff[Dot][{{a_, b_}, {b_, c_}, {c_, d_}} :> {{a, d}}, {x, y, z}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}] . ArrayReshape[Range[20], {4, 5}],
  TestID -> "dot-three-chain"
];

(* 15. Four-operand chain 'a b, b c, c d, d e -> a e'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}],
        z = ArrayReshape[Range[20], {4, 5}], w = ArrayReshape[Range[10], {5, 2}]},
    Einstoff[Dot][{{a_, b_}, {b_, c_}, {c_, d_}, {d_, e_}} :> {{a, e}}, {x, y, z, w}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}] .
    ArrayReshape[Range[20], {4, 5}] . ArrayReshape[Range[10], {5, 2}],
  TestID -> "dot-four-chain"
];

(* 16. Bracketed three-operand chain 'a [b], [b] [c], [c] d -> a d'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}], z = ArrayReshape[Range[20], {4, 5}]},
    Einstoff[Dot][{{a_, Slot[b_]}, {Slot[b], Slot[c_]}, {Slot[c], d_}} :> {{a, d}}, {x, y, z}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}] . ArrayReshape[Range[20], {4, 5}],
  TestID -> "dot-three-chain-bracketed"
];

(* 17. Batched three-operand 'n a b, n b c, n c d -> n a d'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}], z = ArrayReshape[Range[20], {2, 5, 2}]},
    Einstoff[Dot][{{n_, a_, b_}, {n_, b_, c_}, {n_, c_, d_}} :> {{n, a, d}}, {x, y, z}]],
  MapThread[Dot[#1, #2, #3] &,
    {ArrayReshape[Range[24], {2, 3, 4}], ArrayReshape[Range[40], {2, 4, 5}], ArrayReshape[Range[20], {2, 5, 2}]}],
  TestID -> "dot-batched-three"
];

(* 18. Scalar intermediate 'a, a, b -> b' = (x·y) * z, exercising the fold's
   scalar-operand path. *)
VerificationTest[
  Einstoff[Dot][{{a_}, {a_}, {b_}} :> {{b}}, {Range[3], Range[3], Range[4]}],
  (Range[3] . Range[3]) Range[4],
  TestID -> "dot-scalar-intermediate"
];

(* 19. One input tensor is rejected (Dot needs >= 2). *)
VerificationTest[
  Quiet @ Einstoff[Dot][{{a_, b_}} :> {{a, b}}, {ArrayReshape[Range[6], {2, 3}]}],
  $Failed,
  TestID -> "dot-reject-one-tensor"
];

EndTestSection[];
