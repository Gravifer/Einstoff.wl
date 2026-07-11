(* ::Package:: *)

(* Tests for the rearrange/reshape lowering path (Einstoff[ArrayReshape]).
   One file per lowering path under tests/; future paths get Reduce.wlt etc.
   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`
   so they carry section semantics. The .wlt itself does not import MUnit`. *)

BeginTestSection["Einstoff`Lowering`Reshape"];

ClearAll[a, b, c];

(* ===================== rearrange / reshape (einx.id) =============== *)

(* 1. Plain rearrange a b c -> c a b matches native Transpose. *)
VerificationTest[
  With[{x = ArrayReshape[Range[2*3*4], {2, 3, 4}]},
    Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {x}]],
  Transpose[ArrayReshape[Range[2*3*4], {2, 3, 4}], {2, 3, 1}],
  TestID -> "lower-rearrange-permute"
];

(* 2. Split + permute + merge a (b c) -> (b a) c, b=2. *)
VerificationTest[
  With[{y = ArrayReshape[Range[4*8], {4, 8}]},
    Einstoff[ArrayReshape][
      {{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {y}, {"b" -> 2}]],
  ArrayReshape[
    Transpose[ArrayReshape[Range[4*8], {4, 2, 4}], {2, 1, 3}], {8, 4}],
  TestID -> "lower-split-permute-merge"
];

(* 3. Output shape is correct for split+permute+merge. *)
VerificationTest[
  Dimensions @ With[{y = ArrayReshape[Range[4*8], {4, 8}]},
    Einstoff[ArrayReshape][
      {{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {y}, {"b" -> 2}]],
  {8, 4},
  TestID -> "lower-split-permute-merge-dims"
];

(* 4. Single-axis identity (Length<=1 transpose short-circuit). *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a}}, {Range[5]}],
  Range[5],
  TestID -> "lower-identity"
];

(* 5. Pure merge a b -> (a b) flattens row-major. *)
VerificationTest[
  With[{m = Partition[Range[6], 3]},
    Einstoff[ArrayReshape][{{a_, b_}} :> {{CircleTimes[a, b]}}, {m}]],
  Range[6],
  TestID -> "lower-merge"
];

(* 6. Pure split (a b) -> a b round-trips with merge. *)
VerificationTest[
  Einstoff[ArrayReshape][{{CircleTimes["a", b_]}} :> {{"a", b}}, {Range[6]}, {"a" -> 2}],
  Partition[Range[6], 3],
  TestID -> "lower-split"
];

(* ===================== rejection paths ============================= *)

(* 7. Brackets (reduce) are not in the rearrange subset. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][
      {{a_, Highlighted[b_]}} :> {{a}}, {Partition[Range[6], 3]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "lower-reject-bracket"
];

(* 8. Dropping an axis (reduce) is rejected as non-permutation. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][
      {{a_, b_}} :> {{a}}, {Partition[Range[6], 3]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "lower-reject-drop-axis"
];

(* Named axis-sequences lower as concrete carried axis runs. *)
VerificationTest[
  Einstoff[ArrayReshape][
    {{a__}} :> {{a..}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  ArrayReshape[Range[24], {2, 3, 4}],
  TestID -> "lower-named-axis-sequence-carry"
];

VerificationTest[
  Einstoff[ArrayReshape][
    {{a__}} :> {{CircleTimes[a..]}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  Range[24],
  TestID -> "lower-named-axis-sequence-pack"
];

VerificationTest[
  Einstoff["Massage"][
    {{a__}} :> {{CircleTimes[a..]}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  Range[24],
  TestID -> "massage-named-axis-sequence-pack"
];

VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    With[{g = Einstoff[ArrayReshape][{{a__}} :> {{CircleTimes[a..]}}, {x}, {},
        TraceAction -> Hold]},
      {Head[g], ReleaseHold[g], ! FreeQ[g, _ArrayReshape]}]],
  {Hold, Range[24], True},
  TestID -> "lower-named-axis-sequence-pack-trace"
];

VerificationTest[
  Einstoff[ArrayReshape][
    {{CircleTimes[a__]}} :> {{a..}}, {Range[24]},
    {a -> Inactive[Sequence][2, 3, 4]}],
  ArrayReshape[Range[24], {2, 3, 4}],
  TestID -> "lower-named-axis-sequence-unpack"
];

VerificationTest[
  Einstoff[ArrayReshape][
    {{CircleTimes[a___]}} :> {{a..}}, {Range[24]},
    {a -> Inactive[Sequence][2, 3, 4]}],
  ArrayReshape[Range[24], {2, 3, 4}],
  TestID -> "lower-named-axis-nullsequence-unpack-nonempty"
];

VerificationTest[
  Einstoff[ArrayReshape][
    {{CircleTimes[a___]}} :> {{a..}}, {Range[1]},
    {a -> Inactive[Sequence][]}],
  1,
  TestID -> "lower-named-axis-nullsequence-unpack-empty-unit"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][
      {{CircleTimes[a___]}} :> {{a..}}, {Range[24]},
      {a -> Inactive[Sequence][]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "lower-reject-empty-nullsequence-unpack-nonunit"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][
      {{CircleTimes[a__]}} :> {{a..}}, {Range[1]},
      {a -> Inactive[Sequence][]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "lower-reject-empty-blanksequence-unpack"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][
      {{CircleTimes[a__]}} :> {{a..}}, {Range[24]},
      {a -> Inactive[Sequence][2, 0, 4]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "lower-reject-bad-sequence-binding"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][
      {{CircleTimes[a__]}} :> {{a..}}, {Range[24]},
      {a -> Inactive[Sequence][2, 3, 5]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "lower-reject-sequence-product-mismatch"
];

(* 9. Unsatisfiable desc (rank mismatch) returns $Failed. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][
      {{a_, b_, c_}} :> {{c, a, b}}, {ArrayReshape[Range[8], {4, 2}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "lower-reject-unsat"
];

(* 10. Multi-tensor input is rejected (separate path). *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][
      {{a_}, {b_}} :> {{a, b}}, {Range[4], Range[5]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "lower-reject-multitensor"
];

(* ===================== repetition is a Massage feature ============ *)
(* Repetition (SPEC 5.5, an output-only axis of size > 1) is NOT bijective, so it moved
   out of Einstoff[ArrayReshape] and lives on the permissive Einstoff["Massage"] engine.
   These tests exercise the repeat lowering itself (numerics unchanged); the companion
   section below asserts the bijective guard now REJECTS the same descs. *)

(* 11. Repeat a vector along a new trailing axis: 'a -> a c', c=3. *)
VerificationTest[
  Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}],
  Table[Range[4][[i]], {i, 4}, {j, 3}],
  TestID -> "repeat-trailing"
];

(* 12. Repeat + permute: 'a -> c a', c=3 (new axis leads). *)
VerificationTest[
  Einstoff["Massage"][{{a_}} :> {{c, a}}, {Range[4]}, {c -> 3}],
  ConstantArray[Range[4], 3],
  TestID -> "repeat-leading"
];

(* 13. einops.repeat 2D -> 3D: 'a b -> a b c', c=2. *)
VerificationTest[
  With[{m = Partition[Range[6], 3]},
    Einstoff["Massage"][{{a_, b_}} :> {{a, b, c}}, {m}, {c -> 2}]],
  Table[Partition[Range[6], 3][[i, j]], {i, 2}, {j, 3}, {k, 2}],
  TestID -> "repeat-einops-2d-3d"
];

(* 14. An unbound repeat axis (no binding) is unsatisfiable. *)
VerificationTest[
  Quiet[
    Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[4]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "repeat-reject-unbound"
];

(* 15. An explicit integer axis on the output is repetition: 'a -> a 2'. *)
VerificationTest[
  Einstoff["Massage"][{{a_}} :> {{a, 2}}, {Range[4]}],
  Table[Range[4][[i]], {i, 4}, {j, 2}],
  TestID -> "repeat-output-integer"
];

(* 16. A repeat axis inside an output composite: 'a -> (a c)', c=3. *)
VerificationTest[
  Einstoff["Massage"][{{a_}} :> {{CircleTimes[a, c]}}, {Range[4]}, {c -> 3}],
  Flatten @ Table[Range[4][[i]], {i, 4}, {j, 3}],
  TestID -> "repeat-merge"
];

(* 17. Repeat axis as the leading composite factor: 'a -> (c a)', c=3. *)
VerificationTest[
  Einstoff["Massage"][{{a_}} :> {{CircleTimes[c, a]}}, {Range[4]}, {c -> 3}],
  Flatten @ ConstantArray[Range[4], 3],
  TestID -> "repeat-merge-leading"
];

(* Named axis-sequences can be reordered as a captured run. *)
VerificationTest[
  Einstoff["Massage"][{{a_, b__}} :> {{b.., a}},
    {ArrayReshape[Range[24], {2, 3, 4}]}],
  Transpose[ArrayReshape[Range[24], {2, 3, 4}], {3, 1, 2}],
  TestID -> "massage-named-axis-sequence-reorder"
];

(* 18-20. An output axis must be a positive integer (Massage sizes via EinstoffMatch,
   so this positivity guard lives in materializeOutput, not EinstoffShapes). *)
VerificationTest[
  Quiet[
    Einstoff["Massage"][{{a_}} :> {{a, 0}}, {Range[3]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reject-zero-output-integer"
];
VerificationTest[
  Quiet[
    Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[3]}, {c -> 0}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reject-zero-output-binding"
];
VerificationTest[
  Quiet[
    Einstoff["Massage"][{{a_}} :> {{a, -1}}, {Range[3]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reject-negative-output-integer"
];

(* 21. Duplicate literal output axes BROADCAST as distinct anonymous axes (Option A,
   einx-faithful: 'a -> a 2 2' => (a,2,2)). *)
VerificationTest[
  Einstoff["Massage"][{{a_}} :> {{a, 2, 2}}, {Range[3]}],
  Table[Range[3][[i]], {i, 3}, {j, 2}, {k, 2}],
  TestID -> "repeat-duplicate-literal"
];

(* ===== bijective guard: Einstoff[ArrayReshape] rejects non-bijective descs ===== *)
(* The same repetition / contraction / direct-sum descs that Massage accepts are
   rejected by the bijective entrance — a repeated OUTPUT-only axis of size > 1 is not
   an element-count-preserving reindexing.  (A size-1 output-only axis is a unit insert,
   still bijective — covered by the unit-axis tests below.) *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reshape-reject-repeat"
];
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{a_}} :> {{a, 2}}, {Range[4]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reshape-reject-output-integer"
];
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{a_}} :> {{a, 2, 2}}, {Range[3]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reshape-reject-duplicate-literal"
];
(* A within-tensor contraction shrinks the element count — not bijective; ArrayReshape
   points at Einstoff["ArrayContract"] (which accepts it — see ArrayContract.wlt). *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{a_, b_, a_, d_}} :> {{b, d}},
      {ArrayReshape[Range[16], {2, 2, 2, 2}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reshape-reject-contraction"
];
(* A direct sum is a structural join/split, not a reshape. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{b_, CirclePlus["q", k_]}} :> {{b, "q"}, {b, k}},
      {ArrayReshape[Range[20], {2, 10}]}, {"q" -> 3}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reshape-reject-direct-sum"
];

(* 22. A literal-integer INPUT axis cannot be carried to the output (it has no
   identity to permute — cf. einx rejecting 'a 2 -> a 2'); that is a drop = reduce. *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{a_, 2}} :> {{2, a}}, {ArrayReshape[Range[6], {3, 2}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reject-literal-carry"
];

(* ===================== unit axes & scalars (einx axis-squeezing) ====== *)
ClearAll[a, c];

(* 23. Squeeze a size-1 input axis dropped on the output: 'a 1 c -> a c' (einx). *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, 1, c_}} :> {{a, c}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
  ArrayReshape[Range[6], {2, 3}],
  TestID -> "unit-squeeze-input"
];

(* 24. ...and it composes with a permute: 'a 1 c -> c a'. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, 1, c_}} :> {{c, a}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
  Transpose[ArrayReshape[Range[6], {2, 3}]],
  TestID -> "unit-squeeze-permute"
];

(* 25. An in-shape {} term is the unit axis (einx '()'): 'a () c -> a c' == 'a 1 c -> a c'. *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, {}, c_}} :> {{a, c}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
  ArrayReshape[Range[6], {2, 3}],
  TestID -> "unit-empty-term-squeeze"
];

(* 26. ...and {} is accepted in a non-output position by the matcher (Dimensions 1). *)
VerificationTest[
  Einstoff`EinstoffMatch[{{2, {}, 3}, {2, ___}}, {{2, 1, 3}, {2, 4, 5}}]["ok"],
  True,
  TestID -> "unit-empty-term-match"
];

(* 26b. Plain anonymous sequences are carried/vmapped by reshape lowering. *)
VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReshape][{{a_, ___, c_}} :> {{a, ___, c}}, {x}]],
  ArrayReshape[Range[24], {2, 3, 4}],
  TestID -> "reshape-blanknullsequence-carry"
];

VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReshape][{{a_, ___, c_}} :> {{c, ___, a}}, {x}]],
  Transpose[ArrayReshape[Range[24], {2, 3, 4}], {3, 2, 1}],
  TestID -> "reshape-blanknullsequence-permute"
];

VerificationTest[
  With[{x = ArrayReshape[Range[24], {2, 3, 4}]},
    Einstoff[ArrayReshape][{{a_, __, c_}} :> {{a, __, c}}, {x}]],
  ArrayReshape[Range[24], {2, 3, 4}],
  TestID -> "reshape-blanksequence-carry-nonempty"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{a_, __, c_}} :> {{a, __, c}},
      {ArrayReshape[Range[6], {2, 3}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reshape-blanksequence-reject-empty"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{___, a_, ___}} :> {{___, a, ___}},
      {ArrayReshape[Range[24], {2, 3, 4}]}],
    {Einstoff::unsupp, Einstoff::unsat}],
  $Failed,
  TestID -> "reshape-reject-multiple-plain-blanknullsequence-lhs"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{___, c_}} :> {{___, c, ___}},
      {ArrayReshape[Range[24], {2, 3, 4}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reshape-reject-multiple-plain-blanknullsequence-rhs"
];

VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{a_, c_}} :> {{a, ___, c}},
      {ArrayReshape[Range[6], {2, 3}]}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "reshape-reject-output-only-plain-blanknullsequence"
];

(* 26c-d. The raw public EinstoffMatch accepts a string-tier axis (SPEC §5.6): "a" is
   the axis named `a`, unified like a bare symbol — consistent with EinstoffShapes, whose
   desc parse canonicalizes strings before matching. *)
VerificationTest[
  Einstoff`EinstoffMatch[{{"a"}}, {{3}}]["ok"],
  True,
  TestID -> "match-string-axis-ok"
];
VerificationTest[
  SymbolName /@ Keys[Einstoff`EinstoffMatch[{{"a"}}, {{3}}]["env"]],
  {"a"},
  TestID -> "match-string-axis-binding-name"
];

(* 26d. A string-tier axis that needs an explicit size (a composite split factor) can be
   supplied with the string-tier key "a" -> n in the raw matcher (SPEC §5.7), converted
   to the same Symbol["a"] identity the term side uses. *)
VerificationTest[
  Einstoff`EinstoffMatch[{{CircleTimes["a", "b"]}}, {{6}}, {"a" -> 2}]["ok"],
  True,
  TestID -> "match-string-axis-string-binding-ok"
];

(* 26e-f. An invalid string axis name (not an identifier) is a clean unsat reason in the
   raw matcher, NOT a Symbol::symname crash — for a string term and a string binding key
   alike (string names validated before Symbol[…], SPEC §5.6). *)
VerificationTest[
  Einstoff`EinstoffMatch[{{"a b"}}, {{3}}]["ok"],
  False,
  TestID -> "match-string-axis-invalid-name-reject"
];
VerificationTest[
  Einstoff`EinstoffMatch[{{CircleTimes["a", "b"]}}, {{6}}, {"a b" -> 2}]["ok"],
  False,
  TestID -> "match-string-key-invalid-name-reject"
];

(* 26g-h. Invalid string names are also validated inside a bracket (Slot) and inside a
   composite factor — clean unsat, not a Symbol::symname crash. *)
VerificationTest[
  Einstoff`EinstoffMatch[{{Slot["a b"]}}, {{3}}]["ok"],
  False,
  TestID -> "match-slot-invalid-name-reject"
];
VerificationTest[
  Einstoff`EinstoffMatch[{{CircleTimes["a b", "c"]}}, {{6}}]["ok"],
  False,
  TestID -> "match-composite-invalid-factor-reject"
];

(* 26i-l. The raw string tier is Block-immune: a shadowed global of the axis name does
   NOT leak its value into the env key (axisSymbol maps a shadowed name to a value-less
   private-context symbol whose SymbolName is still the user name).  An UNBOUND name keeps
   the clean Global` symbol as key. *)
VerificationTest[
  Block[{c = 3},
    {Einstoff`EinstoffMatch[{{"c"}}, {{5}}]["ok"],
     SymbolName /@ Keys[Einstoff`EinstoffMatch[{{"c"}}, {{5}}]["env"]]}],
  {True, {"c"}},
  TestID -> "match-string-axis-shadowed-no-leak"
];
VerificationTest[
  Block[{c = 3},
    Einstoff`EinstoffMatch[{{"c"}}, {{5}}, {"c" -> 5}]["ok"]],
  True,
  TestID -> "match-string-key-shadowed-no-leak"
];
VerificationTest[
  Block[{c = 3},
    SymbolName /@ Keys[Einstoff`EinstoffMatch[{{Slot["c"]}}, {{5}}]["env"]]],
  {"c"},
  TestID -> "match-slot-axis-shadowed-no-leak"
];
VerificationTest[
  Keys[Einstoff`EinstoffMatch[{{"c"}}, {{5}}]["env"]],
  {c},
  TestID -> "match-string-axis-unbound-clean-key"
];

(* 26m. A bracket binding key #a = Slot["a"] is reserved for actual slot axes;
   it does not bind a non-slot string factor. *)
VerificationTest[
  Einstoff`EinstoffMatch[{{CircleTimes["a", "b"]}}, {{6}}, {Slot["a"] -> 2}]["ok"],
  False,
  TestID -> "match-bracket-key-raw-reject-non-slot"
];

(* 27-30. Scalars (rank 0): squeeze/insert a singleton, no leaked ArrayReshape[s,{}]. *)
VerificationTest[
  Einstoff[ArrayReshape][{{}} :> {{}}, {7}], 7, TestID -> "scalar-identity"];
VerificationTest[
  Einstoff[ArrayReshape][{{}} :> {{1}}, {7}], {7}, TestID -> "scalar-to-singleton"];
VerificationTest[
  Einstoff[ArrayReshape][{{1}} :> {{}}, {{7}}], 7, TestID -> "singleton-to-scalar"];
VerificationTest[
  Einstoff[ArrayReduce][Total][{{}} :> {{}}, {7}], 7, TestID -> "scalar-reduce"];

(* 31. A size > 1 literal still cannot be carried even with a {} unit beside it:
   '2 () 3 -> 2 1 3' rejects (anonymous 2 and 3 have no carryable identity; einx errors). *)
VerificationTest[
  Quiet[
    Einstoff[ArrayReshape][{{2, {}, 3}} :> {{2, 1, 3}}, {ArrayReshape[Range[6], {2, 1, 3}]}],
    {Einstoff::unsat}],
  $Failed,
  TestID -> "reject-literal-carry-with-unit"
];

(* 32. {} and 1 are the same unit literal even for duplicate-output broadcast:
   'a -> a {} {}' == 'a -> a 1 1' (both two unit broadcast axes). *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a, {}, {}}}, {Range[2]}],
  Einstoff[ArrayReshape][{{a_}} :> {{a, 1, 1}}, {Range[2]}],
  TestID -> "unit-empty-duplicate-output"
];

(* 33. Massage shares the targeted within-tensor contraction path with ArrayContract. *)
VerificationTest[
  With[{t = ArrayReshape[Range[27], {3, 3, 3}]},
    Einstoff["Massage"][{{"a", Highlighted["a"], Highlighted["a"]}} :> {{"a"}}, {t}]],
  With[{t = ArrayReshape[Range[27], {3, 3, 3}]},
    Table[Sum[t[[i, j, j]], {j, 3}], {i, 3}]],
  TestID -> "massage-targeting-auto-targeted-pair-kept-carrier"
];

(* 34. TraceAction returns the lowered expression wrapped by the requested action. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Head @ Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}, {}, TraceAction -> Hold]],
  Hold,
  TestID -> "traceaction-hold-head"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    With[{g = Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}, {}, TraceAction -> Hold]},
      {MatchQ[g, Hold[_ArrayReshape]], ! FreeQ[g, _Transpose],
       FreeQ[g, _Einstoff`PackageScope`materializeOutput]}]],
  {True, True, True},
  TestID -> "traceaction-holds-public-lowering"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    ReleaseHold @ Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}, {}, TraceAction -> Hold]],
  Transpose[ArrayReshape[Range[6], {2, 3}]],
  TestID -> "traceaction-hold-releases"
];

VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Head @ Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}, {}, TraceAction -> Defer]],
  Defer,
  TestID -> "traceaction-defer-head"
];

(* Inline bindings are consumed by the same scoped parser used by operators. *)
VerificationTest[
  Einstoff["Massage"][{{a_}} :> {{a, Annotation[c, 2]}}, {Range[3]}],
  ConstantArray[Range[3], {2}] // Transpose,
  TestID -> "inline-annotation-operator-broadcast"
];

VerificationTest[
  Einstoff[ArrayReshape][{{Annotation[a_, 3]}} :> {{a}}, {Range[3]}],
  Range[3],
  TestID -> "inline-sized-blank-operator-check"
];

EndTestSection[];
