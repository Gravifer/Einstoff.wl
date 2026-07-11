(* ::Package:: *)

(* Surface capture and normalized IR compilation.  Raw WL syntax is converted directly
   to private inert capture nodes; no temporary symbol participates in identity. *)

PackageScoped[{
  compileDescIR, compileHeldDescIR, captureDescIR, normalizeCapturedDesc,
  compileTargetPolicy, normalizedDescAssociation, declarativeRhsQ,
  compileDeclarativeRhsSurface, surfaceAxisKey, capturedBinder,
  capturedLogicalAxis, capturedAmbientAxis, capturedNamedSequence
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
  Catch[Module[{surface, sourceDesc, captured, normalized},
    sourceDesc = h /. Hold[x_] :> HoldComplete[x];
    surface = iri["SurfaceDesc"][sourceDesc, hb, operator,
      If[AssociationQ[options], options, <||>]];
    captured = captureDescIR[h, hb, surface];
    If[compilerFailureQ[captured], Throw[<|"Surface" -> surface,
      "Captured" -> captured, "Normalized" -> captured|>, compilerTag]];
    normalized = normalizeCapturedDesc[captured];
    <|"Surface" -> surface, "Captured" -> captured,
      "Normalized" -> normalized|>
  ], compilerTag];

captureDescIR[h_Hold, hb_HoldComplete, surface_] :=
  Block[{$axisFresh = <||>, $axisKind = <||>, $descRejectReason = None,
      $axisFallbackMemo = <||>, $inlineBindingFacts = {}},
  Catch[Module[{prepared, hp, specs, established, lhsRaw, rhsRaw, lhs, rhsHeld,
          rawBindings, externalBindings, inlineFacts},
    If[! MatchQ[h, Hold[_Rule | _RuleDelayed]],
      Throw[compilerFailure["MalformedDescription", "Capture",
        <|"Source" -> surface|>], compilerTag]];
    prepared = prepareInlineHeld[h];
    If[prepared === $Failed,
      Throw[compilerFailure["CaptureRejected", "Capture",
        <|"Reason" -> descFailReason[], "Source" -> surface|>], compilerTag]];
    hp = prepared["Held"]; specs = prepared["Specs"];
    established = collectEstablished[hp];
    If[established === $Failed,
      Throw[compilerFailure["CaptureRejected", "Capture",
        <|"Reason" -> descFailReason[], "Source" -> surface|>], compilerTag]];
    established = DeleteDuplicates @ Join[established, surfaceBinderNames[hp]];
    $axisFresh = AssociationMap[surfaceAxisKey, established];
    lhsRaw = normShapes @ Extract[hp, {1, 1}];
    rhsRaw = compileDeclarativeRhsSurface[
      normHeldShapes @ Extract[hp, {1, 2}, Hold]];
    If[! declarativeRhsQ[rhsRaw],
      Throw[compilerFailure["NonDeclarativeRHS", "Capture",
        <|"Source" -> iri["SourceRef"][{2}, HoldComplete[rhsRaw]]|>], compilerTag]];
    lhs = captureSurfaceSide[lhsRaw, "LHS", established];
    rhsHeld = captureSurfaceHeld[rhsRaw, "RHS", established];
    rawBindings = Quiet @ Check[ReleaseHold[hb], $Failed];
    If[rawBindings === $Failed,
      Throw[compilerFailure["InvalidBindings", "Capture",
        <|"Source" -> surface|>], compilerTag]];
    If[! MatchQ[rawBindings, {(_Rule | _RuleDelayed) ...}],
      Throw[compilerFailure["InvalidBindings", "Capture", <|
        "Reason" -> "bindings must be a list of axis-name -> size rules " <>
          "(e.g. {n -> 8}); got " <> ToString[rawBindings, InputForm],
        "Source" -> surface|>], compilerTag]];
    externalBindings = canonBindingList[rawBindings, "Scoped"];
    If[StringQ[externalBindings],
      Throw[compilerFailure["InvalidBindings", "Capture",
        <|"Reason" -> externalBindings, "Source" -> surface|>], compilerTag]];
    inlineFacts = captureInlineFacts[specs];
    If[compilerFailureQ[inlineFacts], Throw[inlineFacts, compilerTag]];
    iri["CapturedDesc"][<|
      "Surface" -> surface,
      "CanonicalLHS" -> lhs,
      "CanonicalRHS" -> rhsHeld,
      "EstablishedNames" -> established,
      "AxisKinds" -> Association[$axisKind],
      "InlineBindingFacts" -> inlineFacts,
      "ExternalBindings" -> externalBindings,
      "Bindings" -> hb
    |>]
  ], compilerTag]];

captureInlineFacts[specs_List] :=
  Catch[Map[Function[spec,
    Module[{info = inlineSpecInfo[spec["Spec"]], size},
      If[info === $Failed,
        Throw[compilerFailure["InvalidInlineBinding", "Capture", <|
          "Source" -> spec|>], compilerTag]];
      size = Quiet @ Check[ReleaseHold[spec["Size"]], $Failed];
      <|"Key" -> surfaceAxisKey[info["Name"]], "Size" -> size,
        "Name" -> info["Name"], "Kind" -> info["Kind"],
        "Binder" -> info["Binder"], "TargetHead" -> info["TargetHead"],
        "Source" -> spec["Source"], "SourceExpression" -> spec|>]], specs],
    compilerTag];

captureSurfaceHeld[h_Hold, side_String, established_List] :=
  h /. {
    inlineSizedAxis[s_String, _, _] :> capturedLogicalAxis[s, "String"],
    inlineSizedAxis[s_Symbol, _, _] /; Context[Unevaluated[s]] =!= "System`" :>
      RuleCondition[capturedLogicalAxis[SymbolName[Unevaluated[s]], "Symbol"]],
    inlineSizedAxis[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]], _, _] :>
      RuleCondition[capturedLogicalAxis[SymbolName[Unevaluated[s]], "Symbol"]],
    Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :>
      RuleCondition[capturedBinder[SymbolName[Unevaluated[s]]]],
    Verbatim[Pattern][s_Symbol, Verbatim[BlankSequence[]]] :>
      RuleCondition[capturedNamedSequence[SymbolName[Unevaluated[s]], 1, Blank[]]],
    Verbatim[Pattern][s_Symbol, Verbatim[BlankNullSequence[]]] :>
      RuleCondition[capturedNamedSequence[SymbolName[Unevaluated[s]], 0, Blank[]]],
    (head : (Slot | Highlighted | Framed))[s_String] :>
      head[capturedLogicalAxis[s, "String"]],
    (head : (Slot | Highlighted | Framed))[s_Symbol] /;
        Context[Unevaluated[s]] =!= "System`" :>
      RuleCondition[head[capturedLogicalAxis[
        SymbolName[Unevaluated[s]], "Symbol"]]],
    s_String :> capturedLogicalAxis[s, "String"],
    s_Symbol /; Context[Unevaluated[s]] =!= "System`" &&
        Unevaluated[s] =!= sequenceZipSurface &&
        Unevaluated[s] =!= inlineSizedAxis &&
        MemberQ[established, SymbolName[Unevaluated[s]]] :>
      RuleCondition[capturedLogicalAxis[SymbolName[Unevaluated[s]], "Symbol"]],
    s_Symbol /; Context[Unevaluated[s]] =!= "System`" &&
        Unevaluated[s] =!= sequenceZipSurface &&
        Unevaluated[s] =!= inlineSizedAxis && ValueQ[s] :> s,
    s_Symbol /; Context[Unevaluated[s]] =!= "System`" &&
        Unevaluated[s] =!= sequenceZipSurface &&
        Unevaluated[s] =!= inlineSizedAxis :>
      RuleCondition[capturedAmbientAxis[Context[Unevaluated[s]],
        SymbolName[Unevaluated[s]]]]
  };

