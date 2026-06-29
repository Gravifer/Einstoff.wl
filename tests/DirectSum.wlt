(* ::Package:: *)

(* Tests for the direct-sum lowering path (CirclePlus concat; Einstoff[Join] and
   the CirclePlus branch of Einstoff[ArrayReshape]).
   One file per lowering path under tests/; cf. Reshape.wlt.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`
   so they carry section semantics. The .wlt itself does not import MUnit`. *)

BeginTestSection["Einstoff`Lowering`DirectSum"];

ClearAll[a, b, c, m];

(* ===================== concatenation (einx `+` on RHS) ============= *)

(* 1. Scalar append 'b c, -> b (c + 1)' with scalar 42 (SPEC ex4)
   === native Join of x and a constant column. *)
VerificationTest[
  With[{x = ArrayReshape[Range[15], {3, 5}]},
    Einstoff[ArrayReshape][{{b_, c_}, {}} :> {{b, CirclePlus[c, 1]}}, {x, 42}]],
  Join[ArrayReshape[Range[15], {3, 5}], ConstantArray[42, {3, 1}], 2],
  TestID -> "concat-scalar-append"
];

(* 2. Two-array concat along axis 2: 'm a, m b -> m (a + b)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}}, {x, y}]],
  Join[ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}], 2],
  TestID -> "concat-axis2"
];

(* 3. Concat along axis 1: 'a m, b m -> (a + b) m'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}], y = ArrayReshape[Range[4], {2, 2}]},
    Einstoff[ArrayReshape][{{a_, m_}, {b_, m_}} :> {{CirclePlus[a, b], m}}, {x, y}]],
  Join[ArrayReshape[Range[6], {3, 2}], ArrayReshape[Range[4], {2, 2}], 1],
  TestID -> "concat-axis1"
];

(* 4. Concat with the carrier axis permuted: 'm a, m b -> (a + b) m'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}} :> {{CirclePlus[a, b], m}}, {x, y}]],
  Join[Transpose[ArrayReshape[Range[6], {2, 3}]], Transpose[ArrayReshape[Range[8], {2, 4}]], 1],
  TestID -> "concat-carrier-permute"
];

(* 5. Three-way concat: 'm a, m b, m c -> m (a + b + c)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[2], {2, 1}], y = ArrayReshape[Range[4], {2, 2}], z = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}, {m_, c_}} :> {{m, CirclePlus[a, b, c]}}, {x, y, z}]],
  Join[ArrayReshape[Range[2], {2, 1}], ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}], 2],
  TestID -> "concat-three-way"
];

(* 6. Output dims of a concat are correct (3 + 4 along axis 2). *)
VerificationTest[
  Dimensions @ With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}}, {x, y}]],
  {2, 7},
  TestID -> "concat-dims"
];

(* 7. Einstoff[Join] is the same machinery as the ArrayReshape CirclePlus branch. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Join][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}}, {x, y}]],
  Join[ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}], 2],
  TestID -> "concat-join-operator"
];

(* ===================== rejection paths ============================= *)

(* 8. Einstoff[Join] with CirclePlus on the LHS (that is a split) is rejected. *)
VerificationTest[
  Quiet @ Einstoff[Join][{{m_, CirclePlus[a_, b_]}} :> {{m, a}, {m, b}},
    {ArrayReshape[Range[14], {2, 7}]}, {a -> 3}],
  $Failed,
  TestID -> "concat-reject-join-lhs"
];

(* 11. Operand/summand count mismatch (2 summands, 1 tensor) is rejected. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
    {ArrayReshape[Range[6], {2, 3}]}],
  $Failed,
  TestID -> "concat-reject-count"
];

(* 12. Unsatisfiable: carrier axis size disagrees between operands. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "concat-reject-unsat"
];

(* ===================== splitting (einx `+` on LHS) ================ *)

(* 13. Split into two outputs 'b (q + k) -> b q, b k', q=3 (SPEC ex3)
   === native Take of the two contiguous blocks. *)
VerificationTest[
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff[ArrayReshape][{{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}}, {x}, {q -> 3}]],
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    {Take[x, All, {1, 3}], Take[x, All, {4, 10}]}],
  TestID -> "split-two-way"
];

