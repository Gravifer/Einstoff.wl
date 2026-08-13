(* ::Package:: *)

(* Tests for desc evaluation-hygiene and the string axis tier (feat/desc-hygiene).

   The desc eDSL must distinguish three uses of the same surface syntax: a blank
   `a_` (an axis to be solved), a targeted string `#a` = Slot["a"], and a
   bare `a` (env capture — evaluates to its value UNLESS its name is an established
   axis identity, then a hygienic reference).  A globally shadowed axis symbol (a
   `Block[{c=3},...]`) must not leak its value into an axis identity.  A string `"a"`
   (valid identifier) is the fully-hygienic axis spelling.

   Run via: wolframscript -script scripts/run-tests.wls
   BeginTestSection/EndTestSection are MUnit markers; the runner loads MUnit`. *)

BeginTestSection["Gravifer`Einstoff`DescHygiene"];

ClearAll[a, b, c, k, r, n];

bindingKeyName[Verbatim[HoldPattern][s_Symbol]] := SymbolName[Unevaluated[s]];
bindingKeyName[s_Symbol] := SymbolName[Unevaluated[s]];

(* Fixtures. *)
(* x23 = {{1,2,3},{4,5,6}} ; x24 = {{1,..,4},{5,..,8}} *)

(* 1. HEADLINE: a shadowed blank must not capture its value.  Today this is $Failed
      (the `{s}` extraction re-evaluates c -> 3); it must equal the unshadowed swap. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Block[{c = 3}, Einstoff[ArrayReshape][{{a_, c_}} :> {{c, a}}, {x}]]],
  Transpose[ArrayReshape[Range[6], {2, 3}]],
  TestID -> "hyg-shadowed-blank-reshape"
];

(* 2. A shadowed targeted string axis (#c = Slot["c"]) must not resolve to 3. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Block[{c = 3}, Einstoff[Map]["flip"][{{a_, Slot["c"]}} :> {{a, Slot["c"]}}, {x}]]],
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
  Quiet[
    Einstoff[ArrayReshape][{{"a b"}} :> {{"a b"}}, {{1, 2, 3}}],
    {Einstoff::unsupp}],
  $Failed,
  TestID -> "hyg-string-invalid-identifier-reject"
];

(* 8. Mixing string spelling with a symbol spelling of the SAME name (mishmash)
      is rejected. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Quiet[
      Einstoff[ArrayReshape][{{a_, "a"}} :> {{a, "a"}}, {x}],
      {Einstoff::unsupp}]],
  $Failed,
  TestID -> "hyg-mishmash-reject"
];

(* 9. REGRESSION: a bare, unestablished RHS symbol env-captures (literal repeat),
      exactly as a bound bare axis does on the LHS. *)
VerificationTest[
  Block[{k = 4}, Dimensions @ Einstoff["Massage"][{{a_}} :> {{a, k}}, {{1, 2, 3}}]],
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

(* 12. A whole-axis blank `a_` is inference-only: binding it is rejected even when the
       size agrees with the tensor. Block[{a}] keeps the bare `a` key unshadowed
       so it reaches the axis rather than evaluating to a junk key. *)
VerificationTest[
  Block[{a}, Quiet[
    Einstoff["Massage"][{{a_}} :> {{a}}, {{1, 2, 3}}, {a -> 3}],
    {Einstoff::unsat}]],
  $Failed,
  TestID -> "hyg-blank-not-bindable"
];

(* 13. An evaluated/junk binding key ({3 -> 2} from c = 3) WARNS but carries on: the
       targeted blank axis c is sized from the tensor, the junk binding is dropped,
       and the op succeeds. *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Block[{c = 3},
      Quiet[
        Einstoff[Map]["flip"][{{a_, Highlighted[c_]}} :> {{a, c}}, {x}, {c -> 2}],
        {Einstoff::evalkey}]]],
  Reverse /@ ArrayReshape[Range[6], {2, 3}],
  TestID -> "hyg-evaluated-binding-key-warns-continues"
];

(* 14. A Pattern-form binding key `r_ -> n` is a category error (a matcher, not an axis
       name) — rejected, not silently ignored (which would let a whole-axis blank be
       "bound" and still succeed by tensor inference). *)
VerificationTest[
  Block[{r}, Quiet[
    Einstoff["Massage"][{{r_}} :> {{r}}, {{1, 2}}, {r_ -> 2}],
    {Einstoff::unsat}]],
  $Failed,
  TestID -> "hyg-pattern-key-reject"
];

(* 15. Public output is hygienic under a shadowing Block: EinstoffShapes' Bindings keys
       are axis identities (SymbolName recovers the user name), never the shadowed VALUE. *)
VerificationTest[
  Block[{c = 3},
    Sort[bindingKeyName /@ Keys[
      Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_, c_}} :> {{c, a}}, {{2, 3}}]["Bindings"]]]],
  {"a", "c"},
  TestID -> "hyg-decanon-bindings-no-value-leak"
];

(* 15b. ...and EinstoffParse's normalized LHS keeps the blank `c_`, not `Pattern[3, _]`. *)
VerificationTest[
  Block[{c = 3},
    FreeQ[Gravifer`Einstoff`PackageScope`EinstoffParse[{{a_, c_}} :> {{c, a}}]["LHS"], 3]],
  True,
  TestID -> "hyg-decanon-parse-no-value-leak"
];

