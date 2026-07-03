(* ::Package:: *)

(* Tests for desc evaluation-hygiene and the string axis tier (feat/desc-hygiene).

   The desc eDSL must distinguish three uses of the same surface syntax: a binder
   `a_` (an axis to be solved), a bracket `#a` = Slot["a"] (a named op-axis), and a
   bare `a` (env capture — evaluates to its value UNLESS its name is an established
   axis identity, then a hygienic reference).  A globally shadowed axis symbol (a
   `Block[{c=3},...]`) must not leak its value into an axis identity.  A string `"a"`
   (valid identifier) is the fully-hygienic axis spelling.

   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`. *)

BeginTestSection["Einstoff`DescHygiene"];

ClearAll[a, b, c, k, r, n];

(* Fixtures. *)
(* x23 = {{1,2,3},{4,5,6}} ; x24 = {{1,..,4},{5,..,8}} *)

(* 1. HEADLINE: a shadowed binder must not capture its value.  Today this is $Failed
      (the `{s}` extraction re-evaluates c -> 3); it must equal the unshadowed swap. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Block[{c = 3}, Einstoff[ArrayReshape][{{a_, c_}} :> {{c, a}}, {x}]]],
  Transpose[ArrayReshape[Range[6], {2, 3}]],
  TestID -> "hyg-shadowed-binder-reshape"
];

(* 2. A shadowed bracket axis (#c = Slot["c"]) must resolve to axis c, not to 3. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Block[{c = 3}, Einstoff[Map]["flip"][{{a_, Slot["c"]}} :> {{a, c}}, {x}]]],
  Reverse /@ ArrayReshape[Range[6], {2, 3}],
  TestID -> "hyg-shadowed-bracket-map-flip"
];

(* 3. STRING TIER: an all-string desc rearranges (transpose). *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[ArrayReshape][{{"a", "b"}} :> {{"b", "a"}}, {x}]],
  Transpose[ArrayReshape[Range[6], {2, 3}]],
  TestID -> "hyg-string-reshape-transpose"
];

(* 4. String axes drive a reduction (drop "b", sum over it). *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Einstoff[ArrayReduce][Total][{{"a", "b"}} :> {{"a"}}, {x}]],
  Total[ArrayReshape[Range[6], {2, 3}], {2}],
  TestID -> "hyg-string-reduce"
];

(* 5. A string axis is sized by a string-keyed binding (repetition). *)
VerificationTest[
  Dimensions @ Einstoff["Massage"][{{"a"}} :> {{"a", "b"}}, {{1, 2, 3}}, {"b" -> 2}],
  {3, 2},
  TestID -> "hyg-string-repeat-binding"
];

(* 6. The string tier is immune to any Block on the same-named symbol (no symbol
      is involved at all). *)
VerificationTest[
  Block[{b = 9},
    Dimensions @ Einstoff["Massage"][{{"a"}} :> {{"a", "b"}}, {{1, 2, 3}}, {"b" -> 2}]],
  {3, 2},
  TestID -> "hyg-string-binding-shadowproof"
];

(* 7. An invalid identifier string is rejected (not a legal axis name). *)
VerificationTest[
  Quiet @ Einstoff[ArrayReshape][{{"a b"}} :> {{"a b"}}, {{1, 2, 3}}],
  $Failed,
  TestID -> "hyg-string-invalid-identifier-reject"
];

(* 8. Mixing the string tier with a symbol/slot spelling of the SAME name (mishmash)
      is rejected. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Quiet @ Einstoff[ArrayReshape][{{a_, "a"}} :> {{a, "a"}}, {x}]],
  $Failed,
  TestID -> "hyg-mishmash-reject"
];

(* 9. REGRESSION: a bare, unestablished RHS symbol env-captures (literal repeat),
      exactly as a bound bare axis does on the LHS. *)
VerificationTest[
  Block[{k = 4}, Quiet @ Dimensions @ Einstoff["Massage"][{{a_}} :> {{a, k}}, {{1, 2, 3}}]],
  {3, 4},
  TestID -> "hyg-bare-rhs-unestablished-literal"
];

(* 10. ...but the SAME shape with the axis established hygienically (string tier)
       uses the binding size and ignores the shadow. *)
VerificationTest[
  Block[{k = 4},
    Dimensions @ Einstoff["Massage"][{{a_}} :> {{a, "k"}}, {{1, 2, 3}}, {"k" -> 2}]],
  {3, 2},
  TestID -> "hyg-string-established-repeat-ignores-shadow"
];

(* 11. REGRESSION: a bound bare LHS axis still reads as its literal dimension. *)
VerificationTest[
  With[{x = ArrayReshape[Range[8], {2, 4}]},
    Block[{k = 4}, Einstoff[ArrayReduce][Total][{{a_, k}} :> {{a}}, {x}]]],
  Total[ArrayReshape[Range[8], {2, 4}], {2}],
  TestID -> "hyg-bare-lhs-literal-dim"
];

(* 12. A whole-axis binder `a_` is inference-only: binding it is rejected even when the
       size agrees with the tensor (a composite split-factor binder, by contrast, IS
       bindable — see ex2 in Parsing.wlt).  Block[{a}] keeps the bare `a` key unshadowed
       so it reaches the axis rather than evaluating to a junk key. *)
