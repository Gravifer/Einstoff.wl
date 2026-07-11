(* ::Package:: *)

BeginTestSection["Einstoff`Solver"];

ClearAll[a, b, c, grp, q, s];

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

VerificationTest[
  out @ solved[{{a__}} :> {{a..}}, {{2, 3, 4}}],
  {{2, 3, 4}},
  TestID -> "solver-named-sequence-projection"
];

VerificationTest[
  out @ solved[
    {{b_, grp : (CircleTimes[s_, Highlighted["ds"]]).., c_}} :>
      {{b, s.., c}},
    {{2, 6, 15, 4}}, {Highlighted["ds"] -> 3}],
  {{2, 2, 5, 4}},
  TestID -> "solver-structured-repetition-pointwise-binders"
];

VerificationTest[
  Head @ solved[{{a___, b___}} :> {{a.., b..}}, {{2}}],
  ir["FailureRecord"],
  TestID -> "solver-rejects-ambiguous-sequence-decomposition"
];

VerificationTest[
  Head @ solved[{{a__}} :> {{a..}}, {{}}],
  ir["FailureRecord"],
  TestID -> "solver-enforces-blanksequence-minimum"
];

VerificationTest[
  out @ solved[{{a__}, {b__}} :>
      {MapThread[CircleTimes, {{a}, {b}}]}, {{2, 3}, {5, 7}}],
  {{10, 21}},
  TestID -> "solver-declarative-sequence-zip"
];

VerificationTest[
  Module[{s = solved[{{a__}} :> {{a..}}, {{2, 3, 4}}]},
    DeleteDuplicates @ Cases[s,
      ir["SequenceMemberId"][ir["AxisId"][n_], k_] :> {n, k}, Infinity]],
  {{1, 1}, {1, 2}, {1, 3}},
  TestID -> "solver-sequence-member-identities-are-local-and-indexed"
];

VerificationTest[
  Module[{bundle, constraints, sources},
    bundle = solve[compile[{{a_, b_}} :> {{b, a}}], {{2, 3}}];
    constraints = bundle["Constraints"];
    sources = Cases[constraints,
      ir["EqualSize"][_, _, source_Association] :> source["Source"], Infinity];
    MatchQ[sources,
      {ir["SourceRef"][{1, 1, 1}, HoldComplete[a_]],
       ir["SourceRef"][{1, 1, 2}, HoldComplete[b_]]}]],
  True,
  TestID -> "solver-constraints-carry-occurrence-sources"
];

VerificationTest[
  Module[{failure = solved[{{a_, a_}} :> {{a}}, {{3, 4}}]},
    MatchQ[failure,
      ir["FailureRecord"]["ConflictingAxisSizes", "Solve",
        KeyValuePattern["Sources" -> {__Association}]]]],
  True,
  TestID -> "solver-conflict-carries-source-provenance"
];

VerificationTest[
  ! FreeQ[solved[{{a_, b_}} :> {{b, a}}, {{2, 3}}],
    ir["SourceMap"][_Association], Infinity],
  True,
  TestID -> "solver-preserves-source-map"
];

VerificationTest[
  Module[{failure = solved[{{a_, a_}} :> {{a}}, {{3, 4}}]},
    MatchQ[failure,
      ir["FailureRecord"]["ConflictingAxisSizes", "Solve",
        KeyValuePattern[{
          "Operator" -> None,
          "SourceReference" -> ir["SourceRef"][{}, _HoldComplete],
          "MessageParameters" -> _List}]]]],
  True,
  TestID -> "solver-failure-has-structured-context"
];

EndTestSection[];
