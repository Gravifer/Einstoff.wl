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
    {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {{4, 8}}, {b -> 2}],
  {{8, 4}},
  TestID -> "ex2-split-merge"
];

(* 3. Direct-sum split, multi-output:  b (q + k) -> b q, b k, q=3 *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{b_, CirclePlus[q_, k_]}} :> {{b, q}, {b, k}}, {{5, 10}}, {q -> 3}],
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

(* 6b. A string-named bracket #b == Slot["b"] binds by *unification*: repeated
   occurrences are symmetric (no Slot[b_]-binds-vs-Slot[b]-references asymmetry)
   and must agree.  a [b] [b] with both b = 4 is satisfiable. *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{a_, Slot["b"], Slot["b"]}} :> {{a}}, {{2, 4, 4}}],
  {{2}},
  TestID -> "bracket-unify-ok"
];

(* 6c. ...and the two occurrences disagreeing (4 vs 5) is unsatisfiable. *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, Slot["b"], Slot["b"]}} :> {{a}}, {{2, 4, 5}}],
  False,
  TestID -> "bracket-unify-mismatch"
];

(* 6d. A bracketed axis shares identity with a bare reference: #b on the input is
   the same axis `b` referenced bare on the output. *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[{{a_, Slot["b"]}} :> {{a, b}}, {{2, 4}}],
  {{2, 4}},
  TestID -> "bracket-shares-identity-with-bare"
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

(* 11. Gather with bracketed immediate:  b [h w] c, b i [2] -> b i c *)
VerificationTest[
  out @ Einstoff`EinstoffShapes[
    {{b_, Slot["h"], Slot["w"], c_}, {b, i_, Slot[2]}} :> {{b, i, c}},
    {{8, 16, 16, 3}, {8, 5, 2}}],
  {{8, 5, 3}},
  TestID -> "ex11-gather-immediate"
];

(* sanity: satisfiable verdict + bindings on a representative case *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {{4, 8}}, {b -> 2}],
  True,
  TestID -> "ex2-satisfiable-true"
];

VerificationTest[
  Einstoff`EinstoffShapes[
    {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {{4, 8}}, {b -> 2}]["Bindings"],
  <|b -> 2, a -> 4, c -> 4|>,
  SameTest -> (Sort[Normal[#1]] === Sort[Normal[#2]] &),
  TestID -> "ex2-bindings"
];

(* bracketed-axis reporting *)
VerificationTest[
  Einstoff`EinstoffShapes[
    {{a_, Slot["b"]}, {Slot["b"], c_}} :> {{a, c}}, {{2, 3}, {3, 4}}]["Bracketed"],
  {b},
  TestID -> "ex10-bracketed"
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
    {{a_, CircleTimes[b_, c_]}} :> {{CircleTimes[b, a], c}}, {{5, 8}}, {b -> 3}],
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

(* bracketed-immediate mismatch: [2] but tensor dim is 5 *)
VerificationTest[
  sat @ Einstoff`EinstoffShapes[
    {{b_, Slot["h"], Slot["w"], c_}, {b, i_, Slot[2]}} :> {{b, i, c}},
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

EndTestSection[];