(* 15c. A symbol shadowed to the VALUE Null must also be treated as shadowed — the
       hygiene test is ValueQ, not value =!= Null (else Block[{c=Null},…] leaks). *)
VerificationTest[
  Block[{c = Null},
    Sort[bindingKeyName /@ Keys[
      Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_, c_}} :> {{c, a}}, {{2, 3}}]["Bindings"]]]],
  {"a", "c"},
  TestID -> "hyg-decanon-null-shadow-no-leak"
];

VerificationTest[
  Block[{c = Null},
    FreeQ[Gravifer`Einstoff`PackageScope`EinstoffParse[{{a_, c_}} :> {{c, a}}]["LHS"], Null]],
  True,
  TestID -> "hyg-decanon-null-shadow-parse"
];

(* 15e. A bare binding key that evaluated to a System` symbol (e.g. {c->2} under c=Null
       arrives as {Null->2}) is an evaluated shadow-capture, not a bare axis "Null": it
       is dropped as junk (targeted blank c is sized from the tensor), so no Null
       survives as a resolved-bindings KEY.  (Check via Keys — FreeQ does not inspect
       Association keys.) *)
VerificationTest[
  Block[{c = Null},
    Sort[bindingKeyName /@ Keys[Quiet[
      Gravifer`Einstoff`PackageScope`EinstoffShapes[
        {{a_, Highlighted[c_]}} :> {{a, c}}, {{2, 3}}, {c -> 2}],
      {Einstoff::evalkey}]["Bindings"]]]],
  {"a", "c"},
  TestID -> "hyg-system-symbol-key-dropped"
];

(* 16. An axis name inside a targeted composite (Slot[(c d)]) is canonicalized like any
       grammar position: under a shadowing Block it still resolves, matching the
       unshadowed result.  The supplied factor is string-spelled; c_ remains inferred. *)
VerificationTest[
  With[{x = ArrayReshape[Range[18], {3, 6}]},
    Block[{c = 3},
      Einstoff[ArrayReduce][Total][
        {{a_, Highlighted[CircleTimes[c_, "d"]]}} :> {{a}}, {x}, {"d" -> 2}]]],
  With[{x = ArrayReshape[Range[18], {3, 6}]},
    Einstoff[ArrayReduce][Total][
      {{a_, Highlighted[CircleTimes[c_, "d"]]}} :> {{a}}, {x}, {"d" -> 2}]],
  TestID -> "hyg-targeted-composite-canon"
];

(* 17. Tier separation inside a desc scope: a bare/env-capture axis `c` (RHS-only,
       unestablished as a string) must be bound with the bare key `c -> n`, NOT the
       string key `"c" -> n` (which is only for a string-tier axis). *)
VerificationTest[
  Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {"c" -> 2}]["Satisfiable"],
  False,
  TestID -> "hyg-string-key-rejected-for-bare-axis"
];
VerificationTest[
  Block[{c}, Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> 2}]["OutputShapes"]],
  {{3, 2}},
  TestID -> "hyg-bare-key-binds-bare-axis"
];
(* ...and the positive counterpart through the public shape resolver: an all-string desc
   whose RHS-only string axis "c" is supplied with the string-tier key "c" -> n. *)
VerificationTest[
  Gravifer`Einstoff`PackageScope`EinstoffShapes[{{"a"}} :> {{"a", "c"}}, {{3}}, {"c" -> 2}]["OutputShapes"],
  {{3, 2}},
  TestID -> "hyg-string-key-binds-string-axis-shapes"
];

(* 18. A canonHeld hygiene reject (invalid axis name / tier mishmash) of a well-FORMED
       lhs :> rhs must surface the accurate reason, NOT the generic "desc must be of the
       form lhs :> rhs" — which would misdescribe a structurally-correct desc. *)
VerificationTest[
  StringContainsQ[
    Quiet[
      Gravifer`Einstoff`PackageScope`EinstoffShapes[{{"a b"}} :> {{"a b"}}, {{3}}]["Reason"],
      {Einstoff::unsupp}],
    "invalid axis name"],
  True,
  TestID -> "hyg-reject-reason-invalid-name"
];
VerificationTest[
  StringContainsQ[
    Quiet[
      Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_}} :> {{"a"}}, {{3}}]["Reason"],
      {Einstoff::unsupp}],
    "spelled both"],
  True,
  TestID -> "hyg-reject-reason-mishmash"
];
(* ...while a genuinely malformed desc (not lhs :> rhs) still gets the generic reason. *)
VerificationTest[
  StringContainsQ[
    Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_}}, {{3}}]["Reason"],
    "must be of the form"],
  True,
  TestID -> "hyg-reject-reason-structural"
];

(* The whole LHS is one scope, but a bare LHS symbol is always ambient: it is not
   localized merely because another occurrence uses a binder with the same text. *)
VerificationTest[
  Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_, a}} :> {{a}}, {{3, 5}}]["OutputShapes"],
  {{3}},
  TestID -> "hyg-lhs-bare-not-localized-by-binder"
];
VerificationTest[
  Gravifer`Einstoff`PackageScope`EinstoffShapes[
    {{a_, b_}, {b, c_}} :> {{a, c}}, {{2, 3}, {9, 4}}]["OutputShapes"],
  {{2, 4}},
  TestID -> "hyg-lhs-bare-cross-operand-is-ambient"
];

(* 19. Diagnostic strings show the USER's axis name, not the internal fresh identity
       (axisDisplayName maps a$nn back to "a"); a shadowed name still displays cleanly,
       never its leaked value. *)
VerificationTest[
  Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_}, {a_}} :> {{a}}, {{4}, {7}}]["Reason"],
  "axis a: expected 4 but tensor dimension is 7",
  TestID -> "hyg-reason-user-name-mismatch"
];
VerificationTest[
  StringStartsQ[
    Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_}} :> {{a, a}}, {{3}}]["Reason"],
    "axis a appears more than once"],
  True,
  TestID -> "hyg-reason-user-name-dup-output"
];
VerificationTest[
  Block[{a = 9},
    Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_}, {a_}} :> {{a}}, {{4}, {7}}]["Reason"]],
  "axis a: expected 4 but tensor dimension is 7",
  TestID -> "hyg-reason-user-name-shadowed-no-leak"
];