(* 14. Split along axis 1: '(q + k) m -> q m, k m', q=2. *)
VerificationTest[
  With[{y = ArrayReshape[Range[20], {5, 4}]},
    Einstoff[ArrayReshape][{{CirclePlus[q_, k_], m_}} :> {{q, m}, {k, m}}, {y}, {q -> 2}]],
  With[{y = ArrayReshape[Range[20], {5, 4}]},
    {Take[y, {1, 2}, All], Take[y, {3, 5}, All]}],
  TestID -> "split-axis1"
];

(* 15. Three-way split 'b (p + q + r) -> b p, b q, b r', p=2, q=3. *)
VerificationTest[
  With[{z = ArrayReshape[Range[20], {2, 10}]},
    Einstoff[ArrayReshape][{{b_, CirclePlus[p_, q_, r_]}} :> {{b, p}, {b, q}, {b, r}},
      {z}, {p -> 2, q -> 3}]],
  With[{z = ArrayReshape[Range[20], {2, 10}]},
    {Take[z, All, {1, 2}], Take[z, All, {3, 5}], Take[z, All, {6, 10}]}],
  TestID -> "split-three-way"
];

(* 16. Split then permute a block: 'b (q + k) -> q b, b k', q=3. *)
VerificationTest[
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff[ArrayReshape][{{b_, CirclePlus[q_, k_]}} :> {{q, b}, {b, k}}, {x}, {q -> 3}]],
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    {Transpose[Take[x, All, {1, 3}]], Take[x, All, {4, 10}]}],
  TestID -> "split-then-permute"
];

(* 17. Einstoff[Split] is the same machinery as the ArrayReshape LHS-CirclePlus branch. *)
VerificationTest[
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff[Split][{{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}}, {x}, {q -> 3}]],
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    {Take[x, All, {1, 3}], Take[x, All, {4, 10}]}],
  TestID -> "split-operator"
];

(* 18. Einstoff[Split] with CirclePlus on the RHS (that is a concat) is rejected. *)
VerificationTest[
  Quiet @ Einstoff[Split][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}]}],
  $Failed,
  TestID -> "split-reject-rhs"
];

(* 19. Output/summand count mismatch (2 summands, 1 output) is rejected. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{b_, CirclePlus[q_, k_]}} :> {{b, q}},
    {ArrayReshape[Range[20], {2, 10}]}, {q -> 3}],
  $Failed,
  TestID -> "split-reject-count"
];

(* 20. Underdetermined direct sum (no summand bound) is unsatisfiable. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}},
    {ArrayReshape[Range[20], {2, 10}]}],
  $Failed,
  TestID -> "split-reject-underdetermined"
];

(* ===================== nested CirclePlus (associativity) ========= *)
(* CirclePlus is associative: a ⊕ (b ⊕ c) flattens to a ⊕ b ⊕ c (order preserved,
   since CirclePlus is not Orderless). Both directions canonicalize the nesting. *)

(* 21. Right-nested concat 'm a, m b, m c -> m (a + (b + c))' === flat 3-way. *)
VerificationTest[
  With[{x = ArrayReshape[Range[2], {2, 1}], y = ArrayReshape[Range[4], {2, 2}], z = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}, {m_, c_}} :> {{m, CirclePlus[a, CirclePlus[b, c]]}}, {x, y, z}]],
  Join[ArrayReshape[Range[2], {2, 1}], ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}], 2],
  TestID -> "concat-nested-right"
];

(* 22. Left-nested concat 'm a, m b, m c -> m ((a + b) + c)' === flat 3-way. *)
VerificationTest[
  With[{x = ArrayReshape[Range[2], {2, 1}], y = ArrayReshape[Range[4], {2, 2}], z = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}, {m_, c_}} :> {{m, CirclePlus[CirclePlus[a, b], c]}}, {x, y, z}]],
  Join[ArrayReshape[Range[2], {2, 1}], ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}], 2],
  TestID -> "concat-nested-left"
];

(* 23. Nested split 'b (q + (a + k)) -> b q, b a, b k', q=2, a=3 === flat 3-way. *)
VerificationTest[
  With[{w = ArrayReshape[Range[20], {2, 10}]},
    Einstoff[ArrayReshape][{{b_, CirclePlus[q_, CirclePlus[a_, k_]]}} :> {{b, q}, {b, a}, {b, k}},
      {w}, {q -> 2, a -> 3}]],
  With[{w = ArrayReshape[Range[20], {2, 10}]},
    {Take[w, All, {1, 2}], Take[w, All, {3, 5}], Take[w, All, {6, 10}]}],
  TestID -> "split-nested"
];

EndTestSection[];
