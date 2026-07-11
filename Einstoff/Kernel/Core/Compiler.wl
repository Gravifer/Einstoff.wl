(* ::Package:: *)

(* Surface capture and normalized IR compilation.

   This is the compatibility migration boundary: it shares the existing held hygiene
   capture so observable semantics remain stable, but no fresh symbol escapes the
   CapturedDesc -> NormalizedDesc step.  The explicit constraint solver will consume
   NormalizedDesc and ultimately replace the compatibility capture itself. *)

PackageScoped[{
  compileDescIR, compileHeldDescIR, captureDescIR, normalizeCapturedDesc,
  compileTargetPolicy, normalizedDescAssociation
}]

iri[name_String] := Symbol["Einstoff`Internal`IR`" <> name];

compileTargetPolicy[False] :=
  iri["TargetPolicy"][<|"Infer" -> True, "ValidateExplicit" -> False,
    "RequireExplicit" -> False|>];
compileTargetPolicy[Automatic] :=
  iri["TargetPolicy"][<|"Infer" -> True, "ValidateExplicit" -> True,
    "RequireExplicit" -> False|>];
compileTargetPolicy[True] :=
  iri["TargetPolicy"][<|"Infer" -> False, "ValidateExplicit" -> True,
    "RequireExplicit" -> True|>];
compileTargetPolicy[other_] :=
  iri["FailureRecord"]["InvalidTargetPolicy", iri["OperationAnalysis"],
    <|"Value" -> HoldComplete[other]|>];

SetAttributes[compileDescIR, HoldAllComplete];
compileDescIR[desc_, bindings_ : {}, operator_ : None, options_ : <||>] :=
  compileHeldDescIR[Hold[desc], HoldComplete[bindings], operator, options];

compileHeldDescIR[h_Hold, hb_HoldComplete, operator_, options_] :=
  withAxisScope @ Module[{surface, sourceDesc, captured, normalized},
    sourceDesc = h /. Hold[x_] :> HoldComplete[x];
    surface = iri["SurfaceDesc"][sourceDesc, hb, operator,
      If[AssociationQ[options], options, <||>]];
    captured = captureDescIR[h, hb, surface];
    If[compilerFailureQ[captured], Return[<|"Surface" -> surface,
      "Captured" -> captured, "Normalized" -> captured|>]];
    normalized = normalizeCapturedDesc[captured];
    <|"Surface" -> surface, "Captured" -> captured,
      "Normalized" -> normalized|>
  ];

captureDescIR[h_Hold, hb_HoldComplete, surface_] :=
  Module[{hc, lhs, rhsHeld, rawBindings, externalBindings},
    If[! MatchQ[h, Hold[_Rule | _RuleDelayed]],
      Return[compilerFailure["MalformedDescription", "Capture",
        <|"Source" -> surface|>]]];
    hc = canonHeld[h];
    If[hc === $Failed,
      Return[compilerFailure["CaptureRejected", "Capture",
        <|"Reason" -> descFailReason[], "Source" -> surface|>]]];
    lhs = normShapes @ Extract[hc, {1, 1}];
    rhsHeld = normHeldShapes @ Extract[hc, {1, 2}, Hold];
    If[! declarativeRhsQ[rhsHeld],
      Return[compilerFailure["NonDeclarativeRHS", "Capture",
        <|"Source" -> With[{held = rhsHeld},
          iri["SourceRef"][{2}, HoldComplete[held]]]|>]]];
    rawBindings = Quiet @ Check[ReleaseHold[hb], $Failed];
    If[rawBindings === $Failed,
      Return[compilerFailure["InvalidBindings", "Capture",
        <|"Source" -> surface|>]]];
    externalBindings = canonBindingList[rawBindings, "Scoped"];
    If[StringQ[externalBindings],
      Return[compilerFailure["InvalidBindings", "Capture",
        <|"Reason" -> externalBindings, "Source" -> surface|>]]];
    iri["CapturedDesc"][<|
      "Surface" -> surface,
      "CanonicalLHS" -> lhs,
      "CanonicalRHS" -> rhsHeld,
      "AxisNames" -> Association[$axisFresh],
      "AxisKinds" -> Association[$axisKind],
      "InlineBindingFacts" -> $inlineBindingFacts,
      "ExternalBindings" -> externalBindings,
      "Bindings" -> hb
    |>]
  ];

(* Inspect held compound heads before releasing the RHS.  Only the declarative shape
   vocabulary is allowed; atoms (including axis symbols and strings) contribute no
   compound head. *)
