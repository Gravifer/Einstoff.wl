(* ::Package:: *)

(* Tests for the direct-sum lowering path (CirclePlus concat; Einstoff[Join] and
   the CirclePlus branch of Einstoff["Massage"]).
   One file per lowering path under tests/; cf. Reshape.wlt.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`
   so they carry section semantics. The .wlt itself does not import MUnit`. *)

BeginTestSection["Einstoff`Lowering`DirectSum"];

ClearAll[a, b, c, k, m, p, q, r];

(* ===================== concatenation (einx `+` on RHS) ============= *)

(* 1. Scalar append 'b c, -> b (c + 1)' with scalar 42 (SPEC ex4)
   === native Join of x and a constant column. *)
VerificationTest[
  With[{x = ArrayReshape[Range[15], {3, 5}]},
    Einstoff["Massage"][{{b_, c_}, {}} :> {{b, CirclePlus[c, 1]}}, {x, 42}]],
  Join[ArrayReshape[Range[15], {3, 5}], ConstantArray[42, {3, 1}], 2],
  TestID -> "concat-scalar-append"
];

(* 2. Two-array concat along axis 2: 'm a, m b -> m (a + b)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff["Massage"][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}}, {x, y}]],
  Join[ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}], 2],
  TestID -> "concat-axis2"
];

(* 3. Concat along axis 1: 'a m, b m -> (a + b) m'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}], y = ArrayReshape[Range[4], {2, 2}]},
    Einstoff["Massage"][{{a_, m_}, {b_, m_}} :> {{CirclePlus[a, b], m}}, {x, y}]],
  Join[ArrayReshape[Range[6], {3, 2}], ArrayReshape[Range[4], {2, 2}], 1],
  TestID -> "concat-axis1"
];

(* 4. Concat with the carrier axis permuted: 'm a, m b -> (a + b) m'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff["Massage"][{{m_, a_}, {m_, b_}} :> {{CirclePlus[a, b], m}}, {x, y}]],
  Join[Transpose[ArrayReshape[Range[6], {2, 3}]], Transpose[ArrayReshape[Range[8], {2, 4}]], 1],
  TestID -> "concat-carrier-permute"
];

(* 5. Three-way concat: 'm a, m b, m c -> m (a + b + c)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[2], {2, 1}], y = ArrayReshape[Range[4], {2, 2}], z = ArrayReshape[Range[6], {2, 3}]},
    Einstoff["Massage"][{{m_, a_}, {m_, b_}, {m_, c_}} :> {{m, CirclePlus[a, b, c]}}, {x, y, z}]],
  Join[ArrayReshape[Range[2], {2, 1}], ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}], 2],
  TestID -> "concat-three-way"
];

(* 6. Output dims of a concat are correct (3 + 4 along axis 2). *)
VerificationTest[
  Dimensions @ With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff["Massage"][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}}, {x, y}]],
  {2, 7},
  TestID -> "concat-dims"
];

(* 7. Einstoff[Join] is the same machinery as the Massage RHS-CirclePlus branch. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Join][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}}, {x, y}]],
  Join[ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}], 2],
  TestID -> "concat-join-operator"
];

(* ===================== rejection paths ============================= *)

(* 8. Einstoff[Join] with CirclePlus on the LHS (that is a split) is rejected. *)
VerificationTest[
  Quiet @ Einstoff[Join][{{m_, CirclePlus["a", b_]}} :> {{m, "a"}, {m, b}},
    {ArrayReshape[Range[14], {2, 7}]}, {"a" -> 3}],
  $Failed,
  TestID -> "concat-reject-join-lhs"
];

(* 11. Operand/summand count mismatch (2 summands, 1 tensor) is rejected. *)
VerificationTest[
  Quiet @ Einstoff["Massage"][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
    {ArrayReshape[Range[6], {2, 3}]}],
  $Failed,
  TestID -> "concat-reject-count"
];

(* 12. Unsatisfiable: carrier axis size disagrees between operands. *)
VerificationTest[
  Quiet @ Einstoff["Massage"][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  $Failed,
  TestID -> "concat-reject-unsat"
];

(* 12b. A name repeated within an input shape ('a' in operand 1) is within-tensor
   contraction, which the direct-sum path cannot do — rejected by its own guard.  The
   output {{m, a (+) b}} is duplicate-free, so EinstoffShapes is Satisfiable and the
   rejection is the concat guard's alone (without it the desc reaches lowering and
   mis-reshapes — verified, so this test isolates the guard).  Carrier 'm' shared across
   operands is fine (firstDuplicateAxis is per-shape). *)
