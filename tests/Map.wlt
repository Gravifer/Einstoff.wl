(* ::Package:: *)

(* Tests for the map lowering path (Einstoff[Map]) — einx miscellaneous /
   shape-preserving elementary ops (flip/roll/sort/softmax/log_softmax/id).
   The op is curried: Einstoff[Map][f][desc, tensors, bindings]; f is a
   vector->vector function, or a string shortcut for the einx op of that name.
   The bracketed (Slot) axes are the op axes (kept on the output); every
   unbracketed axis is vmapped.  One file per lowering path under tests/.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`. *)

BeginTestSection["Einstoff`Lowering`Map"];

ClearAll[a, b, c, r];

(* 1. Flip (einx.flip) by name: reverse along the bracketed axis. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, b}}, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-flip-string"
];

(* 2. A raw function works identically (the string is just a shortcut). *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map][Reverse][{{a_, Slot["b"]}} :> {{a, b}}, {x}] ===
      Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, b}}, {x}]],
  True,
  TestID -> "map-raw-function-equals-name"
];

(* 3. Sort (einx.sort) along the bracket. *)
VerificationTest[
  With[{y = {{3, 1, 2}, {9, 4, 7}}},
    Einstoff[Map]["sort"][{{a_, Slot["b"]}} :> {{a, b}}, {y}]],
  Sort /@ {{3, 1, 2}, {9, 4, 7}},
  TestID -> "map-sort"
];

(* 4. id (einx.id) is the identity along the bracket. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map]["id"][{{a_, Slot["b"]}} :> {{a, b}}, {x}]],
  ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-id"
];

(* 5. Roll (einx.roll): the shift is a parameter, so pass a function. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map][RotateLeft[#, 1] &][{{a_, Slot["b"]}} :> {{a, b}}, {x}]],
  RotateLeft[#, 1] & /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-roll-function"
];

(* 6. Bracket leads on input, output permutes ({b a} -> {a b}); flip along b. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}]},
    Einstoff[Map]["flip"][{{Slot["b"], a_}} :> {{a, b}}, {x}]],
  Transpose[Reverse[ArrayReshape[Range[6], {3, 2}]]],
  TestID -> "map-flip-permute"
];

(* 7. Two adjacent brackets flatten into one op axis ([b][c] == [b c]); flip
      reverses the whole flattened block (cf. SPEC 7.3). *)
VerificationTest[
  With[{z = ArrayReshape[Range[12], {2, 2, 3}]},
    Einstoff[Map]["flip"][{{a_, Slot["b"], Slot["c"]}} :> {{a, b, c}}, {z}]],
  Map[ArrayReshape[Reverse[Flatten[#]], {2, 3}] &, ArrayReshape[Range[12], {2, 2, 3}]],
  TestID -> "map-two-bracket-flatten"
];

(* 8. Softmax (einx.softmax) along the bracket, vs the stable max-shift form. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}],
        sm = Exp[# - Max[#]]/Total[Exp[# - Max[#]]] &},
    Einstoff[Map]["softmax"][{{a_, Slot["b"]}} :> {{a, b}}, {x}] === (sm /@ x)],
  True,
  TestID -> "map-softmax"
];

(* 9. log_softmax along the bracket, vs x - logsumexp(x). *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}],
        lsm = (# - Max[#]) - Log[Total[Exp[# - Max[#]]]] &},
    Einstoff[Map]["log_softmax"][{{a_, Slot["b"]}} :> {{a, b}}, {x}] === (lsm /@ x)],
  True,
  TestID -> "map-log-softmax"
];

(* 10. Output-only axis is repetition (SPEC 5.5): keep the bracket, broadcast r. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Dimensions @
      Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, b, r}}, {x}, {r -> 2}]],
  {2, 4, 2},
  TestID -> "map-repeat"
];

(* 11. A dropped axis is a reduction, not a map — rejected (points at ArrayReduce). *)
VerificationTest[
  Quiet @ Einstoff[Map][Reverse][{{a_, Slot["b"]}} :> {{a}},
    {ArrayReshape[Range[8], {2, 4}]}],
  $Failed,
  TestID -> "map-reject-dropped-axis"
];

(* 12. No bracketed axis is a pure rearrange — rejected (points at ArrayReshape). *)
VerificationTest[
  Quiet @ Einstoff[Map][Reverse][{{a_, b_}} :> {{a, b}},
    {ArrayReshape[Range[8], {2, 4}]}],
  $Failed,
  TestID -> "map-reject-no-bracket"
];

(* 13. A non-shape-preserving f (collapses the block) is rejected. *)
VerificationTest[
  Quiet @ Einstoff[Map][Total][{{a_, Slot["b"]}} :> {{a, b}},
    {ArrayReshape[Range[8], {2, 4}]}],
  $Failed,
  TestID -> "map-reject-not-shape-preserving"
];

(* 14b. An unknown map op name is rejected with a clear error. *)
VerificationTest[
  Quiet @ Einstoff[Map]["flipp"][{{a_, Slot["b"]}} :> {{a, b}},
    {ArrayReshape[Range[8], {2, 4}]}],
  $Failed,
  TestID -> "map-reject-unknown-string"
];

(* 14. More than one input tensor is rejected (Map is single-tensor). *)
VerificationTest[
  Quiet @ Einstoff[Map][Reverse][{{a_, Slot["b"]}} :> {{a, b}},
    {ArrayReshape[Range[8], {2, 4}], ArrayReshape[Range[8], {2, 4}]}],
  $Failed,
  TestID -> "map-reject-multitensor"
];

(* 15. A kept literal-integer axis has no carryable identity (shared materializeOutput
   guard, Option A) — rejected, not leaked. *)
VerificationTest[
  Quiet @ Einstoff[Map]["id"][{{a_, Slot[2]}} :> {{a, 2}},
    {ArrayReshape[Range[6], {3, 2}]}],
  $Failed,
  TestID -> "map-reject-kept-literal"
];

EndTestSection[];