declarativeRhsQ[h_Hold] :=
  Module[{allowed, heads},
    allowed = {Hold, List, CircleTimes, CirclePlus, Pattern, Blank,
      BlankSequence, BlankNullSequence, Repeated, RepeatedNull,
      Slot, SlotSequence, Highlighted, Framed, Inactive, Sequence};
    heads = DeleteDuplicates @ Cases[h,
      e_[___] :> Unevaluated[e], {0, Infinity}, Heads -> False];
    AllTrue[heads, MemberQ[allowed, #] &]
  ];

normalizeCapturedDesc[iri["CapturedDesc"][captured_Association]] :=
  Module[{lhs, rhs, state, in, out, r, facts, axisTable, normalized},
    lhs = captured["CanonicalLHS"];
    rhs = Quiet @ Check[ReleaseHold[captured["CanonicalRHS"]], $Failed];
    If[rhs === $Failed || ! MatchQ[rhs, {___List}],
      Return[compilerFailure["InvalidOutputShapes", "Normalize",
        <|"Source" -> captured["Surface"]|>]]];
    state = compilerState[captured];
    r = compileShapeList[lhs, "LHS", state];
    If[compilerResultFailureQ[r], Return[First[r]]];
    {in, state} = r;
    r = compileShapeList[rhs, "RHS", state];
    If[compilerResultFailureQ[r], Return[First[r]]];
    {out, state} = r;
    facts = compileBindingFacts[captured["InlineBindingFacts"],
      captured["ExternalBindings"], state];
    If[compilerFailureQ[facts], Return[facts]];
    axisTable = iri["AxisTable"][irAxisMetadata[state["IRState"]]];
    normalized = iri["NormalizedDesc"][<|
      "Inputs" -> iri["Inputs"][in],
      "Outputs" -> iri["Outputs"][out],
      "Axes" -> axisTable,
      "Bindings" -> iri["BindingFacts"][facts],
      "SourceMap" -> iri["SourceMap"][state["SourceMap"]]
    |>];
    If[TrueQ[normalizedIRValidQ[normalized]], normalized,
      compilerFailure["InvalidNormalizedIR", "Normalize",
        <|"Expression" -> normalized|>]]
  ];
normalizeCapturedDesc[other_] :=
  compilerFailure["ExpectedCapturedDesc", "Normalize",
    <|"Expression" -> HoldComplete[other]|>];

normalizedDescAssociation[iri["NormalizedDesc"][a_Association]] := a;
normalizedDescAssociation[_] := Missing["NotNormalized"];

compilerState[captured_Association] := <|
  "IRState" -> irNewState[],
  "FreshToName" -> Association @ KeyValueMap[(#2 -> #1) &,
    captured["AxisNames"]],
  "AxisKinds" -> captured["AxisKinds"],
  "SourceMap" -> <||>
|>;

compilerIntern[key_String, display_String, metadata_Association,
    state_Association] :=
  Module[{id, irs},
    {id, irs} = irInternAxis[key,
      Join[<|"DisplayName" -> display|>, metadata], state["IRState"]];
    {id, Append[state, "IRState" -> irs]}
  ];

compilerOccurrence[state_Association] :=
  Module[{id, irs},
    {id, irs} = irNewOccurrence[state["IRState"]];
    {id, Append[state, "IRState" -> irs]}
  ];

compilerAxisForSymbol[s_Symbol, side_String, state_Association] :=
  Module[{name, freshName, key, metadata},
    freshName = Lookup[state["FreshToName"], Unevaluated[s], Missing["Ambient"]];
    If[MissingQ[freshName],
      name = SymbolName[Unevaluated[s]];
      key = "ambient:" <> Context[Unevaluated[s]] <> name;
      metadata = <|"Origin" -> "Ambient", "Context" -> Context[Unevaluated[s]]|>,
      name = freshName;
      key = "axis:" <> name;
      metadata = <|"Origin" -> "Established",
        "SurfaceKinds" -> Lookup[state["AxisKinds"], name, {}]|>];
    compilerIntern[key, name, metadata, state]
  ];

compileShapeList[shapes_List, side_String, state_Association] :=
  Catch[Module[{out = {}, st = state, r},
    Do[
      If[! ListQ[shape],
        Throw[{compilerFailure["ExpectedShape", "Normalize",
          <|"Side" -> side, "Expression" -> HoldComplete[shape]|>], st},
          compilerTag]];
      r = compileTerms[shape, side, st];
      If[compilerResultFailureQ[r], Throw[r, compilerTag]];
      AppendTo[out, iri["Shape"][First[r]]]; st = Last[r],
      {shape, shapes}];
    {out, st}
  ], compilerTag];

compileTerms[terms_List, side_String, state_Association] :=
  Catch[Module[{out = {}, st = state, r},
    Do[
      r = compileTerm[terms[[i]], side, None, st];
      If[compilerResultFailureQ[r], Throw[r, compilerTag]];
      AppendTo[out, First[r]]; st = Last[r],
      {i, Length[terms]}];
    {out, st}
  ], compilerTag];

compileTerm[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]], side_, target_, state_] :=
  compileNamedOccurrence[s, side, "Binder", target, state];

compileTerm[Verbatim[Pattern][s_Symbol, Verbatim[BlankSequence[]]], side_, target_, state_] :=
  compileNamedSequence[s, side, 1, Blank[], target, state];
compileTerm[Verbatim[Pattern][s_Symbol, Verbatim[BlankNullSequence[]]], side_, target_, state_] :=
  compileNamedSequence[s, side, 0, Blank[], target, state];
compileTerm[Verbatim[Pattern][s_Symbol, Verbatim[Repeated][body_]], side_, target_, state_] :=
  compileNamedSequence[s, side, 1, body, target, state];
compileTerm[Verbatim[Pattern][s_Symbol, Verbatim[RepeatedNull][body_]], side_, target_, state_] :=
  compileNamedSequence[s, side, 0, body, target, state];

compileTerm[s_Symbol, side_, target_, state_] /; Context[Unevaluated[s]] =!= "System`" :=
  compileNamedOccurrence[s, side, If[side === "RHS", "Reference", "Named"],
    target, state];
compileTerm[n_Integer, side_, target_, state_] :=
  compileLeaf["LiteralAxis", n, side, target, state];
compileTerm[Verbatim[Blank[]], side_, target_, state_] :=
  compileLeaf["AnonymousAxis", "One", side, target, state];
compileTerm[Verbatim[BlankSequence[]], side_, target_, state_] :=
  compileLeaf["SequenceAxis", <|"Minimum" -> 1, "Named" -> False|>, side,
    target, state];
compileTerm[Verbatim[BlankNullSequence[]], side_, target_, state_] :=
  compileLeaf["SequenceAxis", <|"Minimum" -> 0, "Named" -> False|>, side,
    target, state];
compileTerm[SlotSequence[1], side_, _, state_] :=
  compileLeaf["SequenceAxis", <|"Minimum" -> 0, "Named" -> False|>, side,
    SlotSequence, state];

compileTerm[Slot[x_], side_, _, state_] := compileTerm[x, side, Slot, state];
compileTerm[Highlighted[x_], side_, _, state_] :=
  compileTerm[x, side, Highlighted, state];
compileTerm[Framed[x_], side_, _, state_] := compileTerm[x, side, Framed, state];

compileTerm[CircleTimes[xs__], side_, target_, state_] :=
  compileComposite["ProductAxis", {xs}, side, target, state];
compileTerm[CirclePlus[xs__], side_, target_, state_] :=
  compileComposite["DirectSumAxis", {xs}, side, target, state];
compileTerm[Repeated[body_], side_, target_, state_] :=
  compileRepeated[body, side, 1, target, state];
compileTerm[RepeatedNull[body_], side_, target_, state_] :=
  compileRepeated[body, side, 0, target, state];

compileTerm[other_, side_, _, state_] :=
  {compilerFailure["UnsupportedTerm", "Normalize",
    <|"Side" -> side, "Expression" -> HoldComplete[other]|>], state};

compileNamedOccurrence[s_Symbol, side_, role_, target_, state_] :=
  Module[{id, occ, st},
    {id, st} = compilerAxisForSymbol[Unevaluated[s], side, state];
    {occ, st} = compilerOccurrence[st];
    {iri["AxisOccurrence"][occ, id,
      <|"Side" -> side, "SyntaxRole" -> role,
        "TargetHead" -> target|>], st}
  ];

compileNamedSequence[s_Symbol, side_, min_, body_, target_, state_] :=
  Module[{id, occ, st, child, r},
    {id, st} = compilerAxisForSymbol[Unevaluated[s], side, state];
    {occ, st} = compilerOccurrence[st];
    If[MatchQ[Unevaluated[body], Verbatim[Blank[]]],
      child = None,
      r = compileTerm[body, side, None, st];
      If[compilerResultFailureQ[r], Return[r]];
      child = First[r]; st = Last[r]];
    {iri["SequenceAxis"][occ, id,
      <|"Side" -> side, "Minimum" -> min, "Pattern" -> child,
        "TargetHead" -> target|>], st}
  ];

compileLeaf[head_, payload_, side_, target_, state_] :=
  Module[{occ, st},
    {occ, st} = compilerOccurrence[state];
    {iri[head][occ, payload,
      <|"Side" -> side, "TargetHead" -> target|>], st}
  ];

compileComposite[head_, children_List, side_, target_, state_] :=
  Module[{r, occ, st},
    r = compileTerms[children, side, state];
    If[compilerResultFailureQ[r], Return[r]];
    st = Last[r]; {occ, st} = compilerOccurrence[st];
    {iri[head][occ, First[r],
      <|"Side" -> side, "TargetHead" -> target|>], st}
  ];

compileRepeated[body_, side_, min_, target_, state_] :=
  Module[{r, occ, st},
    r = compileTerm[body, side, None, state];
    If[compilerResultFailureQ[r], Return[r]];
    st = Last[r]; {occ, st} = compilerOccurrence[st];
    {iri["RepeatedGroup"][occ, First[r],
      <|"Side" -> side, "Minimum" -> min, "TargetHead" -> target|>], st}
  ];

compileBindingFacts[inline_List, external_List, state_Association] :=
  Catch[Module[{out = {}, id, source, grouped, values, fact},
    Do[
      id = Lookup[state["IRState"]["NameToAxisId"], "axis:" <> fact["Name"],
        Missing["UnknownAxis"]];
      If[MissingQ[id],
        Throw[compilerFailure["UnknownInlineBindingAxis", "Normalize",
          <|"Name" -> fact["Name"]|>], compilerTag]];
      source = <|"Kind" -> fact["Source"], "Name" -> fact["Name"],
        "SurfaceKind" -> fact["Kind"], "Binder" -> fact["Binder"],
        "TargetHead" -> fact["TargetHead"]|>;
      AppendTo[out, iri["BindingFact"][id, fact["Size"], source]],
      {fact, inline}];
    Do[
      id = compilerBindingAxisId[First[bd], state];
      If[! MissingQ[id],
        AppendTo[out, iri["BindingFact"][id, Last[bd],
          <|"Kind" -> "Argument", "Key" -> axisDisplayName[First[bd]]|>]]],
      {bd, external}];
    grouped = GatherBy[out, bindingFactAxisId];
    out = {};
    Do[
      values = DeleteDuplicates[bindingFactSize /@ group, SameQ];
      If[Length[values] > 1,
        Throw[compilerFailure["ConflictingBindingFacts", "Normalize",
          <|"Axis" -> bindingFactAxisId[First[group]],
            "Values" -> values|>], compilerTag]];
      fact = First[group];
      AppendTo[out, fact],
      {group, grouped}];
    out
  ], compilerTag];

compilerBindingAxisId[key_Symbol, state_Association] :=
  Module[{name, internalKey},
    name = Lookup[state["FreshToName"], Unevaluated[key], Missing["Ambient"]];
    internalKey = If[MissingQ[name],
      "ambient:" <> Context[Unevaluated[key]] <> SymbolName[Unevaluated[key]],
      "axis:" <> name];
    Lookup[state["IRState"]["NameToAxisId"], internalKey, Missing["UnknownAxis"]]
  ];
compilerBindingAxisId[_, _] := Missing["UnknownAxis"];

bindingFactAxisId[iri["BindingFact"][id_, _, _]] := id;
bindingFactSize[iri["BindingFact"][_, size_, _]] := size;

normalizedIRValidQ[iri["NormalizedDesc"][a_Association]] :=
  And[
    KeyExistsQ[a, "Inputs"], KeyExistsQ[a, "Outputs"],
    KeyExistsQ[a, "Axes"], KeyExistsQ[a, "Bindings"],
    FreeQ[a, _Pattern | _Blank | _BlankSequence | _BlankNullSequence |
      _Rule | _RuleDelayed | _Slot | _SlotSequence | _Highlighted | _Framed |
      _Annotation | _Labeled, {0, Infinity}, Heads -> True]
  ];
normalizedIRValidQ[_] := False;

compilerFailure[tag_, stage_String, details_Association] :=
  iri["FailureRecord"][tag, stage, details];
compilerFailureQ[expr_] := Head[Unevaluated[expr]] === iri["FailureRecord"];
compilerResultFailureQ[{expr_, _}] := compilerFailureQ[expr];
compilerResultFailureQ[_] := True;