VerificationTest[
  Quiet @ Einstoff[Join][{{m_, a_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
    {ArrayReshape[Range[8], {2, 2, 2}], ArrayReshape[Range[6], {2, 3}]}],
  $Failed,
  TestID -> "concat-reject-repeated-input-axis"
];

(* ===================== splitting (einx `+` on LHS) ================ *)

(* 13. Split into two outputs 'b (q + k) -> b q, b k', q=3 (SPEC ex3)
   === native Take of the two contiguous blocks. *)
VerificationTest[
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus["q", k_]}} :> {{b, "q"}, {b, k}}, {x}, {"q" -> 3}]],
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    {Take[x, All, {1, 3}], Take[x, All, {4, 10}]}],
  TestID -> "split-two-way"
];

(* 13b-c. Pattern blanks inside composites remain inference-only: external bare
   and slot keys do not bind q_ in q_ (+) k_. *)
VerificationTest[
  Quiet @ With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}}, {x}, {q -> 3}]],
  $Failed,
  TestID -> "split-reject-composite-blank-bare-binding"
];
VerificationTest[
  Quiet @ With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}}, {x}, {Slot["q"] -> 3}]],
  $Failed,
  TestID -> "split-reject-composite-blank-slot-binding"
];

(* 13d. Slot keys do not bind string-tier composite factors. *)
VerificationTest[
  Quiet @ With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus["q", k_]}} :> {{b, "q"}, {b, k}}, {x}, {Slot["q"] -> 3}]],
  $Failed,
  TestID -> "split-reject-string-factor-slot-binding"
];

(* 13e-g. Bare composite factors are explicitly bindable, including the normal
   contradictory-binding path. *)
VerificationTest[
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus[q, k_]}} :> {{b, q}, {b, k}}, {x}, {q -> 3}]],
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    {Take[x, All, {1, 3}], Take[x, All, {4, 10}]}],
  TestID -> "split-bare-factor-binding-ok"
];
VerificationTest[
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus[q, k]}} :> {{b, q}, {b, k}}, {x}, {q -> 3, k -> 7}]],
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    {Take[x, All, {1, 3}], Take[x, All, {4, 10}]}],
  TestID -> "split-bare-factor-both-bindings-ok"
];
VerificationTest[
  Quiet @ With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus[q, k]}} :> {{b, q}, {b, k}}, {x}, {q -> 3, k -> 8}]],
  $Failed,
  TestID -> "split-bare-factor-contradictory-bindings"
];

(* 14. Split along axis 1: '(q + k) m -> q m, k m', q=2. *)
VerificationTest[
  With[{y = ArrayReshape[Range[20], {5, 4}]},
    Einstoff["Massage"][{{CirclePlus["q", k_], m_}} :> {{"q", m}, {k, m}}, {y}, {"q" -> 2}]],
  With[{y = ArrayReshape[Range[20], {5, 4}]},
    {Take[y, {1, 2}, All], Take[y, {3, 5}, All]}],
  TestID -> "split-axis1"
];

(* 15. Three-way split 'b (p + q + r) -> b p, b q, b r', p=2, q=3. *)
VerificationTest[
  With[{z = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus["p", "q", r_]}} :> {{b, "p"}, {b, "q"}, {b, r}},
      {z}, {"p" -> 2, "q" -> 3}]],
  With[{z = ArrayReshape[Range[20], {2, 10}]},
    {Take[z, All, {1, 2}], Take[z, All, {3, 5}], Take[z, All, {6, 10}]}],
  TestID -> "split-three-way"
];

(* 16. Split then permute a block: 'b (q + k) -> q b, b k', q=3. *)
VerificationTest[
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus["q", k_]}} :> {{"q", b}, {b, k}}, {x}, {"q" -> 3}]],
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    {Transpose[Take[x, All, {1, 3}]], Take[x, All, {4, 10}]}],
  TestID -> "split-then-permute"
];

