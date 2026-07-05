(* ::Package:: *)

(* Tests for the map lowering path (Einstoff[Map]) — einx miscellaneous /
   shape-preserving elementary ops (flip/roll/sort/softmax/log_softmax/id).
   The op is curried: Einstoff[Map][f][desc, tensors, bindings]; f is a
   target-block -> same-shape target-block function, or a string shortcut.
   The targeted axes are the op axes (kept on the output); every
   untargeted axis is vmapped.  One file per lowering path under tests/.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`. *)

BeginTestSection["Einstoff`Lowering`Map"];

ClearAll[a, b, c, r];

(* 1. Flip (einx.flip) by name: reverse along the targeted axis. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-flip-string"
];

(* 1b-c. Highlighted/Framed mark a targeted blank axis. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map]["flip"][{{a_, Highlighted[b_]}} :> {{a, b}}, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-flip-highlighted-blank"
];
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map]["flip"][{{a_, Framed[b_]}} :> {{a, b}}, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-flip-framed-blank"
];

(* 1d. Highlighted also supports a targeted bare axis, bound by a bare key. *)
VerificationTest[
  Block[{b},
    With[{x = ArrayReshape[Range[8], {2, 4}]},
      Einstoff[Map]["flip"][{{a_, Highlighted[b]}} :> {{a, b}}, {x}, {b -> 4}]]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-flip-highlighted-bare-binding"
];

(* 1e. A targeted bare axis also accepts the matching target-head key. *)
VerificationTest[
  Block[{b},
    With[{x = ArrayReshape[Range[8], {2, 4}]},
      Einstoff[Map]["flip"][{{a_, Highlighted[b]}} :> {{a, b}}, {x}, {Highlighted[b] -> 4}]]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-flip-highlighted-bare-head-binding"
];

(* 1f. A targeted bare axis rejects a different target-head key. *)
VerificationTest[
  Block[{b},
    With[{x = ArrayReshape[Range[8], {2, 4}]},
      Quiet[
        Einstoff[Map]["flip"][{{a_, Highlighted[b]}} :> {{a, b}}, {x}, {Framed[b] -> 4}],
        {Einstoff::unsat}]]],
  $Failed,
  TestID -> "map-reject-highlighted-bare-wrong-head-binding"
];

(* 1g. A targeted blank axis is still infer-only: external bindings are rejected. *)
VerificationTest[
  Block[{b},
    With[{x = ArrayReshape[Range[8], {2, 4}]},
      Quiet[
        Einstoff[Map]["flip"][{{a_, Highlighted[b_]}} :> {{a, b}}, {x}, {b -> 4}],
        {Einstoff::unsat}]]],
  $Failed,
  TestID -> "map-reject-highlighted-blank-binding"
];

(* 1h. The old Slot["b"] -> bare b spelling mixes string and symbol kinds. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Quiet[
      Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, b}}, {x}],
      {Einstoff::unsupp}]],
  $Failed,
  TestID -> "map-reject-slot-string-to-bare"
];

(* 1i. Highlighted/Framed can also target string-kind axes. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map]["flip"][{{a_, Highlighted["b"]}} :> {{a, Highlighted["b"]}}, {x}]],
  Reverse /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-flip-highlighted-string"
];

(* 1j. Slot is reserved for string-kind targeting; it is not targeted blank notation. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Quiet[
      Einstoff[Map]["flip"][{{a_, Slot[b_]}} :> {{a, b}}, {x}],
      {Einstoff::unsupp}]],
  $Failed,
  TestID -> "map-reject-slot-blank-target"
];

(* 2. A raw function works identically (the string is just a shortcut). *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map][Reverse][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}] ===
      Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]],
  True,
  TestID -> "map-raw-function-equals-name"
];

(* 3. Sort (einx.sort) along the target. *)
VerificationTest[
  With[{y = {{3, 1, 2}, {9, 4, 7}}},
    Einstoff[Map]["sort"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {y}]],
  Sort /@ {{3, 1, 2}, {9, 4, 7}},
  TestID -> "map-sort"
];

(* 4. id (einx.id) is the identity along the target. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map]["id"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]],
  ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-id"
];

(* 5. Roll (einx.roll): the shift is a parameter, so pass a function. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Einstoff[Map][RotateLeft[#, 1] &][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]],
  RotateLeft[#, 1] & /@ ArrayReshape[Range[8], {2, 4}],
  TestID -> "map-roll-function"
];

(* 6. Bracket leads on input, output permutes ({b a} -> {a b}); flip along b. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {3, 2}]},
    Einstoff[Map]["flip"][{{Slot["b"], a_}} :> {{a, Slot["b"]}}, {x}]],
  Transpose[Reverse[ArrayReshape[Range[6], {3, 2}]]],
  TestID -> "map-flip-permute"
];

(* 7. Two adjacent targets are one target block; raw f receives that rectangular block
      with WL expression structure, so Reverse reverses the block's first level. *)
VerificationTest[
  With[{z = ArrayReshape[Range[12], {2, 2, 3}]},
    Einstoff[Map]["flip"][{{a_, Slot["b"], Slot["c"]}} :> {{a, Slot["b"], Slot["c"]}}, {z}]],
  Reverse /@ ArrayReshape[Range[12], {2, 2, 3}],
  TestID -> "map-two-target-block-reverse"
];

(* 7b. A variadic visual target captures the concrete middle dimensions and maps over
   the full rectangular block. *)
VerificationTest[
  With[{z = ArrayReshape[Range[120], {2, 3, 4, 5}]},
    Einstoff[Map][Reverse][{{a_, Highlighted[___], c_}} :> {{a, Highlighted[___], c}}, {z}]],
  Reverse /@ ArrayReshape[Range[120], {2, 3, 4, 5}],
  TestID -> "map-highlighted-blanknullsequence-block"
];

VerificationTest[
  With[{z = ArrayReshape[Range[120], {2, 3, 4, 5}]},
    Einstoff[Map][Reverse][{{a_, SlotSequence[1], c_}} :> {{a, SlotSequence[1], c}}, {z}]],
  Reverse /@ ArrayReshape[Range[120], {2, 3, 4, 5}],
  TestID -> "map-slotsequence-block"
];

(* 7c. A targeted literal is an anonymous target axis with a concrete size, and can be
   kept by the same target wrapper. *)
VerificationTest[
  With[{z = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[Map][Reverse][{{a_, Highlighted[3]}} :> {{a, Highlighted[3]}}, {z}]],
  Reverse /@ ArrayReshape[Range[6], {2, 3}],
  TestID -> "map-highlighted-literal"
];

VerificationTest[
  Quiet[
    Einstoff[Map][Reverse][
      {{a_, Highlighted[CirclePlus["b", c_]]}} :> {{a, Highlighted[CirclePlus["b", c]]}},
      {ArrayReshape[Range[14], {2, 7}]}, {"b" -> 3}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-highlighted-direct-sum"
];

(* 8. Softmax (einx.softmax) along the target, vs the stable max-shift form. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}],
        sm = Exp[# - Max[#]]/Total[Exp[# - Max[#]]] &},
    Einstoff[Map]["softmax"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}] === (sm /@ x)],
  True,
  TestID -> "map-softmax"
];

VerificationTest[
  With[{x = ArrayReshape[N @ Range[6], {1, 2, 3}]},
    With[{got = Einstoff[Map]["softmax"][
          {{a_, Slot["b"], Slot["c"]}} :> {{a, Slot["b"], Slot["c"]}}, {x}],
        want = With[{v = Flatten[x[[1]]]},
          {ArrayReshape[Exp[v - Max[v]]/Total[Exp[v - Max[v]]], {2, 3}]}]},
      Chop[got - want] == ConstantArray[0, {1, 2, 3}]]],
  True,
  TestID -> "map-softmax-rectangular-target"
];

(* 9. log_softmax along the target, vs x - logsumexp(x). *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}],
        lsm = (# - Max[#]) - Log[Total[Exp[# - Max[#]]]] &},
    Einstoff[Map]["log_softmax"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}] === (lsm /@ x)],
  True,
  TestID -> "map-log-softmax"
];

VerificationTest[
  With[{x = ArrayReshape[N @ Range[6], {1, 2, 3}]},
    With[{got = Einstoff[Map]["log_softmax"][
          {{a_, Slot["b"], Slot["c"]}} :> {{a, Slot["b"], Slot["c"]}}, {x}],
        want = With[{v = Flatten[x[[1]]]},
          {ArrayReshape[(v - Max[v]) - Log[Total[Exp[v - Max[v]]]], {2, 3}]}]},
      Chop[got - want] == ConstantArray[0, {1, 2, 3}]]],
  True,
  TestID -> "map-log-softmax-rectangular-target"
];

(* 10. Output-only axis is repetition (SPEC 5.5): keep the target, broadcast r. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Dimensions @
      Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"], r}}, {x}, {r -> 2}]],
  {2, 4, 2},
  TestID -> "map-repeat"
];

(* 11. A dropped axis is a reduction, not a map — rejected (points at ArrayReduce). *)
VerificationTest[
  Quiet[
    Einstoff[Map][Reverse][{{a_, Slot["b"]}} :> {{a}},
      {ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-dropped-axis"
];

(* 11b. A name repeated within an input shape is within-tensor contraction, which Map
   (shape-preserving) does not do — rejected.  The output {{a, #b}} is duplicate-free, so
   EinstoffShapes is Satisfiable and the rejection comes from Map itself (the distinctAxesQ
   guard, backed by Map's shape-preserving drop-check — defense in depth), not the
   resolver's output-uniqueness check. *)
VerificationTest[
  Quiet[
    Einstoff[Map][Reverse][{{a_, a_, Slot["b"]}} :> {{a, Slot["b"]}},
      {ArrayReshape[Range[16], {2, 2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-repeated-input-axis"
];

(* 12. No targeted axis is a pure rearrange — rejected (points at ArrayReshape). *)
VerificationTest[
  Quiet[
    Einstoff[Map][Reverse][{{a_, b_}} :> {{a, b}},
      {ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-no-bracket"
];

(* 13. A non-shape-preserving f (collapses the block) is rejected. *)
VerificationTest[
  Quiet[
    Einstoff[Map][Total][{{a_, Slot["b"]}} :> {{a, Slot["b"]}},
      {ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-not-shape-preserving"
];

(* 14b. An unknown map op name is rejected with a clear error. *)
VerificationTest[
  Quiet[
    Einstoff[Map]["flipp"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}},
      {ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-unknown-string"
];

(* 14. More than one input tensor is rejected (Map is single-tensor). *)
VerificationTest[
  Quiet[
    Einstoff[Map][Reverse][{{a_, Slot["b"]}} :> {{a, Slot["b"]}},
      {ArrayReshape[Range[8], {2, 4}], ArrayReshape[Range[8], {2, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-multitensor"
];

(* 15. A kept literal-integer axis has no carryable identity (shared materializeOutput
   guard, Option A) — rejected, not leaked. *)
VerificationTest[
  Quiet[
    Einstoff[Map]["id"][{{a_, Slot[2]}} :> {{a, 2}},
      {ArrayReshape[Range[6], {3, 2}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-kept-literal"
];

(* 16. A dropped size-1 (unit) axis is squeezed, not reduced: 'a 1 [b] -> a [b]' and the
   {}/named-unit spellings all flip along b over the squeezed input (einx allows this). *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 1, 3}], ref = Reverse /@ ArrayReshape[Range[6], {2, 3}]},
    {Einstoff[Map]["flip"][{{a_, 1, Slot["b"]}} :> {{a, Slot["b"]}}, {x}],
     Einstoff[Map]["flip"][{{a_, {}, Slot["b"]}} :> {{a, Slot["b"]}}, {x}],
     Einstoff[Map]["flip"][{{a_, u_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]}],
  With[{ref = Reverse /@ ArrayReshape[Range[6], {2, 3}]}, {ref, ref, ref}],
  TestID -> "map-unit-squeeze"
];

(* 17. ...but a dropped size > 1 axis is still a reduction — rejected. *)
VerificationTest[
  Quiet[
    Einstoff[Map]["flip"][{{a_, b_, Slot["c"]}} :> {{a, Slot["c"]}},
      {ArrayReshape[Range[24], {2, 4, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "map-reject-drop-size-gt1"
];

(* 18. TraceAction holds the row-map lowering, not only the final materialized value. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    With[{g = Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}, {},
        TraceAction -> Hold]},
      {! FreeQ[g, _Map], ! FreeQ[g, Reverse],
       ReleaseHold[g] === Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}],
       FreeQ[g, _Einstoff`PackageScope`materializeOutput]}]],
  {True, True, True, True},
  TestID -> "map-traceaction-holds-map"
];

EndTestSection[];
