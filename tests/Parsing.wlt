(* ::Package:: *)

(* Test suite for Einstoff`Parsing`. Run via:
   wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads
   MUnit` so they carry section semantics (skip/require). The .wlt itself
   does not import MUnit`, matching public-paclet convention. *)

BeginTestSection["Einstoff`Parsing"];

ClearAll[a, b, c, q, k, h, w, i, g, n, m];

(* helpers *)
sat[r_] := r["Satisfiable"];
out[r_] := r["OutputShapes"];
bindingKeyName[Verbatim[HoldPattern][s_Symbol]] := SymbolName[Unevaluated[s]];
bindingKeyName[s_Symbol] := SymbolName[Unevaluated[s]];

(* ===================== Satisfiable cases (SPEC 6) ================== *)

(* 1. Plain rearrange:  a b c -> c a b *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_, b_, c_}} :> {{c, a, b}}, {{2, 3, 4}}],
  {{4, 2, 3}},
  TestID -> "ex1-rearrange"
];

(* 2. Split + permute + merge:  a (b c) -> (b a) c, b=2 *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {{4, 8}}, {"b" -> 2}],
  {{8, 4}},
  TestID -> "ex2-split-merge"
];

(* 3. Direct-sum split, multi-output:  b (q + k) -> b q, b k, q=3 *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{b_, CirclePlus["q", k_]}} :> {{b, "q"}, {b, k}}, {{5, 10}}, {"q" -> 3}],
  {{5, 3}, {5, 7}},
  TestID -> "ex3-directsum-split"
];

(* 4. Scalar operand + direct-sum append:  b c, -> b (c + 1) *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{b_, c_}, {}} :> {{b, CirclePlus[c, 1]}}, {{5, 9}, {}}],
  {{5, 10}},
  TestID -> "ex4-scalar-operand"
];

(* 5. Bracket reduce:  a [b] *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_, Slot["b"]}} :> {{a}}, {{5, 9}}],
  {{5}},
  TestID -> "ex5-bracket-reduce"
];

(* 6. Anonymous bracket ellipsis:  b [...] c *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{b_, SlotSequence[1], c_}} :> {{b, c}}, {{2, 7, 7, 3}}],
  {{2, 3}},
  TestID -> "ex6-anon-bracket-ellipsis"
];

(* 6b. A string-named bracket #b == Slot["b"] binds by *unification* (no
   Slot[b_]-binds-vs-Slot[b]-references asymmetry); repeated occurrences across
   operands must agree.  a [b], [b] c with both b = 4 is satisfiable. *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {{2, 4}, {4, 3}}],
  {{2, 3}},
  TestID -> "bracket-unify-ok"
];

(* 6c. ...and the two occurrences disagreeing (4 vs 5) is unsatisfiable. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {{2, 4}, {5, 3}}],
  False,
  TestID -> "bracket-unify-mismatch"
];