(* 17. Einstoff[Split] is the same machinery as the Massage LHS-CirclePlus branch. *)
VerificationTest[
  With[{x = ArrayReshape[Range[20], {2, 10}]},
    Einstoff[Split][{{b_, CirclePlus["q", k_]}} :> {{b, "q"}, {b, k}}, {x}, {"q" -> 3}]],
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
  Quiet @ Einstoff["Massage"][{{b_, CirclePlus["q", k_]}} :> {{b, "q"}},
    {ArrayReshape[Range[20], {2, 10}]}, {"q" -> 3}],
  $Failed,
  TestID -> "split-reject-count"
];

(* 20. Underdetermined direct sum (no summand bound) is unsatisfiable. *)
VerificationTest[
  Quiet @ Einstoff["Massage"][{{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}},
    {ArrayReshape[Range[20], {2, 10}]}],
  $Failed,
  TestID -> "split-reject-underdetermined"
];

(* 20b. A name repeated within the input shape ('b' as a carried axis) is within-tensor
   contraction, which the split path cannot do — rejected by its own guard.  Each output
   {{b, q}, {b, k}} is duplicate-free, so EinstoffShapes is Satisfiable and the rejection
   is the split guard's alone (without it the desc reaches lowering and mis-slices —
   verified, so this test isolates the guard).  (A repeated direct-sum *summand* q (+) q
   is a distinct, deferred equal-split case; here the repeat is a carried axis.) *)
VerificationTest[
  Quiet @ Einstoff[Split][{{b_, b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}},
    {ArrayReshape[Range[20], {2, 2, 5}]}, {"q" -> 2}],
  $Failed,
  TestID -> "split-reject-repeated-input-axis"
];

(* ===================== nested CirclePlus (associativity) ========= *)
(* CirclePlus is associative: a ⊕ (b ⊕ c) flattens to a ⊕ b ⊕ c (order preserved,
   since CirclePlus is not Orderless). Both directions canonicalize the nesting. *)

(* 21. Right-nested concat 'm a, m b, m c -> m (a + (b + c))' === flat 3-way. *)
VerificationTest[
  With[{x = ArrayReshape[Range[2], {2, 1}], y = ArrayReshape[Range[4], {2, 2}], z = ArrayReshape[Range[6], {2, 3}]},
    Einstoff["Massage"][{{m_, a_}, {m_, b_}, {m_, c_}} :> {{m, CirclePlus[a, CirclePlus[b, c]]}}, {x, y, z}]],
  Join[ArrayReshape[Range[2], {2, 1}], ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}], 2],
  TestID -> "concat-nested-right"
];

(* 22. Left-nested concat 'm a, m b, m c -> m ((a + b) + c)' === flat 3-way. *)
VerificationTest[
  With[{x = ArrayReshape[Range[2], {2, 1}], y = ArrayReshape[Range[4], {2, 2}], z = ArrayReshape[Range[6], {2, 3}]},
    Einstoff["Massage"][{{m_, a_}, {m_, b_}, {m_, c_}} :> {{m, CirclePlus[CirclePlus[a, b], c]}}, {x, y, z}]],
  Join[ArrayReshape[Range[2], {2, 1}], ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}], 2],
  TestID -> "concat-nested-left"
];

(* 23. Nested split 'b (q + (a + k)) -> b q, b a, b k', q=2, a=3 === flat 3-way. *)
VerificationTest[
  With[{w = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{b_, CirclePlus["q", CirclePlus["a", k_]]}} :> {{b, "q"}, {b, "a"}, {b, k}},
      {w}, {"q" -> 2, "a" -> 3}]],
  With[{w = ArrayReshape[Range[20], {2, 10}]},
    {Take[w, All, {1, 2}], Take[w, All, {3, 5}], Take[w, All, {6, 10}]}],
  TestID -> "split-nested"
];

(* ===================== composite summands (concat) =============== *)
(* A direct-sum summand may be a product block (a CircleTimes), e.g. (a⊗b) ⊕ c.
   Supported in BOTH directions: concat here, and split below (the CAS matcher
   solveComposite resolves the block's factor sizes; see SPEC §9). *)

(* 24. Composite block whose operand is pre-merged: 'm (a b), m c -> m ((a b) + c)', a=2. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {2, 6}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff["Massage"][{{m_, CircleTimes["a", b_]}, {m_, c_}} :> {{m, CirclePlus[CircleTimes["a", b], c]}},
      {x, y}, {"a" -> 2}]],
  Join[ArrayReshape[Range[12], {2, 6}], ArrayReshape[Range[8], {2, 4}], 2],
  TestID -> "concat-composite-merged-operand"
];

(* 25. Composite block whose operand has separate axes: 'm a b, m c -> m ((a b) + c)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[12], {2, 2, 3}], y = ArrayReshape[Range[8], {2, 4}]},
    Einstoff["Massage"][{{m_, a_, b_}, {m_, c_}} :> {{m, CirclePlus[CircleTimes[a, b], c]}}, {x, y}]],
  Join[ArrayReshape[Range[12], {2, 6}], ArrayReshape[Range[8], {2, 4}], 2],
  TestID -> "concat-composite-split-operand"
];

