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
    Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}],
  TestID -> "dot-matmul-bare"
];

(* 2. Bracketed matmul 'a [b], [b] c -> a c' (SPEC ex 10) === native Dot. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Dot][{{a_, Highlighted[b_]}, {Highlighted[b_], c_}} :> {{a, c}}, {x, y}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}],
  TestID -> "dot-matmul-bracket"
];

(* 3. Batched matmul 'a b c, a c d -> a b d' === MapThread[Dot]. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
    Einstoff[Dot][{{a_, b_, c_}, {a_, c_, d_}} :> {{a, b, d}}, {x, y}]],
  MapThread[Dot, {ArrayReshape[Range[24], {2, 3, 4}], ArrayReshape[Range[40], {2, 4, 5}]}],
  TestID -> "dot-batched"
];

(* 4. Outer product 'a, b -> a b' (no contracted axis). *)
VerificationTest[
  Einstoff[Dot][{{a_}, {b_}} :> {{a, b}}, {Range[2], Range[3]}],
  Outer[Times, Range[2], Range[3]],
  TestID -> "dot-outer"
];

(* 4b. Named axis-sequence RHS code can zip captured axes into product axes:
   einx.multiply("a..., b... -> (a b)..."). *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}],
        y = ArrayReshape[Range[35], {5, 7}]},
    Einstoff[Dot][
    {{a__}, {b__}} :> {{CircleTimes[a, b]..}},
      {x, y}]],
  ArrayReshape[
    Table[
      ArrayReshape[Range[6], {2, 3}][[i1, j1]] *
        ArrayReshape[Range[35], {5, 7}][[i2, j2]],
      {i1, 2}, {i2, 5}, {j1, 3}, {j2, 7}],
    {10, 21}],
  TestID -> "dot-named-axis-sequence-zip-product"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}],
        y = ArrayReshape[Range[35], {5, 7}]},
    With[{g = Einstoff[Dot][
    {{a__}, {b__}} :> {{CircleTimes[a, b]..}},
        {x, y}, {}, TraceAction -> Hold]},
      {Head[g], Dimensions[ReleaseHold[g]], ! FreeQ[g, _MapThread]}]],
  {Hold, {10, 21}, True},
  TestID -> "dot-named-axis-sequence-zip-product-trace"
];

(* 5. Inner product 'a, a -> ' contracts everything to a scalar. *)
VerificationTest[
  Einstoff[Dot][{{a_}, {a_}} :> {{}}, {Range[3], Range[3]}],
  Range[3] . Range[3],
  TestID -> "dot-inner-scalar"
];

(* 6. Contract then merge survivors 'a b, b c -> (a c)'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Dot][{{a_, Highlighted[b_]}, {Highlighted[b_], c_}} :> {{CircleTimes[a, c]}}, {x, y}]],
  Flatten[ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}]],
  TestID -> "dot-contract-merge"
];

(* 7. Batched + permuted survivors 'a b c, a c d -> a d b'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
    Einstoff[Dot][{{a_, b_, c_}, {a_, c_, d_}} :> {{a, d, b}}, {x, y}]],
  Transpose[MapThread[Dot, {ArrayReshape[Range[24], {2, 3, 4}], ArrayReshape[Range[40], {2, 4, 5}]}], {1, 3, 2}],
  TestID -> "dot-batched-permute"
];

(* 8. Output dims of batched matmul are correct. *)
VerificationTest[
  Dimensions @ With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
    Einstoff[Dot][{{a_, b_, c_}, {a_, c_, d_}} :> {{a, b, d}}, {x, y}]],
  {2, 3, 5},
  TestID -> "dot-batched-dims"
];

(* ===================== rejection paths ============================= *)

(* 9. Operand-count mismatch: 3 tensors but only 2 input shapes in the desc -> rejected.
   (N-operand chains ARE supported — see the 3- and 4-operand chain tests above; this
   rejects only because the tensor count disagrees with the desc's shape count.) *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}},
      {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}], ArrayReshape[Range[6], {2, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-reject-operand-count-mismatch"
];

(* 10. A single-operand axis dropped before contraction is rejected. *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a}},
      {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-reject-within-drop"
];

(* 10b. A name repeated *within a single operand* ('a' in operand 1) is within-tensor
   contraction — Dot contracts *across* operands, not within one, so it is rejected (Dot's
   own policy; EinstoffShapes no longer gates it).  'b' is a legitimate cross-operand
   contracted axis and must NOT trip the guard (firstDuplicateAxis is per-shape). *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, b_, a_}, {b_, c_}} :> {{c}},
      {ArrayReshape[Range[12], {2, 3, 2}], ArrayReshape[Range[12], {3, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-reject-repeated-within-operand"
];

(* 11. A new output axis is repetition (SPEC 5.5); unbound it is rejected. *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c, d}},
      {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "dot-reject-unbound-repeat"
];

(* 12. Unsatisfiable desc (shared axis size disagrees) returns $Failed. *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}},
      {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[20], {5, 4}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "dot-reject-unsat"
];

(* ===================== contract then repeat (SPEC 5.5) =========== *)