(* 6d. A Slot["b"] bracket is targeted string; referencing bare b is a kind mismatch. *)
VerificationTest[
  Quiet[
    sat @ Einstoff`EinstoffShapes[{{a_, Slot["b"]}} :> {{a, b}}, {{2, 4}}],
    {Einstoff::unsupp}],
  False,
  TestID -> "bracket-string-rejects-bare-reference"
];

(* 6d'. A targeted string axis accepts the plain string key or its matching target head. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_, Slot["q"]}} :> {{a}}, {{2, 3}}, {"q" -> 3}],
  True,
  TestID -> "bracket-binding-string-key-ok"
];
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_, Slot["q"]}} :> {{a}}, {{2, 3}}, {Slot["q"] -> 3}],
  True,
  TestID -> "bracket-binding-slot-key-ok"
];
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_, Slot["q"]}} :> {{a}}, {{2, 3}}, {Highlighted["q"] -> 3}],
  False,
  TestID -> "bracket-binding-wrong-target-head-reject"
];
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_, Slot["q"]}} :> {{a}}, {{2, 3}}, {q -> 3}],
  False,
  TestID -> "bracket-binding-bare-key-reject"
];
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, Highlighted["q"]}} :> {{a}}, {{2, 3}}, {Highlighted["q"] -> 3}],
  True,
  TestID -> "highlighted-string-binding-head-key-ok"
];
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, Highlighted["q"]}} :> {{a}}, {{2, 3}}, {"q" -> 3}],
  True,
  TestID -> "highlighted-string-binding-string-key-ok"
];
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, Highlighted["q"]}} :> {{a}}, {{2, 3}}, {Framed["q"] -> 3}],
  False,
  TestID -> "highlighted-string-binding-wrong-head-reject"
];
VerificationTest[
  Block[{q},
    sat @ Einstoff`EinstoffShapes[
      {{a_, Highlighted[q]}} :> {{a}}, {{2, 3}}, {Highlighted[q] -> 3}]],
  True,
  TestID -> "highlighted-bare-binding-head-key-ok"
];
VerificationTest[
  Block[{q},
    sat @ Einstoff`EinstoffShapes[
      {{a_, Highlighted[q]}} :> {{a}}, {{2, 3}}, {q -> 3}]],
  True,
  TestID -> "highlighted-bare-binding-bare-key-ok"
];
VerificationTest[
  Block[{q},
    sat @ Einstoff`EinstoffShapes[
      {{a_, Highlighted[q]}} :> {{a}}, {{2, 3}}, {Framed[q] -> 3}]],
  False,
  TestID -> "highlighted-bare-binding-wrong-head-reject"
];

(* 6e. A repeated axis name within the OUTPUT shape is rejected (einx: "must not contain
   multiple vectorized axes with the same name") — a universal invariant (no layout);
   distinct-across-shapes is fine. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_}} :> {{a, c, c}}, {{3}}, {c -> 2}],
  False,
  TestID -> "reject-duplicate-output-axis"
];

(* 6e'. A repeated axis name within an INPUT shape is NOT rejected here — that is
   within-tensor contraction, which EinstoffShapes resolves by unification (bind once,
   enforce equality) so the preflight agrees with Einstoff["ArrayContract"].  The
   Satisfiable/OutputShapes match the ArrayContract partial-trace 'a b a d -> b d'.
   (Its admissibility for a *non-contracting* operator is that operator's policy, not the
   resolver's — see the reduce/map/dot/direct-sum reject tests.) *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_, b_, a_, d_}} :> {{b, d}}, {{2, 3, 2, 5}}],
  True,
  TestID -> "accept-repeated-input-axis"
];
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_, b_, a_, d_}} :> {{b, d}}, {{2, 3, 2, 5}}],
  {{3, 5}},
  TestID -> "accept-repeated-input-axis-shape"
];