(* 26. Composite block in the second position: 'm c, m (a b) -> m (c + (a b))', a=2. *)
VerificationTest[
  With[{y = ArrayReshape[Range[8], {2, 4}], x = ArrayReshape[Range[12], {2, 6}]},
    Einstoff["Massage"][{{m_, c_}, {m_, CircleTimes["a", b_]}} :> {{m, CirclePlus[c, CircleTimes["a", b]]}},
      {y, x}, {"a" -> 2}]],
  Join[ArrayReshape[Range[8], {2, 4}], ArrayReshape[Range[12], {2, 6}], 2],
  TestID -> "concat-composite-second"
];

(* 27. A targeted (Slot) summand is not a product block -> rejected. *)
VerificationTest[
  Quiet @ Einstoff["Massage"][{{m_, Slot["a"]}, {m_, c_}} :> {{m, CirclePlus[Slot["a"], c]}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}]}],
  $Failed,
  TestID -> "concat-reject-slot-summand"
];

(* ===================== composite summands (split) =============== *)
(* Splitting a product block needs the block's factors bound so the matcher can
   determine the remaining summand. The CAS (Solve over positive integers) handles
   the arithmetic — and resolves any system the integers pin uniquely (see #31). *)

(* 28. Split a product block: 'm ((a b) + c) -> m (a b), m c', a=2, b=3 (=> c=4). *)
VerificationTest[
  With[{z = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{m_, CirclePlus[CircleTimes["a", "b"], c_]}} :> {{m, CircleTimes["a", "b"]}, {m, c}},
      {z}, {"a" -> 2, "b" -> 3}]],
  With[{z = ArrayReshape[Range[20], {2, 10}]},
    {Take[z, All, {1, 6}], Take[z, All, {7, 10}]}],
  TestID -> "split-composite"
];

(* 29. Split a product block, expanding it to separate output axes:
   'm ((a b) + c) -> m a b, m c', a=2, b=3. *)
VerificationTest[
  With[{z = ArrayReshape[Range[20], {2, 10}]},
    Einstoff["Massage"][{{m_, CirclePlus[CircleTimes["a", "b"], c_]}} :> {{m, "a", "b"}, {m, c}},
      {z}, {"a" -> 2, "b" -> 3}]],
  With[{z = ArrayReshape[Range[20], {2, 10}]},
    {ArrayReshape[Take[z, All, {1, 6}], {2, 2, 3}], Take[z, All, {7, 10}]}],
  TestID -> "split-composite-expand"
];

(* 30. Composite split underdetermined (only a bound, 2b + c = 10) is rejected. *)
VerificationTest[
  Quiet @ Einstoff["Massage"][{{m_, CirclePlus[CircleTimes["a", b_], c_]}} :> {{m, "a", b}, {m, c}},
    {ArrayReshape[Range[20], {2, 10}]}, {"a" -> 2}],
  $Failed,
  TestID -> "split-composite-reject-underdetermined"
];

(* 31. The CAS uniquely resolves a system einx rejects: 'm (a + b) -> m a, m b'
   with no bindings and an axis of size 2 forces a = b = 1. *)
VerificationTest[
  With[{w = ArrayReshape[Range[4], {2, 2}]},
    Einstoff["Massage"][{{m_, CirclePlus[a_, b_]}} :> {{m, a}, {m, b}}, {w}]],
  With[{w = ArrayReshape[Range[4], {2, 2}]},
    {Take[w, All, {1, 1}], Take[w, All, {2, 2}]}],
  TestID -> "split-cas-unique"
];

(* 32. Split with an integer summand, the singleton block SQUEEZED to {b}:
   'b (q + 1) -> b q, b', q=3 over a size-4 axis (cf. einx). *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff["Massage"][{{b_, CirclePlus[q_, 1]}} :> {{b, q}, {b}}, {x}]],
  {{{1, 2, 3}, {5, 6, 7}}, {4, 8}},
  TestID -> "split-integer-summand-squeeze"
];