VerificationTest[
  Block[{a}, Quiet @ Einstoff["Massage"][{{a_}} :> {{a}}, {{1, 2, 3}}, {a -> 3}]],
  $Failed,
  TestID -> "hyg-binder-not-bindable"
];

(* 13. An evaluated/junk binding key ({3 -> 2} from c = 3) WARNS but carries on: the
       bracket axis c is sized from the tensor, the junk binding is dropped, and the
       op succeeds. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Block[{c = 3},
      Quiet @ Einstoff[Map]["flip"][{{a_, Slot["c"]}} :> {{a, c}}, {x}, {c -> 2}]]],
  Reverse /@ ArrayReshape[Range[6], {2, 3}],
  TestID -> "hyg-evaluated-binding-key-warns-continues"
];

(* 14. A Pattern-form binding key `r_ -> n` is a category error (a matcher, not an axis
       name) — rejected, not silently ignored (which would let a whole-axis binder be
       "bound" and still succeed by tensor inference). *)
VerificationTest[
  Block[{r}, Quiet @ Einstoff["Massage"][{{r_}} :> {{r}}, {{1, 2}}, {r_ -> 2}]],
  $Failed,
  TestID -> "hyg-pattern-key-reject"
];

(* 15. Public output is hygienic under a shadowing Block: EinstoffShapes' Bindings keys
       are axis identities (SymbolName recovers the user name), never the shadowed VALUE. *)
VerificationTest[
  Block[{c = 3},
    Sort[SymbolName /@ Keys[
      Einstoff`EinstoffShapes[{{a_, c_}} :> {{c, a}}, {{2, 3}}]["Bindings"]]]],
  {"a", "c"},
  TestID -> "hyg-decanon-bindings-no-value-leak"
];

(* 15b. …and EinstoffParse's normalized LHS keeps the binder `c_`, not `Pattern[3, _]`. *)
VerificationTest[
  Block[{c = 3},
    FreeQ[Einstoff`EinstoffParse[{{a_, c_}} :> {{c, a}}]["LHS"], 3]],
  True,
  TestID -> "hyg-decanon-parse-no-value-leak"
];

(* 15c. A symbol shadowed to the VALUE Null must also be treated as shadowed — the
       hygiene test is ValueQ, not value =!= Null (else Block[{c=Null},…] leaks). *)
VerificationTest[
  Block[{c = Null},
    Sort[SymbolName /@ Keys[
      Einstoff`EinstoffShapes[{{a_, c_}} :> {{c, a}}, {{2, 3}}]["Bindings"]]]],
  {"a", "c"},
  TestID -> "hyg-decanon-null-shadow-no-leak"
];

VerificationTest[
  Block[{c = Null},
    FreeQ[Einstoff`EinstoffParse[{{a_, c_}} :> {{c, a}}]["LHS"], Null]],
  True,
  TestID -> "hyg-decanon-null-shadow-parse"
];

(* 15e. A bare binding key that evaluated to a System` symbol (e.g. {c->2} under c=Null
       arrives as {Null->2}) is an evaluated shadow-capture, not a bare axis "Null": it
       is dropped as junk (bracket #c is sized from the tensor), so no Null survives as a
       resolved-bindings KEY.  (Check via Keys — FreeQ does not inspect Association keys.) *)
VerificationTest[
  Block[{c = Null},
    Sort[SymbolName /@ Keys[Quiet @ Einstoff`EinstoffShapes[
      {{a_, Slot["c"]}} :> {{a, c}}, {{2, 3}}, {c -> 2}]["Bindings"]]]],
  {"a", "c"},
  TestID -> "hyg-system-symbol-key-dropped"
];

(* 16. An axis name inside a bracketed composite (Slot[(c d)]) is canonicalized like any
       grammar position: under a shadowing Block it still resolves, matching the
       unshadowed result. *)
VerificationTest[
  With[{x = ArrayReshape[Range[18], {3, 6}]},
    Block[{c = 3},
      Einstoff[ArrayReduce][Total][
        {{a_, Slot[CircleTimes[c_, d_]]}} :> {{a}}, {x}, {d -> 2}]]],
  With[{x = ArrayReshape[Range[18], {3, 6}]},
    Einstoff[ArrayReduce][Total][
      {{a_, Slot[CircleTimes[c_, d_]]}} :> {{a}}, {x}, {d -> 2}]],
  TestID -> "hyg-bracketed-composite-canon"
];

(* 17. Tier separation inside a desc scope: a bare/env-capture axis `c` (RHS-only,
       unestablished as a string) must be bound with the bare key `c -> n`, NOT the
       string key `"c" -> n` (which is only for a string-tier axis). *)
VerificationTest[
  Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {"c" -> 2}]["Satisfiable"],
  False,
  TestID -> "hyg-string-key-rejected-for-bare-axis"
];
VerificationTest[
  Block[{c}, Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> 2}]["OutputShapes"]],
  {{3, 2}},
  TestID -> "hyg-bare-key-binds-bare-axis"
];
(* ...and the positive counterpart through the public shape resolver: an all-string desc
   whose RHS-only string axis "c" is supplied with the string-tier key "c" -> n. *)
VerificationTest[
  Einstoff`EinstoffShapes[{{"a"}} :> {{"a", "c"}}, {{3}}, {"c" -> 2}]["OutputShapes"],
  {{3, 2}},
  TestID -> "hyg-string-key-binds-string-axis-shapes"
];

EndTestSection[];
