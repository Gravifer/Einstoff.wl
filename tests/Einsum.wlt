(* ::Package:: *)

(* Tests for Einstoff["einsum"] — the pairwise-contraction subset of einsum.
   Within-tensor contraction (repeated dropped index) for one tensor, cross-tensor
   contraction for several.  Validated against native WL (TensorContract / Tr / Dot);
   einops.einsum / np.einsum cross-validation lives in tests/python/Einsum.wlt.
   Run via: wolframscript -script scripts/run-tests.wls *)

BeginTestSection["Einstoff`Lowering`Einsum"];

ClearAll[a, b, c, d];

(* 1. Within-tensor partial trace 'a b a d -> b d' (Ricci-style) === TensorContract. *)
VerificationTest[
  With[{R = ArrayReshape[Range[16], {2, 2, 2, 2}]},
    Einstoff["einsum"][{{a_, b_, a_, d_}} :> {{b, d}}, {R}]],
  TensorContract[ArrayReshape[Range[16], {2, 2, 2, 2}], {{1, 3}}],
  TestID -> "einsum-partial-trace"
];

(* 2. Full trace 'a a ->' === Tr. *)
VerificationTest[
  With[{T = ArrayReshape[Range[9], {3, 3}]},
    Einstoff["einsum"][{{a_, a_}} :> {{}}, {T}]],
  Tr[ArrayReshape[Range[9], {3, 3}]],
  TestID -> "einsum-full-trace"
];

(* 3. Partial trace then permute 'a b a d -> d b'. *)
VerificationTest[
  With[{R = ArrayReshape[Range[16], {2, 2, 2, 2}]},
    Einstoff["einsum"][{{a_, b_, a_, d_}} :> {{d, b}}, {R}]],
  Transpose[TensorContract[ArrayReshape[Range[16], {2, 2, 2, 2}], {{1, 3}}]],
  TestID -> "einsum-trace-permute"
];

(* 4. Cross-tensor matmul 'a b, b c -> a c' === Dot. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff["einsum"][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}],
  TestID -> "einsum-matmul"
];

(* 5. ...and agrees with Einstoff[Dot] on the same desc. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff["einsum"][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}] ===
      Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]],
  True,
  TestID -> "einsum-agrees-with-dot"
];

(* 6. A repeated index kept on the output (diagonal) is rejected — deferred. *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_, a_}} :> {{a}}, {ArrayReshape[Range[9], {3, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-diagonal"
];

(* 7. An index occurring more than twice (super-diagonal) is rejected — non-tensorial. *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_, a_, a_}} :> {{}}, {ArrayReshape[Range[27], {3, 3, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-super-diagonal"
];

(* 8. A single dropped index (sum-reduction) is out of the contraction subset. *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_, b_}} :> {{a}}, {ArrayReshape[Range[6], {2, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-single-drop"
];

(* 9. A new output axis (repetition / broadcast) is rejected. *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_}} :> {{a, c}}, {Range[3]}, {c -> 2}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-repetition"
];

(* 10. A within-operand repeat in a multi-tensor desc is deferred (rejected). *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_, a_}, {a_, c_}} :> {{c}},
      {ArrayReshape[Range[9], {3, 3}], ArrayReshape[Range[6], {3, 2}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-mixed-multitensor"
];

(* 11. A literal integer output axis is also repetition (broadcast) — rejected,
   single- and multi-tensor (output integers count as repetition, Reshape.wlt §15). *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_}} :> {{a, 2}}, {Range[3]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-literal-repetition"
];
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_}, {b_}} :> {{a, b, 2}}, {Range[3], Range[4]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-literal-repetition-multi"
];

(* 13. einsum rejects ANY literal output axis, even one matching an input literal
   (numpy.einsum has no integer subscripts; a literal output is broadcast, not einsum). *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_, 2}} :> {{a, 2}}, {ArrayReshape[Range[6], {3, 2}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-literal-on-input"
];

(* 14. Multi-tensor: a size > 1 literal is not a shared contraction identity — reject
   'a 2, 2 b -> a b' (matches einx.dot). *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_, 2}, {2, b_}} :> {{a, b}},
      {ArrayReshape[Range[6], {3, 2}], ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-shared-literal"
];

(* 15. A contracted axis in >2 operands is an N-way super-diagonal — reject
   'a, a, a ->' (einx.dot: contracted axes must appear in exactly two inputs). *)
VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_}, {a_}, {a_}} :> {{}}, {Range[3], Range[3], Range[3]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-reject-nary-contraction"
];

VerificationTest[
  Quiet[
    Einstoff["einsum"][{{a_}, {a_}} :> {{}}, {Range[3], Range[3]}, {},
      "Targeting" -> "invalid"],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "einsum-invalid-targeting-uses-shared-boundary"
];

EndTestSection[];
