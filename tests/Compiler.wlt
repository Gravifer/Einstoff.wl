(* ::Package:: *)

BeginTestSection["Einstoff`Compiler"];

ClearAll[a, b, c, k];

compile = Symbol["Einstoff`PackageScope`compileDescIR"];
ir[name_] := Symbol["Einstoff`Internal`IR`" <> name];

VerificationTest[
  Head /@ Values @ compile[{{a_, a_}} :> {{a}}],
  {ir["SurfaceDesc"], ir["CapturedDesc"], ir["NormalizedDesc"]},
  TestID -> "compiler-distinct-stage-roots"
];

VerificationTest[
  Module[{n = compile[{{a_, a_}} :> {{a}}]["Normalized"], axes},
    axes = Cases[n, ir["AxisOccurrence"][_, id_, _] :> id, Infinity];
    {Length[axes], SameQ @@ axes}],
  {3, True},
  TestID -> "compiler-whole-lhs-repeated-blank-unifies"
];

VerificationTest[
  Module[{n = compile[{{a_, a}} :> {{a}}]["Normalized"], lhsIds, rhsId},
    lhsIds = Cases[n,
      ir["AxisOccurrence"][_, id_, KeyValuePattern["Side" -> "LHS"]] :> id,
      Infinity];
    rhsId = First @ Cases[n,
      ir["AxisOccurrence"][_, id_, KeyValuePattern["Side" -> "RHS"]] :> id,
      Infinity];
    {lhsIds[[1]] =!= lhsIds[[2]], rhsId === lhsIds[[1]]}],
  {True, True},
  TestID -> "compiler-bare-lhs-remains-ambient"
];

VerificationTest[
  Module[{n = compile[{{a, a}} :> {{a}}]["Normalized"]},
    Cases[n, ir["AxisOccurrence"][_, _, meta_Association] :>
      meta["SyntaxRole"], Infinity]],
  {"Ambient", "Ambient", "Reference"},
  TestID -> "compiler-all-bare-lhs-has-no-binder"
];

VerificationTest[
  Block[{a = 3},
    FreeQ[compile[{{a, a}} :> {{a}}]["Normalized"],
      ir["AxisOccurrence"][___], Infinity]],
  True,
  TestID -> "compiler-bare-lhs-ambient-value-capture"
];

VerificationTest[
  Module[{n = compile[{{Foo`a_, Bar`a_}} :> {{a}}]["Normalized"], ids},
    ids = Cases[n, ir["AxisOccurrence"][_, id_, _] :> id, Infinity];
    SameQ @@ ids],
  True,
  TestID -> "compiler-binders-ignore-symbol-context"
];

VerificationTest[
  Module[{n = compile[{{"a", "a"}} :> {{"a"}}]["Normalized"], ids},
    ids = Cases[n, ir["AxisOccurrence"][_, id_, _] :> id, Infinity];
    SameQ @@ ids],
  True,
  TestID -> "compiler-string-axis-whole-scope"
];

VerificationTest[
  Module[{n = compile[{{a_, b_}} :> {{b, a}}]["Normalized"]},
    Cases[n, ir["AxisOccurrence"][_, id_, _] :> Head[id], Infinity]],
  ConstantArray[ir["AxisId"], 4],
  TestID -> "compiler-no-global-axis-identities"
];

VerificationTest[
  Module[{n = compile[{{a_}} :> {{a, Annotation[c, 2]}}]["Normalized"]},
    Cases[n, ir["BindingFact"][id_, size_, _, _] :> {id, size}, Infinity]],
  {{ir["AxisId"][2], 2}},
  TestID -> "compiler-inline-binding-fact"
];

VerificationTest[
  Module[{n = compile[
      {{Annotation[a_, 3]}} :> {{a, Labeled[2, c]}}]["Normalized"]},
    Cases[n, ir["AxisOccurrence"][_, _, meta_Association] :>
      meta["SyntaxRole"], Infinity]],
  {"Binder", "Reference", "ExplicitSizedDeclaration"},
  TestID -> "compiler-inline-sized-occurrence-roles"
];

VerificationTest[
  Module[{n = compile[{{a_}} :> {{a, c}}, {c -> 2}]["Normalized"]},
    Cases[n, ir["BindingFact"][id_, size_, _, _] :> {id, size}, Infinity]],
  {{ir["AxisId"][2], 2}},
  TestID -> "compiler-external-binding-fact"
];

VerificationTest[
  Length @ Cases[
    compile[{{a_}} :> {{a, Annotation[c, 2]}}, {c -> 2}]["Normalized"],
    ir["BindingFact"][___], Infinity],
  1,
  TestID -> "compiler-equal-binding-facts-coalesce"
];

VerificationTest[
  ! FreeQ[compile[{{a__}, {b__}} :>
      {{CircleTimes[a, b]..}}]["Normalized"],
    ir["SequenceZip"][_, CircleTimes,
      {ir["SequenceReference"][_, _], ir["SequenceReference"][_, _]},
      _Association], Infinity],
  True,
  TestID -> "compiler-normalizes-declarative-sequence-zip"
];

VerificationTest[
  ! FreeQ[compile[{{a__}} :> {{a..}}]["Normalized"],
    ir["SequenceProjection"][_, ir["SequenceReference"][_, _], _Association],
    Infinity],
  True,
  TestID -> "compiler-normalizes-postfix-sequence-projection"
];

VerificationTest[
  ! FreeQ[compile[{{a__, c_}} :> {{CircleTimes[a, c]..}}]["Normalized"],
    ir["SequenceComposition"][_, ir["ProductAxis"][___], _Association],
    Infinity],
  True,
  TestID -> "compiler-normalizes-declarative-sequence-composition"
];