(* 20. The private Gravifer`Einstoff`Axis` identity context holds value-less tokens only; even if a
       user has (wrongly) Set a symbol there, axisSymbol clears it before use, so the raw
       string tier cannot leak that stray value.  With Gravifer`Einstoff`Axis`ptest = 99 AND a
       shadowing Block[{ptest = 1}], the axis "ptest" must still key hygienically. *)
VerificationTest[
  (Gravifer`Einstoff`Axis`ptest = 99;
   Block[{ptest = 1},
     SymbolName /@ Keys[Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"ptest"}}, {{5}}]["env"]]]),
  {"ptest"},
  TestID -> "hyg-private-context-no-stray-value-leak"
];

(* 21. A desc-reject reason does not leak across re-entrant parses: after an invalid-name
       (rule) reject, a subsequent malformed (non-rule) desc must report the GENERIC
       desc-shape reason, not the stale invalid-name reason ($descRejectReason is reset
       per parse, not just per scope). *)
VerificationTest[
  (Quiet[
     Gravifer`Einstoff`PackageScope`EinstoffShapes[{{"a b"}} :> {{"a b"}}, {{3}}],
     {Einstoff::unsupp}];
   StringContainsQ[
     Gravifer`Einstoff`PackageScope`EinstoffShapes[{{a_}}, {{3}}]["Reason"], "must be of the form"]),
  True,
  TestID -> "hyg-reject-reason-no-stale-leak"
];

(* 22. Even a PROTECTED stray value in the private axis context cannot leak — the boundary
       purge Unprotects before clearing (a plain clear cannot touch a Protected symbol). *)
VerificationTest[
  (Gravifer`Einstoff`Axis`ztest = 88; Protect[Gravifer`Einstoff`Axis`ztest];
   Block[{ztest = 1},
     SymbolName /@ Keys[Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"ztest"}}, {{5}}]["env"]]]),
  {"ztest"},
  TestID -> "hyg-private-context-protected-no-leak"
];

(* 22b. ...and even a LOCKED stray value cannot leak: the boundary purge uses Clear (values
        only, not attributes) which works on a Locked symbol, so axisSymbol still yields a
        value-less identity. *)
VerificationTest[
  Quiet[
    (Gravifer`Einstoff`Axis`ltest = 88; SetAttributes[Gravifer`Einstoff`Axis`ltest, Locked];
     Block[{ltest = 1},
       SymbolName /@ Keys[Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"ltest"}}, {{5}}]["env"]]]),
    {Attributes::locked}],
  {"ltest"},
  TestID -> "hyg-private-context-locked-no-leak"
];

(* 22c. A Protected+Locked stray token survives the boundary purge, so axisSymbol falls
        back to a genuinely fresh Unique identity (in Gravifer`Einstoff`Fallback`): the env key is a
        value-less Symbol (name "protlk$nn"), never the leaked value. *)
VerificationTest[
  (Gravifer`Einstoff`Axis`protlk = 21; SetAttributes[Gravifer`Einstoff`Axis`protlk, {Protected, Locked}];
   With[{env = Block[{protlk = 1},
       Quiet[
         Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"protlk"}}, {{5}}]["env"],
         {Einstoff::privctx}]]},
     {MatchQ[Keys[env], {_Symbol}], FreeQ[Keys[env], 21], Values[env]}]),
  {True, True, {5}},
  TestID -> "hyg-private-context-protected-locked-fresh-fallback"
];

