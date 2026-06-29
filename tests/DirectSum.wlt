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

(* 9. Einstoff[Split] (CirclePlus on the LHS) is not implemented yet. *)
VerificationTest[
  Quiet @ Einstoff[Split][{{m_, CirclePlus[a_, b_]}} :> {{m, a}, {m, b}},
    {ArrayReshape[Range[14], {2, 7}]}, {a -> 3}],
  $Failed,
  TestID -> "concat-reject-split-todo"
];

(* 10. A LHS CirclePlus routed through ArrayReshape is split -> not yet. *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{m_, CirclePlus[a_, b_]}} :> {{m, a}, {m, b}},
    {ArrayReshape[Range[14], {2, 7}]}, {a -> 3}],
  $Failed,
  TestID -> "concat-reject-reshape-split"
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

EndTestSection[];
