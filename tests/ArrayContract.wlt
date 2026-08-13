(* ::Package:: *)

(* Tests for Einstoff["ArrayContract"] / EinstoffContract — the within-tensor
   contraction entrance.  It is the "no-repetition" policy over the shared Massage
   core: everything the bijective Einstoff[ArrayReshape] allows (permute/split/merge,
   unit-axis insert/squeeze) PLUS within-tensor pairwise contraction (a repeated,
   dropped input axis summed over its coincident slots).  It rejects repetition (an
   output-only axis of size > 1) and direct sum; a plain single-index sum-reduction is
   out of scope (Einstoff[ArrayReduce]).  Cross-checked against native WL
   TensorContract / Tr and against Einstoff["Massage"] / Einstoff["einsum"].
   Run via: wolframscript -script scripts/run-tests.wls *)

BeginTestSection["Gravifer`Einstoff`Lowering`ArrayContract"];

ClearAll[a, b, c, d];

(* ===================== within-tensor contraction ================== *)

(* 1. Partial trace 'a b a d -> b d' (Ricci-style) === TensorContract. *)
VerificationTest[
  With[{R = ArrayReshape[Range[16], {2, 2, 2, 2}]},
    Einstoff["ArrayContract"][{{a_, b_, a_, d_}} :> {{b, d}}, {R}]],
  TensorContract[ArrayReshape[Range[16], {2, 2, 2, 2}], {{1, 3}}],
  TestID -> "contract-partial-trace"
];

(* 2. Full trace 'a a ->' === Tr. *)
VerificationTest[
  With[{T = ArrayReshape[Range[9], {3, 3}]},
    Einstoff["ArrayContract"][{{a_, a_}} :> {{}}, {T}]],
  Tr[ArrayReshape[Range[9], {3, 3}]],
  TestID -> "contract-full-trace"
];

(* 3. Partial trace then permute 'a b a d -> d b'. *)
VerificationTest[
  With[{R = ArrayReshape[Range[16], {2, 2, 2, 2}]},
    Einstoff["ArrayContract"][{{a_, b_, a_, d_}} :> {{d, b}}, {R}]],
  Transpose[TensorContract[ArrayReshape[Range[16], {2, 2, 2, 2}], {{1, 3}}]],
  TestID -> "contract-trace-permute"
];

(* 4. Agrees with the permissive Massage engine on a contraction desc. *)
VerificationTest[
  With[{R = ArrayReshape[Range[16], {2, 2, 2, 2}]},
    Einstoff["ArrayContract"][{{a_, b_, a_, d_}} :> {{b, d}}, {R}] ===
      Einstoff["Massage"][{{a_, b_, a_, d_}} :> {{b, d}}, {R}]],
  True,
  TestID -> "contract-agrees-with-massage"
];

(* 5. ...and with the single-tensor einsum entrance (which routes through here). *)
VerificationTest[
  With[{R = ArrayReshape[Range[16], {2, 2, 2, 2}]},
    Einstoff["ArrayContract"][{{a_, b_, a_, d_}} :> {{b, d}}, {R}] ===
      Einstoff["einsum"][{{a_, b_, a_, d_}} :> {{b, d}}, {R}]],
  True,
  TestID -> "contract-agrees-with-einsum"
];

(* ===================== bijective transforms are a subset ========== *)

(* 6. A pure permute (no contraction) is allowed — ArrayContract ⊇ ArrayReshape. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Einstoff["ArrayContract"][{{a_, b_}} :> {{b, a}}, {x}]],
  Transpose[ArrayReshape[Range[6], {2, 3}]],
  TestID -> "contract-permute-ok"
];

(* 7. Unit-axis squeeze 'a 1 c -> a c' is allowed (count-preserving). *)
VerificationTest[
  Einstoff["ArrayContract"][{{a_, 1, c_}} :> {{a, c}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
  ArrayReshape[Range[6], {2, 3}],
  TestID -> "contract-unit-squeeze-ok"
];

(* ===================== rejection paths ============================ *)

(* 8. Repetition (an output-only axis of size > 1) is rejected — that is Massage. *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{a_}} :> {{a, c}}, {Range[3]}, {c -> 2}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-reject-repeat"
];

(* 9. A literal-integer output axis is likewise repetition (broadcast). *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{a_}} :> {{a, 2}}, {Range[3]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-reject-output-integer"
];

(* 10. A direct sum belongs to Einstoff[Join]/[Split], not the contraction entrance. *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}},
      {ArrayReshape[Range[20], {2, 10}]}, {q -> 3}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-reject-direct-sum"
];

(* 11. A single dropped index (plain sum-reduction) is out of scope -> ArrayReduce. *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{a_, b_}} :> {{a}}, {ArrayReshape[Range[6], {2, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-reject-single-drop"
];

(* 12. A repeated index KEPT on the output (a diagonal) is deferred (rejected). *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{a_, a_}} :> {{a}}, {ArrayReshape[Range[9], {3, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-reject-diagonal"
];

(* 13. An index occurring more than twice (super-diagonal) is non-tensorial -> rejected. *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{a_, a_, a_}} :> {{}}, {ArrayReshape[Range[27], {3, 3, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-reject-super-diagonal"
];

(* 14. Automatic mode allows a targeted pair to contract while an untargeted occurrence
   of the same axis carries the output. *)
VerificationTest[
  With[{t = ArrayReshape[Range[27], {3, 3, 3}]},
    Einstoff["ArrayContract"][{{"a", Highlighted["a"], Highlighted["a"]}} :> {{"a"}}, {t}]],
  With[{t = ArrayReshape[Range[27], {3, 3, 3}]},
    Table[Sum[t[[i, j, j]], {j, 3}], {i, 3}]],
  TestID -> "contract-targeting-auto-targeted-pair-kept-carrier"
];

(* 15. False mode ignores target roles, so the same three occurrences remain a
   rejected diagonal/super-diagonal shape. *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{"a", Highlighted["a"], Highlighted["a"]}} :> {{"a"}},
      {ArrayReshape[Range[27], {3, 3, 3}]}, {}, "Targeting" -> False],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-targeting-false-reject-targeted-pair-kept-carrier"
];

(* 16. True mode requires explicit targets for within-tensor contraction. *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{a_, b_, a_}} :> {{b}},
      {ArrayReshape[Range[18], {3, 2, 3}]}, {}, "Targeting" -> True],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-targeting-true-reject-bare-repeat"
];

(* 17. Multi-tensor input is a cross-tensor path, not within-tensor contraction. *)
VerificationTest[
  Quiet[
    Einstoff["ArrayContract"][{{a_, b_}, {b_, c_}} :> {{a, c}},
      {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "contract-reject-multitensor"
];

EndTestSection[];