(* 22d. ...and the fresh-fallback path warns the user that they populated our reserved
        Gravifer`Einstoff`Axis` context (rather than silently working around it). *)
VerificationTest[
  (Gravifer`Einstoff`Axis`protlk2 = 21; SetAttributes[Gravifer`Einstoff`Axis`protlk2, {Protected, Locked}];
   Block[{protlk2 = 1}, Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"protlk2"}}, {{5}}]["ok"]]),
  True,
  {Einstoff::privctx},
  TestID -> "hyg-private-context-protected-locked-warns"
];

(* 22e. The fresh fallback is IDENTITY-STABLE: repeated occurrences of one un-sanitizable
        name share a memoized identity, so an inconsistent repeated axis is rejected (not
        silently accepted with two distinct keys) and a string key binds its term. *)
VerificationTest[
  (Gravifer`Einstoff`Axis`protlk3 = 21; SetAttributes[Gravifer`Einstoff`Axis`protlk3, {Protected, Locked}];
   Block[{protlk3 = 1},
     {Quiet[
        Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"protlk3", "protlk3"}}, {{5, 6}}]["ok"],
        {Einstoff::privctx}],   (* 5=/=6 -> False *)
      Quiet[
        Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"protlk3", "protlk3"}}, {{5, 5}}]["ok"],
        {Einstoff::privctx}],   (* consistent -> True *)
      Length @ Keys @ Quiet[
        Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"protlk3", "protlk3"}}, {{5, 5}}]["env"],
        {Einstoff::privctx}],
      Quiet[
        Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"protlk3"}}, {{5}}, {"protlk3" -> 5}]["ok"],
        {Einstoff::privctx}]}]),   (* key binds term *)
  {False, True, 1, True},
  TestID -> "hyg-private-context-fallback-identity-stable"
];

(* 23. A conflicting binding reason names the user's axis, not the fresh identity. *)
VerificationTest[
  StringContainsQ[
    Gravifer`Einstoff`PackageScope`EinstoffShapes[{{"a"}} :> {{"a", "c"}}, {{3}}, {"c" -> 2, "c" -> 4}]["Reason"],
    "axis c"],
  True,
  TestID -> "hyg-conflicting-key-reason-user-name"
];

(* 24. A previously returned result must NOT decay when a later operation runs: the
       boundary purge is CLEAR-ONLY (never Remove), so a synthetic Gravifer`Einstoff`Axis` token
       that is a live key in an earlier env / Bindings is not rewritten to Removed[…].
       (Regression: a Remove-based purge corrupted m["env"] into <|Removed["keepold"]->5|>.) *)
VerificationTest[
  (Module[{m, s},
     m = Block[{keepold = 1}, Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"keepold"}}, {{5}}]];
     s = Block[{keepold2 = 1}, Gravifer`Einstoff`PackageScope`EinstoffShapes[{{"keepold2"}} :> {{"keepold2"}}, {{5}}]];
     Block[{nextop = 1}, Gravifer`Einstoff`PackageScope`EinstoffMatch[{{"nextop"}}, {{7}}]];   (* later op purges *)
     {FreeQ[Keys[m["env"]], _Removed], m["env"][[1]],
      FreeQ[Keys[s["Bindings"]], _Removed]}]),
  {True, 5, True},
  TestID -> "hyg-returned-result-not-mutated-by-later-op"
];

(* 25. A scoped operator on a shadowed targeted axis still lowers correctly through the
       purge + memo-reset + einAxisCatch wrapping (regression that the scope wrapping did
       not break the normal shadowed path). *)
VerificationTest[
  With[{x = ArrayReshape[Range[6], {2, 3}]},
    Block[{c = 3}, Einstoff[Map]["flip"][{{a_, Slot["c"]}} :> {{a, Slot["c"]}}, {x}]]],
  Reverse /@ ArrayReshape[Range[6], {2, 3}],
  TestID -> "hyg-scoped-shadowed-target-through-wrapping"
];

EndTestSection[];