(* 33. ...or the singleton block PRESERVED as {b, 1} when explicitly requested. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff["Massage"][{{b_, CirclePlus[q_, 1]}} :> {{b, q}, {b, 1}}, {x}]],
  {{{1, 2, 3}, {5, 6, 7}}, {{4}, {8}}},
  TestID -> "split-integer-summand-preserve"
];

(* 34. An integer summand of size > 1 cannot be squeezed to {b} (it would lose data)
   — rejected cleanly, not leaked. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Quiet @ Einstoff["Massage"][{{b_, CirclePlus[q_, 2]}} :> {{b, q}, {b}}, {x}]],
  $Failed,
  TestID -> "split-integer-summand-oversized-reject"
];

(* 35. ...nor can a size > 1 literal summand be PRESERVED as {b, 2}: a literal axis is
   anonymous and has no carryable identity, so it cannot be matched between input and
   output — exactly as einx rejects 'b (q + 2) -> b q, b 2' ("input axes {unnamed} must
   appear in the output").  Only size-1 (unit) literals are special (tests 32-33). *)
VerificationTest[
  With[{x = ArrayReshape[Range[10], {2, 5}]},
    Quiet @ Einstoff["Massage"][{{b_, CirclePlus[q_, 2]}} :> {{b, q}, {b, 2}}, {x}]],
  $Failed,
  TestID -> "split-integer-summand-preserve-reject"
];

(* 36. The escape hatch is to NAME the summand, giving it an identity to carry:
   'b (q + k) -> b q, b k' with k = 2 works (einx accepts this), as the basic split. *)
VerificationTest[
  With[{x = ArrayReshape[Range[10], {2, 5}]},
    Einstoff["Massage"][{{b_, CirclePlus[q, k]}} :> {{b, q}, {b, k}}, {x}, {q -> 3, k -> 2}]],
  With[{x = ArrayReshape[Range[10], {2, 5}]},
    {Take[x, All, {1, 3}], Take[x, All, {4, 5}]}],
  TestID -> "split-named-summand-carries"
];

(* 37-38. A {} summand is the unit literal 1 (einx '()'): concat 'b c, -> b (c + ())'
   and split 'b (q + ()) -> b q, b' behave exactly like the literal-1 forms. *)
VerificationTest[
  Einstoff["Massage"][{{b_, c_}, {}} :> {{b, CirclePlus[c, {}]}},
    {ArrayReshape[Range[6], {2, 3}], 42}],
  Einstoff["Massage"][{{b_, c_}, {}} :> {{b, CirclePlus[c, 1]}},
    {ArrayReshape[Range[6], {2, 3}], 42}],
  TestID -> "concat-unit-empty-summand"
];
VerificationTest[
  Einstoff["Massage"][{{b_, CirclePlus[q_, {}]}} :> {{b, q}, {b}},
    {ArrayReshape[Range[8], {2, 4}]}],
  Einstoff["Massage"][{{b_, CirclePlus[q_, 1]}} :> {{b, q}, {b}},
    {ArrayReshape[Range[8], {2, 4}]}],
  TestID -> "split-unit-empty-summand"
];

(* 39. Split must NOT silently drop a NAMED size > 1 summand: 'b (q + k) -> b q, b'
   with k = 2 would truncate the second block (data loss) — reject centrally.  (Only
   a size-1 unit summand may be squeezed, tests 32/38; name+carry it via test 36.) *)
VerificationTest[
  Quiet @ Einstoff["Massage"][{{b_, CirclePlus[q, k]}} :> {{b, q}, {b}},
    {ArrayReshape[Range[10], {2, 5}]}, {q -> 3, k -> 2}],
  $Failed,
  TestID -> "split-drop-named-summand-reject"
];

(* 40. Concat must NOT silently drop a size > 1 operand axis into a size-1 summand:
   'b c, b k -> b (c + 1)' discards most of the second operand — reject. *)
VerificationTest[
  Quiet @ Einstoff["Massage"][{{b_, c_}, {b_, k_}} :> {{b, CirclePlus[c, 1]}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[10 + Range[4], {2, 2}]}],
  $Failed,
  TestID -> "concat-drop-operand-axis-reject"
];

EndTestSection[];