(* 13. Matmul, then broadcast the result into a new axis r: 'a [b], [b] c -> a c r', r=2. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Dot][{{a_, Highlighted[b_]}, {Highlighted[b_], c_}} :> {{a, c, r}}, {x, y}, {r -> 2}]],
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
    Einstoff[Dot][{{a_, Highlighted[b_]}, {Highlighted[b_], Highlighted[c_]}, {Highlighted[c_], d_}} :> {{a, d}}, {x, y, z}]],
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
  Quiet[
    Einstoff[Dot][{{a_, b_}} :> {{a, b}}, {ArrayReshape[Range[6], {2, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-reject-one-tensor"
];

(* 20. A kept literal-integer axis has no carryable identity (shared materializeOutput
   guard, Option A) — rejected, not leaked as an unevaluated ArrayReshape. *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, 2}, {2}} :> {{a, 2}},
      {ArrayReshape[Range[6], {3, 2}], Range[2]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-reject-kept-literal"
];

(* 21. A size > 1 literal is NOT a shared contraction identity across operands: two
   '2's in different operands must not become the same axis — reject (einx.dot rejects
   'a 2, 2 b -> a b': a contracted axis must be named). *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, 2}, {2, b_}} :> {{a, b}},
      {ArrayReshape[Range[6], {3, 2}], ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-reject-shared-literal"
];

(* 22. A unit (size-1) literal operand axis is squeezed, so 'a 1, b -> a b' (== einx
   'a (), b') is an outer product — the {} spelling behaves identically. *)
VerificationTest[
  With[{x = ArrayReshape[Range[3], {3, 1}], y = Range[4]},
    {Einstoff[Dot][{{a_, 1}, {b_}} :> {{a, b}}, {x, y}],
     Einstoff[Dot][{{a_, {}}, {b_}} :> {{a, b}}, {x, y}]}],
  With[{x = ArrayReshape[Range[3], {3, 1}], y = Range[4]},
    {Outer[Times, Flatten[x], y], Outer[Times, Flatten[x], y]}],
  TestID -> "dot-unit-literal-squeeze-outer"
];

(* 23. A contracted axis in >2 operands (dropped) is an N-way super-diagonal — rejected
   (einx.dot: contracted axes must appear in exactly two inputs). *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_}, {a_}, {a_}} :> {{}}, {Range[3], Range[3], Range[3]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-reject-nary-contraction"
];

(* 24. ...but keeping that axis on the output is an elementwise product across all
   operands: 'a, a, a -> a' == x y z (einx accepts this). *)
VerificationTest[
  Einstoff[Dot][{{a_}, {a_}, {a_}} :> {{a}}, {Range[3], Range[3], Range[3]}],
  Range[3] Range[3] Range[3],
  TestID -> "dot-nary-elementwise-keep"
];

(* 25. "Targeting" -> Automatic preserves matching explicit contraction targets,
   including multiple target pairs. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24] - 1, {2, 3, 4}],
      y = ArrayReshape[Range[60] - 1, {4, 5, 3}]},
    Einstoff[Dot][{{a_, Highlighted[b_], Highlighted[c_]}, {Highlighted[c_], d_, Highlighted[b_]}} :>
      {{d, a}}, {x, y}]],
  With[{x = ArrayReshape[Range[24] - 1, {2, 3, 4}],
      y = ArrayReshape[Range[60] - 1, {4, 5, 3}]},
    Table[
      Sum[x[[aa, bb, cc]] y[[cc, dd, bb]], {bb, 3}, {cc, 4}],
      {dd, 5}, {aa, 2}]],
  TestID -> "dot-targeting-auto-multiple-pairs"
];

(* 26. In Automatic mode, explicit targets must agree with inferred contracted axes. *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, Highlighted[b_], c_}, {a_, Highlighted[c_], d_}} :>
      {{a, b, d}},
      {ArrayReshape[Range[24], {2, 3, 4}], ArrayReshape[Range[40], {2, 4, 5}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-targeting-auto-reject-mismatched-targets"
];

(* 27. True mode requires explicit targets for contraction. *)
VerificationTest[
  Quiet[
    Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}},
      {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}, {},
      "Targeting" -> True],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-targeting-true-reject-bare-contraction"
];

(* 28. False mode keeps targeted wrappers as syntax/hygiene and allows a targeted
   shared axis to be kept as batch/output. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[6] + 10, {2, 3}]},
    Einstoff[Dot][{{a_, Highlighted[b_]}, {a_, Highlighted[b_]}} :> {{a, b}},
      {x, y}, {}, "Targeting" -> False]],
  ArrayReshape[Range[6], {2, 3}] ArrayReshape[Range[6] + 10, {2, 3}],
  TestID -> "dot-targeting-false-kept-target"
];

(* 29. The same targeted kept axis rejects under Automatic. *)
VerificationTest[
  Quiet[
    With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[6] + 10, {2, 3}]},
      Einstoff[Dot][{{a_, Highlighted[b_]}, {a_, Highlighted[b_]}} :> {{a, b}},
        {x, y}]],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "dot-targeting-auto-reject-kept-target"
];

(* 30. TraceAction holds the contraction primitive instead of a precomputed result. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    With[{g = Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}, {},
        TraceAction -> Hold]},
      {! FreeQ[g, _MapThread], ! FreeQ[g, Dot],
       ReleaseHold[g] === Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}],
       FreeQ[g, _Einstoff`PackageScope`materializeOutput]}]],
  {True, True, True, True},
  TestID -> "dot-traceaction-holds-contraction"
];

EndTestSection[];