(* 6f. Context robustness: a #b bracket is a string-tier axis, so an unusual $Context
   does not break a kept #b on the output. *)
VerificationTest[
  Block[{$Context = "Sandbox`", $ContextPath = {"System`", "Einstoff`"}},
    out @ Einstoff`EinstoffShapes[{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {{2, 4}}]],
  {{2, 4}},
  TestID -> "bracket-context-robust"
];

(* 9. Outer / broadcast:  a, b -> a b *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_}, {b_}} :> {{a, b}}, {{4}, {5}}],
  {{4, 5}},
  TestID -> "ex9-broadcast"
];

(* 10. Einsum contraction (matmul):  a [b], [b] c -> a c *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {{2, 3}, {3, 4}}],
  {{2, 4}},
  TestID -> "ex10-matmul"
];

(* 11. Gather with targeted literal:  b [h w] c, b i [2] -> b i c *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{b_, Slot["h"], Slot["w"], c_}, {b_, i_, Slot[2]}} :> {{b, i, c}},
    {{8, 16, 16, 3}, {8, 5, 2}}],
  {{8, 5, 3}},
  TestID -> "ex11-gather-immediate"
];

(* sanity: satisfiable verdict + bindings on a representative case *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {{4, 8}}, {"b" -> 2}],
  True,
  TestID -> "ex2-satisfiable-true"
];

VerificationTest[
  Einstoff`EinstoffShapes[
    {{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {{4, 8}}, {"b" -> 2}]["Bindings"],
  <|HoldPattern[b] -> 2, HoldPattern[a] -> 4, HoldPattern[c] -> 4|>,
  SameTest -> (Sort[Normal[#1]] === Sort[Normal[#2]] &),
  TestID -> "ex2-bindings"
];

VerificationTest[
  Sort[bindingKeyName /@ Keys @ Einstoff`EinstoffShapes[
    {{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {{4, 8}}, {"b" -> 2}]["Bindings"]],
  {"a", "b", "c"},
  TestID -> "ex2-bindings-held-key-names"
];

(* targeted-axis reporting *)
VerificationTest[
  Einstoff`EinstoffShapes[
    {{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {{2, 3}, {3, 4}}]["Targeted"],
  {b},
  TestID -> "ex10-targeted"
];

(* ===================== Unsatisfiable cases ======================== *)

(* shared-axis conflict: matmul inner dims disagree (3 vs 9) *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {{2, 3}, {9, 4}}],
  False,
  TestID -> "unsat-shared-axis-conflict"
];

(* non-divisible product: 8 not divisible by b=3 *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, CircleTimes["b", c_]}} :> {{CircleTimes["b", a], c}}, {{5, 8}}, {"b" -> 3}],
  False,
  TestID -> "unsat-nondivisible-product"
];

(* rank mismatch: 3 terms vs 2 dims *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_, b_, c_}} :> {{c, a, b}}, {{2, 3}}],
  False,
  TestID -> "unsat-rank-mismatch"
];

(* underdetermined product: (b c) with no binding for either *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {{4, 8}}],
  False,
  TestID -> "unsat-underdetermined-product"
];

(* targeted-literal mismatch: [2] but tensor dim is 5 *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{b_, Slot["h"], Slot["w"], c_}, {b_, i_, Slot[2]}} :> {{b, i, c}},
    {{8, 16, 16, 3}, {8, 5, 5}}],
  False,
  TestID -> "unsat-immediate-mismatch"
];

(* operand count mismatch: two lhs shapes, one tensor *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_}, {b_}} :> {{a, b}}, {{4}}],
  False,
  TestID -> "unsat-operand-count"
];

(* a reason string is always reported for unsat cases *)
VerificationTest[
  StringQ @ Einstoff`EinstoffShapes[
    {{a_, b_, c_}} :> {{c, a, b}}, {{2, 3}}]["Reason"],
  True,
  TestID -> "unsat-reason-present"
];

(* An in-shape {} inside an output composite is the unit 1, evaluated before the
   CircleTimes product: (a ()) -> a, and a (c ()) -> a (c) with c bound. *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_}} :> {{CircleTimes[a, {}]}}, {{3}}],
  {{3}},
  TestID -> "unit-empty-in-output-composite"
];
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_}} :> {{a, CircleTimes[c, {}]}}, {{3}}, {c -> 2}],
  {{3, 2}},
  TestID -> "unit-empty-in-output-composite-bound"
];

(* EinstoffParse normalizes {} -> 1 on BOTH sides (incl. inside a composite), while a
   whole-shape {} stays scalar and held symbols are untouched. *)
VerificationTest[
  Einstoff`EinstoffParse[{{a_}} :> {{a, {}, CircleTimes[c, {}]}}]["RHS"],
  Hold[{{a, 1, CircleTimes[c, 1]}}],
  TestID -> "parse-normalizes-rhs-unit"
];

