(* ::Package:: *)

BeginTestSection["Einstoff`Solver"];

ClearAll[a, b, c, q];

compile = Symbol["Einstoff`PackageScope`compileDescIR"];
solve = Symbol["Einstoff`PackageScope`solveDescIR"];
ir[name_] := Symbol["Einstoff`Internal`IR`" <> name];

solved[desc_, shapes_, bindings_ : {}] := solve[compile[desc, bindings], shapes]["Solved"];
out[ir["SolvedDesc"][a_Association]] := a["OutputShapes"];

VerificationTest[
  out @ solved[{{a_, b_}} :> {{b, a}}, {{2, 3}}],
  {{3, 2}},
  TestID -> "solver-reshape"
];

VerificationTest[
  out @ solved[{{a_, CircleTimes["b", c_]}} :>
      {{CircleTimes["b", a], c}}, {{4, 8}}, {"b" -> 2}],
  {{8, 4}},
  TestID -> "solver-product-constraint"
];

VerificationTest[
  out @ solved[{{a_, CirclePlus["q", c_]}} :> {{a, "q"}, {a, c}},
    {{5, 10}}, {"q" -> 3}],
  {{5, 3}, {5, 7}},
  TestID -> "solver-direct-sum-constraint"
];

VerificationTest[
  out @ solved[{{a_}} :> {{a, Annotation[c, 2]}}, {{3}}],
  {{3, 2}},
  TestID -> "solver-inline-output-size"
];

VerificationTest[
  Head @ solved[{{a_, a_}} :> {{a}}, {{3, 4}}],
  ir["FailureRecord"],
  TestID -> "solver-repeated-binder-mismatch"
];

VerificationTest[
  out @ solved[{{a_, a}} :> {{a}}, {{3, 5}}],
  {{3}},
  TestID -> "solver-bare-lhs-distinct-from-binder"
];

VerificationTest[
  {
    out @ solved[{{a_, b_}} :> {{b, a}}, {{2, 3}}] ===
      Einstoff`EinstoffShapes[{{a_, b_}} :> {{b, a}}, {{2, 3}}]["OutputShapes"],
    out @ solved[{{a_}} :> {{a, c}}, {{3}}, {c -> 2}] ===
      Einstoff`EinstoffShapes[{{a_}} :> {{a, c}}, {{3}}, {c -> 2}]["OutputShapes"],
    out @ solved[{{a_, CircleTimes["b", c_]}} :> {{c, a}}, {{4, 8}}, {"b" -> 2}] ===
      Einstoff`EinstoffShapes[
        {{a_, CircleTimes["b", c_]}} :> {{c, a}}, {{4, 8}}, {"b" -> 2}]["OutputShapes"]
  },
  {True, True, True},
  TestID -> "solver-public-shape-parity-basic"
];

EndTestSection[];
