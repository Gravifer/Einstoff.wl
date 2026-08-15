(* ::Package:: *)

(* Tests for the generalized contraction Einstoff[Inner][mul, add] (cf. WL Inner).
   Dot is the (Times, Plus) case; other (mul, add) have no einx equivalent and are
   checked against native WL Inner. One file per lowering path under tests/.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`. *)

BeginTestSection["Gravifer`Einstoff`Lowering`Inner"];

ClearAll[a, b, c, d, m, n];

(* 1. Inner[Times, Plus] is exactly Dot (matmul). *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Inner][Times, Plus][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]],
  ArrayReshape[Range[6], {2, 3}] . ArrayReshape[Range[12], {3, 4}],
  TestID -> "inner-times-plus-is-dot"
];

(* 2. ...and agrees with Einstoff[Dot] on the same desc. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Inner][Times, Plus][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}] ===
      Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]],
  True,
  TestID -> "inner-agrees-with-dot"
];

(* 3. Tropical (min-plus) contraction === native Inner[Plus, _, _, Min]. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Inner][Plus, Min][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]],
  Inner[Plus, ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}], Min],
  TestID -> "inner-tropical-min-plus"
];

(* 4. Max-product contraction === native Inner[Times, _, _, Max]. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Einstoff[Inner][Times, Max][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]],
  Inner[Times, ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}], Max],
  TestID -> "inner-max-product"
];

(* 5. Batched tropical 'n a b, n b c -> n a c'. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}], y = ArrayReshape[Range[40], {2, 4, 5}]},
    Einstoff[Inner][Plus, Min][{{n_, a_, b_}, {n_, b_, c_}} :> {{n, a, c}}, {x, y}]],
  MapThread[Inner[Plus, #1, #2, Min] &,
    {ArrayReshape[Range[24], {2, 3, 4}], ArrayReshape[Range[40], {2, 4, 5}]}],
  TestID -> "inner-batched-tropical"
];

(* 6. Variadic tropical 3-chain 'a b, b c, c d -> a d' (semiring => associative). *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}], z = ArrayReshape[Range[8], {4, 2}]},
    Einstoff[Inner][Plus, Min][{{a_, b_}, {b_, c_}, {c_, d_}} :> {{a, d}}, {x, y, z}]],
  Inner[Plus, Inner[Plus, ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}], Min],
    ArrayReshape[Range[8], {4, 2}], Min],
  TestID -> "inner-variadic-tropical"
];

(* 7. Tropical outer product 'a, b -> a b' (no contraction; add over one element). *)
VerificationTest[
  Einstoff[Inner][Plus, Min][{{a_}, {b_}} :> {{a, b}}, {Range[2], Range[3]}],
  Outer[Plus, Range[2], Range[3]],
  TestID -> "inner-tropical-outer"
];

(* 8. One input tensor is rejected (contraction needs >= 2). *)
VerificationTest[
  Quiet[
    Einstoff[Inner][Times, Plus][{{a_, b_}} :> {{a, b}}, {ArrayReshape[Range[6], {2, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "inner-reject-one-tensor"
];

(* 9. Inner shares innerLower's Option-A operand sanitize: a size > 1 literal is not a
   shared contraction identity (two '2's are not the same axis) — reject, like Dot. *)
VerificationTest[
  Quiet[
    Einstoff[Inner][Plus, Min][{{a_, 2}, {2, b_}} :> {{a, b}},
      {ArrayReshape[Range[6], {3, 2}], ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "inner-reject-shared-literal"
];

(* 10. ...and a unit (size-1) literal operand axis squeezes: 'a 1, b -> a b' is the
   (min-plus) outer product. *)
VerificationTest[
  With[{x = ArrayReshape[Range[3], {3, 1}], y = Range[4]},
    Einstoff[Inner][Plus, Min][{{a_, 1}, {b_}} :> {{a, b}}, {x, y}]],
  Outer[Plus, Flatten[ArrayReshape[Range[3], {3, 1}]], Range[4]],
  TestID -> "inner-unit-literal-squeeze-outer"
];

(* 11. Inner shares innerLower's N-way guard: a contracted axis in >2 operands (dropped)
   is a super-diagonal — reject 'a, a, a ->', like Dot. *)
VerificationTest[
  Quiet[
    Einstoff[Inner][Plus, Min][{{a_}, {a_}, {a_}} :> {{}}, {Range[3], Range[3], Range[3]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "inner-reject-nary-contraction"
];

(* 12. The user-supplied combiner runs inside our tagged Catch (einCatch/einThrowTag).
   A combiner that itself Throws (untagged) must PROPAGATE past our control flow, not be
   swallowed as our $Failed sentinel.  Discriminating probe: wrap the call in an inert
   head `mark` inside the user's own Catch.  If the throw propagates (correct), it skips
   `mark` and the user Catch returns the raw payload "boom"; were it swallowed (the old
   bug), the operator would RETURN "boom" normally and the user Catch would see the wrapped
   mark["boom"] instead.  So `=== "boom"` holds iff the throw escaped our control flow. *)
VerificationTest[
  Catch @ mark @ Einstoff[Inner][Times, Function[{x, y}, Throw["boom"]]][
    {{a_, b_}, {b_, c_}} :> {{a, c}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  "boom",
  TestID -> "inner-user-throw-propagates"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}], y = ArrayReshape[Range[12], {3, 4}]},
    Head @ Einstoff[Inner][Times, Plus][
      {{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}, TraceAction -> Hold]],
  Hold,
  TestID -> "inner-option-without-bindings"
];

EndTestSection[];