(* EinstoffParse flattens nested RHS CirclePlus symmetrically with the LHS. *)
VerificationTest[
  Einstoff`EinstoffParse[{{a_}} :> {{CirclePlus[a, CirclePlus[b, 1]]}}]["RHS"],
  Hold[{{CirclePlus[a, b, 1]}}],
  TestID -> "parse-flattens-rhs-circleplus"
];

(* ===================== bindings validation (§7.4) ================== *)

(* A bindings entry that is not an axis-name -> size rule (a bare symbol/expr) is
   rejected at the entrance with a clear reason, not degraded into a deep unsat. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c, 2}],
  False,
  TestID -> "bindings-reject-non-rule"
];
VerificationTest[
  StringContainsQ[
    Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c, 2}]["Reason"],
    "bindings must be a list of axis-name"],
  True,
  TestID -> "bindings-reject-non-rule-reason"
];

(* A non-symbol key (an integer immediate as a key) is not an axis name.  Under the
   desc-hygiene policy this is treated as a probable shadowed/junk key: it WARNS
   (Einstoff::evalkey) and is dropped rather than aborting, so with the remaining valid
   binding the desc still resolves. *)
VerificationTest[
  sat @ Quiet[
    Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {2 -> 3, c -> 2}],
    {Einstoff::evalkey}],
  True,
  TestID -> "bindings-nonsymbol-key-warns-continues"
];

(* A non-positive or non-integer size is rejected with the size-specific reason. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> -2}],
  False,
  TestID -> "bindings-reject-nonpositive-size"
];
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> 2.5}],
  False,
  TestID -> "bindings-reject-noninteger-size"
];
VerificationTest[
  StringContainsQ[
    Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> 0}]["Reason"],
    "positive-integer axis size"],
  True,
  TestID -> "bindings-reject-size-reason"
];

(* A valid RuleDelayed binding still works (size read from the built Association). *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c :> 2}],
  {{3, 2}},
  TestID -> "bindings-ruledelayed-ok"
];

(* Equal facts coalesce; conflicting values reject without order-dependent Association
   overwrite semantics. *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> 2, c -> 2}],
  {{3, 2}},
  TestID -> "bindings-coalesce-equal-key"
];
VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> 2, c -> 99}],
  False,
  TestID -> "bindings-reject-conflicting-key"
];
VerificationTest[
  StringContainsQ[
    Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> 2, c -> 99}]["Reason"],
    "conflicting sizes for axis c"],
  True,
  TestID -> "bindings-reject-conflicting-key-reason"
];

(* ===================== inline axis sizes ================================ *)

VerificationTest[
  out @ Einstoff`EinstoffShapes[{{Annotation[a, 3]}} :> {{a}}, {{3}}],
  {{3}},
  TestID -> "inline-annotation-lhs-sized-axis"
];

VerificationTest[
  out @ Einstoff`EinstoffShapes[{{Labeled[3, a]}} :> {{a}}, {{3}}],
  {{3}},
  TestID -> "inline-labeled-lhs-sized-axis"
];

VerificationTest[
  sat @ Einstoff`EinstoffShapes[{{Annotation[a_, 3]}} :> {{a}}, {{4}}],
  False,
  TestID -> "inline-sized-blank-check-mismatch"
];

VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_}} :> {{a, Annotation[c, 2]}}, {{3}}],
  {{3, 2}},
  TestID -> "inline-annotation-rhs-broadcast-shape"
];

VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_}} :> {{a, Labeled[2, "c"]}}, {{3}}],
  {{3, 2}},
  TestID -> "inline-labeled-rhs-string-axis"
];

VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{Annotation[Framed[b_], 3]}} :> {{Framed[b]}}, {{3}}],
  {{3}},
  TestID -> "inline-target-sizing-outside"
];

VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{Framed[Annotation[b_, 3]]}} :> {{Framed[b]}}, {{3}}],
  {{3}},
  TestID -> "inline-target-sizing-inside"
];

VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{Slot[Annotation["b", 3]]}} :> {{Slot["b"]}}, {{3}}],
  {{3}},
  TestID -> "inline-slot-composition"
];

VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{a_}} :> {{a, Annotation[c, 2]}}, {{3}}, {c -> 2}],
  {{3, 2}},
  TestID -> "inline-external-equal-coalesce"
];

VerificationTest[
  StringContainsQ[
    Einstoff`EinstoffShapes[
      {{a_}} :> {{a, Annotation[c, 2]}}, {{3}}, {c -> 4}]["Reason"],
    "conflicting sizes for axis c"],
  True,
  TestID -> "inline-external-conflict"
];

VerificationTest[
  sat @ Quiet[
    Einstoff`EinstoffShapes[
      {{a_}} :> {{a, Annotation[CircleTimes[c, d], 2]}}, {{3}}],
    {Einstoff::unsupp}],
  False,
  TestID -> "inline-reject-composite-axis"
];