VerificationTest[
  Head @ compile[{{a__}, {b__}} :>
      {MapThread[Plus, {{a}, {b}}]}]["Normalized"],
  ir["FailureRecord"],
  TestID -> "compiler-rejects-arbitrary-rhs-code"
];

VerificationTest[
  Head @ compile[{{a__}, {b__}} :>
      {MapThread[CircleTimes, {{a}, {b}}]}]["Normalized"],
  ir["FailureRecord"],
  TestID -> "compiler-rejects-mapthread-sequence-derivation"
];

VerificationTest[
  Module[{calls = 0, result},
    result = compile[{{a_}} :> {{(calls++; a)}}]["Normalized"];
    {calls, Head[result]}],
  {0, ir["FailureRecord"]},
  TestID -> "compiler-does-not-execute-rhs-computation"
];

VerificationTest[
  Module[{n1, n2},
    n1 = compile[{{a_, b_}} :> {{b, a}}]["Normalized"];
    n2 = compile[{{a_, b_}} :> {{b, a}}]["Normalized"];
    n1 === n2],
  True,
  TestID -> "compiler-local-ids-deterministic"
];

VerificationTest[
  Module[{before, after},
    before = Sort @ Join[
      Names["Einstoff`Axis`*"], Names["Einstoff`Internal`DisplayAxis`*"]];
    Do[compile[{{"compilegrowthaxis"}} :> {{"compilegrowthaxis"}}], {20}];
    after = Sort @ Join[
      Names["Einstoff`Axis`*"], Names["Einstoff`Internal`DisplayAxis`*"]];
    after === before],
  True,
  TestID -> "compiler-does-not-create-axis-symbols"
];

VerificationTest[
  FreeQ[
    DownValues /@ {compile,
      Symbol["Einstoff`PackageScope`captureDescIR"],
      Symbol["Einstoff`PackageScope`normalizeCapturedDesc"]},
    _Unique | _Temporary, Infinity, Heads -> True],
  True,
  TestID -> "compiler-does-not-use-temporary-symbol-identities"
];

VerificationTest[
  Module[{captured, sources},
    captured = compile[{{a_}} :> {{a, Annotation[c, 3]}}]["Captured"];
    sources = Cases[captured, ir["SourceRef"][path_, held_] :> {path, held},
      Infinity];
    sources],
  {{{1}, HoldComplete[{{a_}}]},
   {{2}, HoldComplete[{{a, Annotation[c, 3]}}]}},
  TestID -> "compiler-captured-source-roots"
];

VerificationTest[
  Module[{captured, canonical},
    captured = compile[
      {{Highlighted[CircleTimes[a_, "b"]], c__}} :>
        {{Framed[CirclePlus[a, "b"]], c..}}]["Captured"];
    canonical = Replace[captured, ir["CapturedDesc"][a_Association] :>
      {a["CanonicalLHS"], a["CanonicalRHS"]}];
    FreeQ[canonical,
      _Pattern | _Blank | _BlankSequence | _BlankNullSequence |
        _Slot | _SlotSequence | _Highlighted | _Framed |
        _CircleTimes | _CirclePlus | _Repeated | _RepeatedNull,
      Infinity, Heads -> True]],
  True,
  TestID -> "compiler-captured-canonical-tree-is-inert"
];

VerificationTest[
  Module[{normalized, occurrences, sourceMap, refs},
    normalized = compile[
      {{a_, Highlighted[b_]}} :> {{b, a}}]["Normalized"];
    occurrences = DeleteDuplicates @ Cases[normalized,
      ir["AxisOccurrence"][occ_, _, _] :> occ, Infinity];
    sourceMap = First @ Cases[normalized,
      ir["SourceMap"][m_Association] :> m, Infinity];
    refs = Lookup[sourceMap, occurrences];
    {Keys[sourceMap] === occurrences,
      MatchQ[refs, {ir["SourceRef"][{1, 1, 1}, HoldComplete[a_]],
        ir["SourceRef"][{1, 1, 2, 1}, HoldComplete[b_]],
        ir["SourceRef"][{2, 1, 1}, HoldComplete[b]],
        ir["SourceRef"][{2, 1, 2}, HoldComplete[a]]}]}],
  {True, True},
  TestID -> "compiler-occurrence-source-map"
];

VerificationTest[
  Module[{normalized, stripped},
    normalized = compile[{{a_}} :> {{a, Annotation[c, 3]}}]["Normalized"];
    stripped = normalized /. ir["SourceMap"][_Association] :> Null;
    FreeQ[stripped,
      _Pattern | _Blank | _Rule | _RuleDelayed | _Annotation | _Labeled,
      Infinity, Heads -> True]],
  True,
  TestID -> "compiler-surface-syntax-confined-to-source-map"
];

VerificationTest[
  MatchQ[
    compile[{{a_}} :> {{Map[a]}}]["Normalized"],
    ir["FailureRecord"][_, "Capture",
      KeyValuePattern[{
        "Operator" -> None,
        "SourceReference" -> ir["SourceRef"][{}, _HoldComplete],
        "MessageParameters" -> _List}]]],
  True,
  TestID -> "compiler-failure-has-structured-context"
];

VerificationTest[
  MatchQ[
    compile[{{Framed[Annotation["a", 3]]}} :> {{Framed["a"]}}]["Normalized"],
    _?(Head[#] === ir["NormalizedDesc"] &)],
  True,
  TestID -> "compiler-target-inline-composition"
];

EndTestSection[];