surfaceBinderNames[h_Hold] := DeleteDuplicates @ Cases[h,
  Verbatim[Pattern][s_Symbol,
      Verbatim[Blank[]] | Verbatim[BlankSequence[]] |
      Verbatim[BlankNullSequence[]] | Verbatim[Repeated][_] |
      Verbatim[RepeatedNull][_]] :> SymbolName[Unevaluated[s]], Infinity];

captureSurfaceSide[shapes_List, side_String, established_List] :=
  Map[Function[shape,
    If[ListQ[shape], captureSurfaceTerm[#, side, established] & /@ shape, shape]],
    shapes];

captureSurfaceTerm[inlineSizedAxis[x_, _, _], side_, established_] :=
  captureExplicitSurfaceTerm[x, side, established];
captureSurfaceTerm[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]], _, _] :=
  capturedBinder[SymbolName[Unevaluated[s]]];
captureSurfaceTerm[Verbatim[Pattern][s_Symbol, Verbatim[BlankSequence[]]], _, _] :=
  capturedNamedSequence[SymbolName[Unevaluated[s]], 1, Blank[]];
captureSurfaceTerm[Verbatim[Pattern][s_Symbol, Verbatim[BlankNullSequence[]]], _, _] :=
  capturedNamedSequence[SymbolName[Unevaluated[s]], 0, Blank[]];
captureSurfaceTerm[Verbatim[Pattern][s_Symbol, Verbatim[Repeated][body_]], side_, est_] :=
  capturedNamedSequence[SymbolName[Unevaluated[s]], 1,
    captureSurfaceTerm[body, side, est]];
captureSurfaceTerm[Verbatim[Pattern][s_Symbol, Verbatim[RepeatedNull][body_]], side_, est_] :=
  capturedNamedSequence[SymbolName[Unevaluated[s]], 0,
    captureSurfaceTerm[body, side, est]];
captureSurfaceTerm[(head : (Slot | Highlighted | Framed))[x_], side_, est_] :=
  head[captureExplicitSurfaceTerm[x, side, est]];
captureSurfaceTerm[CircleTimes[xs__], side_, est_] :=
  CircleTimes @@ (captureSurfaceTerm[#, side, est] & /@ {xs});
captureSurfaceTerm[CirclePlus[xs__], side_, est_] :=
  CirclePlus @@ (captureSurfaceTerm[#, side, est] & /@ {xs});
captureSurfaceTerm[Verbatim[Repeated][x_], side_, est_] :=
  Repeated[captureSurfaceTerm[x, side, est]];
captureSurfaceTerm[Verbatim[RepeatedNull][x_], side_, est_] :=
  RepeatedNull[captureSurfaceTerm[x, side, est]];
captureSurfaceTerm[s_String, _, _] := capturedLogicalAxis[s, "String"];
captureSurfaceTerm[s_Symbol, side_, est_] /; Context[Unevaluated[s]] =!= "System`" :=
  Module[{name = SymbolName[Unevaluated[s]]},
    If[side === "RHS" && MemberQ[est, name],
      capturedLogicalAxis[name, "Symbol"],
      capturedAmbientAxis[Context[Unevaluated[s]], name]]];
captureSurfaceTerm[x_, _, _] := x;

captureExplicitSurfaceTerm[s_String, _, _] := capturedLogicalAxis[s, "String"];
captureExplicitSurfaceTerm[s_Symbol, _, _] /; Context[Unevaluated[s]] =!= "System`" :=
  capturedLogicalAxis[SymbolName[Unevaluated[s]], "Symbol"];
captureExplicitSurfaceTerm[x_, side_, est_] := captureSurfaceTerm[x, side, est];

(* Inspect held compound heads before releasing the RHS.  Only the declarative shape
   vocabulary is allowed; atoms (including axis symbols and strings) contribute no
   compound head. *)
declarativeRhsQ[h_Hold] :=
  Module[{allowed, heads},
    allowed = {Hold, List, CircleTimes, CirclePlus, Pattern, Blank,
      BlankSequence, BlankNullSequence, Repeated, RepeatedNull,
      Slot, SlotSequence, Highlighted, Framed, Inactive, Sequence,
      sequenceZipSurface, inlineSizedAxis};
    heads = DeleteDuplicates @ Cases[h,
      e_[___] :> Unevaluated[e], {0, Infinity}, Heads -> False];
    AllTrue[heads, MemberQ[allowed, #] &]
  ];

compileDeclarativeRhsSurface[h_Hold] :=
  Replace[h,
    Hold[{MapThread[CircleTimes, lists_List]}] :>
      If[MatchQ[Unevaluated[lists], {{_Symbol} ..}],
        With[{symbols = First /@ lists},
          Hold[{{sequenceZipSurface[CircleTimes, symbols]}}]],
        h],
    {0}];

normalizeCapturedDesc[iri["CapturedDesc"][captured_Association]] :=
  Catch[Module[{lhs, rhs, state, in, out, r, facts, axisTable, normalized},
    lhs = captured["CanonicalLHS"];
    rhs = Quiet @ Check[ReleaseHold[captured["CanonicalRHS"]], $Failed];
    If[rhs === $Failed || ! MatchQ[rhs, {___List}],
      Throw[compilerFailure["InvalidOutputShapes", "Normalize",
        <|"Source" -> captured["Surface"]|>], compilerTag]];
    state = compilerState[captured];
    r = compileShapeList[lhs, "LHS", state];
    If[compilerResultFailureQ[r], Throw[First[r], compilerTag]];
    {in, state} = r;
    r = compileShapeList[rhs, "RHS", state];
    If[compilerResultFailureQ[r], Throw[First[r], compilerTag]];
    {out, state} = r;
    facts = compileBindingFacts[captured["InlineBindingFacts"],
      captured["ExternalBindings"], state];
    If[compilerFailureQ[facts], Throw[facts, compilerTag]];
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
  ], compilerTag];
normalizeCapturedDesc[other_] :=
  compilerFailure["ExpectedCapturedDesc", "Normalize",
    <|"Expression" -> HoldComplete[other]|>];

normalizedDescAssociation[iri["NormalizedDesc"][a_Association]] := a;
normalizedDescAssociation[_] := Missing["NotNormalized"];

compilerState[captured_Association] := <|
  "IRState" -> irNewState[],
  "EstablishedNames" -> captured["EstablishedNames"],
  "AxisKinds" -> captured["AxisKinds"],
  "SequenceAxes" -> <||>,
  "AnonymousSequences" -> <|"LHS" -> {}, "RHSUsed" -> {}|>,
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
  Module[{name = SymbolName[Unevaluated[s]]},
    If[side === "RHS" && MemberQ[state["EstablishedNames"], name],
      compilerAxisForName[name, state],
      compilerAmbientAxis[Context[Unevaluated[s]], name, state]]];

compilerAxisForName[name_String, state_Association] :=
  compilerIntern["axis:" <> name, name, <|"Origin" -> "Established",
    "SurfaceKinds" -> Lookup[state["AxisKinds"], name, {}]|>, state];

compilerAmbientAxis[context_String, name_String, state_Association] :=
  compilerIntern["ambient:" <> context <> name, name,
    <|"Origin" -> "Ambient", "Context" -> context|>, state];

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

compileTerm[capturedBinder[name_String], side_, target_, state_] :=
  compileNamedOccurrenceByName[name, side, "Binder", target, state];
compileTerm[capturedLogicalAxis[name_String, _], side_, target_, state_] :=
  compileNamedOccurrenceByName[name, side, If[side === "RHS", "Reference", "Named"],
    target, state];
compileTerm[capturedAmbientAxis[context_String, name_String], side_, target_, state_] :=
  compileAmbientOccurrence[context, name, side, target, state];
compileTerm[capturedNamedSequence[name_String, min_Integer, body_], side_, target_, state_] :=
  compileNamedSequenceByName[name, side, min, body, target, state];

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
  compileAnonymousSequence[side, 1, target, state];
compileTerm[Verbatim[BlankNullSequence[]], side_, target_, state_] :=
  compileAnonymousSequence[side, 0, target, state];
compileTerm[SlotSequence[1], side_, _, state_] :=
  compileAnonymousSequence[side, 0, SlotSequence, state];

compileTerm[Slot[x_], side_, _, state_] := compileTerm[x, side, Slot, state];
compileTerm[Highlighted[x_], side_, _, state_] :=
  compileTerm[x, side, Highlighted, state];
compileTerm[Framed[x_], side_, _, state_] := compileTerm[x, side, Framed, state];

compileTerm[CircleTimes[xs__], side_, target_, state_] :=
  compileComposite["ProductAxis", {xs}, side, target, state];
compileTerm[CirclePlus[xs__], side_, target_, state_] :=
  compileComposite["DirectSumAxis", {xs}, side, target, state];
compileTerm[Verbatim[Repeated][body_], side_, target_, state_] :=
  compileRepeated[body, side, 1, target, state];
compileTerm[Verbatim[RepeatedNull][body_], side_, target_, state_] :=
  compileRepeated[body, side, 0, target, state];
compileTerm[sequenceZipSurface[CircleTimes, symbols_List], side_, target_, state_] :=
  compileSequenceZip[symbols, side, target, state];

compileTerm[other_, side_, _, state_] :=
  {compilerFailure["UnsupportedTerm", "Normalize",
    <|"Side" -> side, "Expression" -> HoldComplete[other]|>], state};

compileNamedOccurrence[s_Symbol, side_, role_, target_, state_] :=
  Module[{id, occ, st},
    {id, st} = compilerAxisForSymbol[Unevaluated[s], side, state];
    {occ, st} = compilerOccurrence[st];
    If[side === "RHS" && KeyExistsQ[st["SequenceAxes"], id],
      {iri["SequenceAxis"][occ, id,
        <|"Side" -> side, "Minimum" -> 0, "Pattern" -> None,
          "SyntaxRole" -> "SequenceReference", "TargetHead" -> target|>], st},
      {iri["AxisOccurrence"][occ, id,
        <|"Side" -> side, "SyntaxRole" -> role,
          "TargetHead" -> target|>], st}]
  ];

compileNamedOccurrenceByName[name_String, side_, role_, target_, state_] :=
  Module[{id, occ, st},
    {id, st} = compilerAxisForName[name, state];
    {occ, st} = compilerOccurrence[st];
    If[side === "RHS" && KeyExistsQ[st["SequenceAxes"], id],
      {iri["SequenceAxis"][occ, id,
        <|"Side" -> side, "Minimum" -> 0, "Pattern" -> None,
          "SyntaxRole" -> "SequenceReference", "TargetHead" -> target|>], st},
      {iri["AxisOccurrence"][occ, id,
        <|"Side" -> side, "SyntaxRole" -> role,
          "TargetHead" -> target|>], st}]
  ];

compileAmbientOccurrence[context_, name_, side_, target_, state_] :=
  Module[{id, occ, st},
    {id, st} = compilerAmbientAxis[context, name, state];
    {occ, st} = compilerOccurrence[st];
    {iri["AxisOccurrence"][occ, id,
      <|"Side" -> side, "SyntaxRole" -> If[side === "RHS", "Reference", "Ambient"],
        "TargetHead" -> target|>], st}
  ];

compileNamedSequence[s_Symbol, side_, min_, body_, target_, state_] :=
  Module[{id, occ, st, child, r},
    {id, st} = compilerAxisForSymbol[Unevaluated[s], side, state];
    If[side === "LHS",
      st = Append[st, "SequenceAxes" -> Append[st["SequenceAxes"], id -> True]]];
    {occ, st} = compilerOccurrence[st];
    If[MatchQ[Unevaluated[body], Verbatim[Blank[]]],
      child = None,
      r = compileTerm[body, side, None, st];
      If[compilerResultFailureQ[r], Throw[r, compilerTag]];
      child = First[r]; st = Last[r]];
    {iri["SequenceAxis"][occ, id,
      <|"Side" -> side, "Minimum" -> min, "Pattern" -> child,
        "TargetHead" -> target|>], st}
  ];

compileNamedSequenceByName[name_String, side_, min_, body_, target_, state_] :=
  Module[{id, occ, st, child, r},
    {id, st} = compilerAxisForName[name, state];
    If[side === "LHS",
      st = Append[st, "SequenceAxes" -> Append[st["SequenceAxes"], id -> True]]];
    {occ, st} = compilerOccurrence[st];
    If[MatchQ[Unevaluated[body], Verbatim[Blank[]]], child = None,
      r = compileTerm[body, side, None, st];
      If[compilerResultFailureQ[r], Throw[r, compilerTag]];
      child = First[r]; st = Last[r]];
    {iri["SequenceAxis"][occ, id,
      <|"Side" -> side, "Minimum" -> min, "Pattern" -> child,
        "TargetHead" -> target|>], st}
  ];

compileAnonymousSequence[side_, min_, target_, state_Association] :=
  Module[{occ, id, st, records, used, candidates, chosen, record},
    {occ, st} = compilerOccurrence[state];
    If[side === "LHS",
      id = occ;
      record = <|"Id" -> id, "Targeted" -> (target =!= None)|>;
      st = Append[st, "AnonymousSequences" ->
        Append[st["AnonymousSequences"], "LHS" ->
          Append[st["AnonymousSequences"]["LHS"], record]]],
      records = st["AnonymousSequences"]["LHS"];
      used = st["AnonymousSequences"]["RHSUsed"];
      candidates = Select[records,
        # ["Targeted"] === (target =!= None) && ! MemberQ[used, # ["Id"]] &];
      If[candidates === {},
        id = Missing["Unbound"],
        chosen = First[candidates]; id = chosen["Id"];
        st = Append[st, "AnonymousSequences" ->
          Append[st["AnonymousSequences"], "RHSUsed" -> Append[used, id]]]]];
    If[MissingQ[id],
      {compilerFailure["UnboundAnonymousSequence", "Normalize", <|
        "Side" -> side, "TargetHead" -> target|>], st},
      {iri["SequenceAxis"][occ, id,
        <|"Side" -> side, "Minimum" -> min, "Named" -> False,
          "Pattern" -> None, "TargetHead" -> target|>], st}]
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
    If[compilerResultFailureQ[r], Throw[r, compilerTag]];
    st = Last[r]; {occ, st} = compilerOccurrence[st];
    {iri[head][occ, First[r],
      <|"Side" -> side, "TargetHead" -> target|>], st}
  ];

compileRepeated[body_, side_, min_, target_, state_] :=
  Module[{r, occ, st},
    r = compileTerm[body, side, None, state];
    If[compilerResultFailureQ[r], Throw[r, compilerTag]];
    st = Last[r];
    If[side === "RHS" && Head[First[r]] === iri["SequenceAxis"],
      {Replace[First[r], iri["SequenceAxis"][o_, id_, meta_Association] :>
        iri["SequenceAxis"][o, id,
          Join[meta, <|"TargetHead" -> target|>]]], st},
      {occ, st} = compilerOccurrence[st];
      {iri["RepeatedGroup"][occ, First[r],
        <|"Side" -> side, "Minimum" -> min, "TargetHead" -> target|>], st}]
  ];

compileSequenceZip[symbols_List, side_, target_, state_Association] :=
  Catch[Module[{st = state, refs = {}, id, occ},
    Do[
      If[MatchQ[symbol, capturedLogicalAxis[_String, _]],
        {id, st} = compilerAxisForName[First[symbol], st],
        If[Head[symbol] =!= Symbol,
          Throw[{compilerFailure["InvalidSequenceZipReference", "Normalize", <|
            "Expression" -> HoldComplete[symbol]|>], st}, compilerTag]];
        {id, st} = compilerAxisForSymbol[symbol, side, st]];
      AppendTo[refs, iri["SequenceReference"][id]],
      {symbol, symbols}];
    {occ, st} = compilerOccurrence[st];
    {iri["SequenceZip"][occ, CircleTimes, refs,
      <|"Side" -> side, "TargetHead" -> target|>], st}
  ], compilerTag];

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
            "Name" -> compilerAxisName[bindingFactAxisId[First[group]], state],
            "Values" -> values|>], compilerTag]];
      fact = First[group];
      AppendTo[out, fact],
      {group, grouped}];
    out
  ], compilerTag];

compilerBindingAxisId[surfaceAxisKey[name_String], state_Association] :=
  Lookup[state["IRState"]["NameToAxisId"], "axis:" <> name, Missing["UnknownAxis"]];
compilerBindingAxisId[key_Symbol, state_Association] :=
  Lookup[state["IRState"]["NameToAxisId"],
    "ambient:" <> Context[Unevaluated[key]] <> SymbolName[Unevaluated[key]],
    Missing["UnknownAxis"]];
compilerBindingAxisId[_, _] := Missing["UnknownAxis"];

bindingFactAxisId[iri["BindingFact"][id_, _, _]] := id;
bindingFactSize[iri["BindingFact"][_, size_, _]] := size;

compilerAxisName[id_, state_Association] :=
  Replace[Lookup[state["IRState"]["AxisMetadata"], id, Missing[]],
    iri["AxisInfo"][name_String, _Association] :> name];

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