VerificationTest[
  sat @ Quiet[
    Einstoff`EinstoffShapes[
      {{a_}} :> {{a, Annotation[c, 2, "key"]}}, {{3}}],
    {Einstoff::unsupp}],
  False,
  TestID -> "inline-reject-annotation-arity"
];

(* ===================== named axis-sequence resolver (§5.3) ============== *)

(* Cross-tensor named axis-sequences: RHS code listifies the captured Sequences and zips them. *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{a__}, {b__}} :>
      {MapThread[CircleTimes, {{a}, {b}}]},
    {{2, 3}, {5, 7}}],
  {{10, 21}},
  TestID -> "named-axis-sequence-cross-tensor-zip"
];

(* Inner binders are re-walked per repetition; they do NOT unify to one value. *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{s__}} :> {{s}},
    {{2, 3, 4}}],
  {{2, 3, 4}},
  TestID -> "named-axis-sequence-inner-binders-vary"
];

VerificationTest[
  KeyExistsQ[
    Einstoff`EinstoffMatch[{{s__}}, {{2, 3, 4}}],
    "seq"],
  False,
  TestID -> "named-axis-sequence-match-keeps-seq-private"
];

(* Structured projection keeps the captured term structure; targeted string uses Highlighted. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{b_, grp : (CircleTimes[s_, Highlighted["ds"]]).., c_}} :>
      {Join[{b}, Map[First, {grp}], {c}]},
    {{2, 6, 12, 5}},
    {"ds" -> 3}],
  False,
  TestID -> "named-axis-sequence-rejects-computational-projection"
];

(* Inner sequence captures can be projected with RHS postfix syntax.  This is an
   Einstoff resolver extension: native WL would not use s.. as list splicing. *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{b_, grp : (CircleTimes[s_, Highlighted["ds"]]).., c_}} :>
      {{b, s.., c}},
    {{2, 6, 12, 5}},
    {"ds" -> 3}],
  {{2, 2, 4, 5}},
  TestID -> "named-axis-sequence-rhs-postfix-projection"
];

VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{a_, z___, b_}} :> {{a, z..., b}},
    {{2, 3}}],
  {{2, 3}},
  TestID -> "named-axis-sequence-rhs-postfix-null-empty"
];

VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{b_, grp : (CircleTimes[s_, 3]).., c_}} :> {b, s.., c},
    {{2, 6, 12, 5}}],
  False,
  TestID -> "rhs-flat-shape-rejected-even-with-sequence-splice"
];

(* Arbitrary Join is not the declarative spelling for a null sequence projection. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, z___, b_}} :> {Join[{a}, {z}, {b}]},
    {{2, 3}}],
  False,
  TestID -> "named-axis-sequence-rejects-computational-null-projection"
];

(* Captured named axis-sequences must have the same length in this v1 policy. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a__}, {b__}} :>
      {MapThread[CircleTimes, {{a}, {b}}]},
    {{2, 3}, {5, 7, 11}}],
  False,
  TestID -> "named-axis-sequence-reject-length-mismatch"
];

VerificationTest[
  StringContainsQ[
    Einstoff`EinstoffShapes[
      {{a__}, {b__}} :>
        {MapThread[CircleTimes, {{a}, {b}}]},
      {{2, 3}, {5, 7, 11}}]["Reason"],
    "different lengths"],
  True,
  TestID -> "named-axis-sequence-reject-length-mismatch-reason"
];

(* Nested Repeated and PatternSequence are intentionally outside the v1 matcher. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{grp : ((_)..)..}} :> {{grp}},
    {{2, 3}}],
  False,
  TestID -> "named-axis-sequence-reject-nested-repeated"
];

VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{grp : (PatternSequence[_, _])..}} :> {{grp}},
    {{2, 3}}],
  False,
  TestID -> "named-axis-sequence-reject-patternsequence"
];

(* Inner binders are list-valued; do not also use them as ordinary scalar axes. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{s_}, {grp : (CircleTimes[s_, 3])..}} :> {{s}},
    {{2}, {6}}],
  False,
  TestID -> "named-axis-sequence-reject-inner-scalar-collision"
];

EndTestSection[];

