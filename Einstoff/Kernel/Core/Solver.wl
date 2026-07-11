(* ::Package:: *)

(* Explicit positive-integer shape constraints over normalized IR.  Algebraic solver
   variables are Indexed expressions keyed by AxisId's integer payload; no symbol is
   created per logical axis. *)

PackageScoped[{buildConstraintDesc, solveConstraintDesc, solveDescIR}]

irs[name_String] := Symbol["Einstoff`Internal`IR`" <> name];

solveDescIR[compiled_Association, inputShapes_] :=
  Catch[Module[{normalized, constraints, solved},
    normalized = Lookup[compiled, "Normalized", Missing["Normalized"]];
    If[solverFailureQ[normalized],
      Throw[Join[compiled, <|"Constraints" -> normalized, "Solved" -> normalized|>],
        solverTag]];
    constraints = buildConstraintDesc[normalized, inputShapes];
    If[solverFailureQ[constraints],
      constraints = solverEnrichFailure[constraints, compiled];
      Throw[Join[compiled, <|"Constraints" -> constraints, "Solved" -> constraints|>],
        solverTag]];
    solved = solveConstraintDesc[constraints];
    If[solverFailureQ[solved], solved = solverEnrichFailure[solved, compiled]];
    Join[compiled, <|"Constraints" -> constraints, "Solved" -> solved|>]
  ], solverTag];

buildConstraintDesc[normalized : irs["NormalizedDesc"][a_Association],
    inputShapes_] :=
  Catch[Module[{inputIR, shapes, constraints = {}, bindings, terms, r,
          captureState, solvedInputs = {}, solvedOutputs},
    If[! ListQ[inputShapes] || ! AllTrue[inputShapes, ListQ],
      Throw[solverFailure["InvalidInputShapes", "Constraints",
        <|"InputShapes" -> HoldComplete[inputShapes]|>], solverTag]];
    inputIR = a["Inputs"];
    shapes = Replace[inputIR, irs["Inputs"][s_List] :> s];
    If[! ListQ[shapes] || Length[shapes] =!= Length[inputShapes],
      Throw[solverFailure["OperandCountMismatch", "Constraints",
        <|"Expected" -> If[ListQ[shapes], Length[shapes], Missing[]],
          "Actual" -> Length[inputShapes]|>], solverTag]];
    bindings = Replace[a["Bindings"], irs["BindingFacts"][f_List] :> f];
    captureState = <|"Lengths" -> <||>, "Members" -> <||>,
      "PointwiseAxes" -> {},
      "SourceMap" -> Replace[a["SourceMap"],
        irs["SourceMap"][m_Association] :> m]|>;
    Do[
      With[{id = bindingFactId[fact], size = bindingFactValue[fact],
          source = bindingFactSource[fact]},
        If[MissingQ[solverSequenceBindingValue[size]],
          AppendTo[constraints,
            If[AssociationQ[source] && TrueQ[Lookup[source, "Binder", False]],
              irs["InlineSizeCheck"][id, size, source],
              irs["KnownSize"][id, size, source]]],
          r = seedBoundSequence[id, solverSequenceBindingValue[size], captureState, source];
          If[solverFailureQ[r], Throw[r, solverTag]];
          captureState = r["State"];
          constraints = Join[constraints, r["Constraints"]]]],
      {fact, bindings}];
    Do[
      terms = Replace[shapes[[i]], irs["Shape"][t_List] :> t];
      r = expandInputTerms[terms, inputShapes[[i]], i, captureState];
      If[solverFailureQ[r], Throw[r, solverTag]];
      AppendTo[solvedInputs, irs["Shape"][r["Terms"]]];
      constraints = Join[constraints, r["Constraints"]];
      captureState = r["State"],
      {i, Length[shapes]}];
    With[{scalarIds = DeleteDuplicates @ Cases[constraints,
        (irs["EqualSize"] | irs["TensorDimension"])[
            irs["SizeAxis"][id_], ___] :> id, Infinity],
        pointwiseIds = Lookup[captureState, "PointwiseAxes", {}]},
      If[Intersection[scalarIds, pointwiseIds] =!= {},
        Throw[solverFailure["SequenceScalarCollision", "Constraints", <|
          "Axes" -> Intersection[scalarIds, pointwiseIds]|>], solverTag]]];
    solvedOutputs = expandOutputShapes[a["Outputs"], captureState];
    If[solverFailureQ[solvedOutputs], Throw[solvedOutputs, solverTag]];
    irs["ConstraintDesc"][<|
      "Normalized" -> normalized,
      "InputShapes" -> inputShapes,
      "SolvedInputs" -> irs["Inputs"][solvedInputs],
      "SolvedOutputs" -> solvedOutputs,
      "SequenceCaptures" -> captureState,
      "SourceMap" -> a["SourceMap"],
      "Constraints" -> irs["Constraints"][constraints]
    |>]
  ], solverTag];
buildConstraintDesc[other_, inputShapes_] :=
  solverFailure["ExpectedNormalizedDesc", "Constraints",
    <|"Expression" -> HoldComplete[other],
      "InputShapes" -> HoldComplete[inputShapes]|>];

bindingFactId[irs["BindingFact"][id_, _, _, _]] := id;
bindingFactValue[irs["BindingFact"][_, value_, _, _]] := value;
bindingFactSource[irs["BindingFact"][_, _, kind_, source_Association]] :=
  Join[<|"Kind" -> kind|>, source];

solverSequenceBindingValue[Verbatim[Inactive][Sequence][xs___]] := {xs};
solverSequenceBindingValue[_] := Missing["NotSequenceBinding"];

seedBoundSequence[id_, values_List, state_Association, source_] :=
  If[! AllTrue[values, IntegerQ[#] && # > 0 &],
    solverFailure["InvalidSequenceBinding", "Constraints", <|
      "Axis" -> id, "Value" -> HoldComplete[values]|>],
    Module[{members, constraints},
      members = MapIndexed[
        irs["AxisOccurrence"][irs["SequenceOccurrence"][id, First[#2]],
          irs["SequenceMemberId"][id, First[#2]],
          <|"Side" -> "Binding", "SequenceIndex" -> First[#2]|>] &,
        values];
      constraints = MapThread[
        irs["EqualSize"][sizeExpression[#1], #2, source] &,
        {members, values}];
      <|"State" -> Join[state, <|
          "Lengths" -> Append[state["Lengths"], id -> Length[values]],
          "Members" -> Append[state["Members"], id -> members]|>],
        "Constraints" -> constraints|>]];

sizeExpression[irs["AxisOccurrence"][_, id_, _]] := irs["SizeAxis"][id];
sizeExpression[irs["LiteralAxis"][_, n_Integer, _]] := irs["SizeLiteral"][n];
sizeExpression[irs["ProductAxis"][_, children_List, _]] :=
  sizeComposite["SizeProduct", children];
sizeExpression[irs["DirectSumAxis"][_, children_List, _]] :=
  sizeComposite["SizeSum", children];
sizeExpression[other_] := solverFailure["UnsupportedSizeTerm", "Constraints",
  <|"Expression" -> HoldComplete[other]|>];

sequenceTermQ[term_] := MemberQ[{irs["SequenceAxis"], irs["RepeatedGroup"]},
  Head[Unevaluated[term]]];

sequenceMinimum[irs["SequenceAxis"][_, payload_Association, _]] :=
  payload["Minimum"];
sequenceMinimum[irs["SequenceAxis"][_, _, meta_Association]] := meta["Minimum"];
sequenceMinimum[irs["RepeatedGroup"][_, _, meta_Association]] := meta["Minimum"];

expandInputTerms[terms_List, dims_List, inputIndex_Integer, state_Association] :=
  Catch[Module[{sequencePositions, fixedCount, minima, residual, lengths,
          out = {}, constraints = {}, st = state, cursor = 1, len, expanded, slice},
    sequencePositions = Select[Range[Length[terms]], sequenceTermQ[terms[[#]]] &];
    fixedCount = Length[terms] - Length[sequencePositions];
    minima = sequenceMinimum /@ terms[[sequencePositions]];
    residual = Length[dims] - fixedCount;
    If[residual < Total[minima],
      Throw[solverFailure["RankMismatch", "Constraints", <|
        "Input" -> inputIndex, "Minimum" -> fixedCount + Total[minima],
        "Actual" -> Length[dims]|>], solverTag]];
    lengths = Which[
      sequencePositions === {},
        If[residual === 0, {},
          Throw[solverFailure["RankMismatch", "Constraints", <|
            "Input" -> inputIndex, "Expected" -> fixedCount,
            "Actual" -> Length[dims]|>], solverTag]],
      Length[sequencePositions] === 1,
        {residual},
      residual === Total[minima],
        minima,
      True,
        Throw[solverFailure["AmbiguousSequenceDecomposition", "Constraints", <|
          "Input" -> inputIndex, "ResidualRank" -> residual,
          "Minimums" -> minima|>], solverTag]];
    Do[
      If[sequenceTermQ[terms[[j]]],
        len = lengths[[First @ FirstPosition[sequencePositions, j]]];
        slice = Take[dims, {cursor, cursor + len - 1}];
        expanded = expandCapturedSequence[terms[[j]], slice, st];
        If[solverFailureQ[expanded], Throw[expanded, solverTag]];
        out = Join[out, expanded["Terms"]];
        constraints = Join[constraints,
          Lookup[expanded, "Constraints", {}],
          MapIndexed[irs["TensorDimension"][sizeExpression[#1], inputIndex,
              cursor + First[#2] - 1, slice[[First[#2]]],
              solverTermSource[terms[[j]], st]] &,
            expanded["Terms"]]];
        st = expanded["State"];
        cursor += len,
        expanded = expandBoundSequencesInTerm[terms[[j]], st];
        If[Head[expanded] === irs["AnonymousAxis"] && Length[expanded] === 3 &&
            AssociationQ[Last[expanded]],
          AppendTo[out, Replace[expanded,
            irs["AnonymousAxis"][occ_, _, meta_Association] :>
              irs["LiteralAxis"][occ, dims[[cursor]], meta]]],
          AppendTo[out, expanded];
          expanded = sizeExpression[expanded];
          If[solverFailureQ[expanded], Throw[expanded, solverTag]];
          AppendTo[constraints, irs["TensorDimension"][expanded,
            inputIndex, cursor, dims[[cursor]],
            solverTermSource[terms[[j]], st]]]];
        cursor++],
      {j, Length[terms]}];
    <|"Terms" -> out, "Constraints" -> constraints, "State" -> st|>
  ], solverTag];

solverTermOccurrence[head_[occ_, ___]] /;
    MemberQ[{irs["AxisOccurrence"], irs["LiteralAxis"], irs["ProductAxis"],
      irs["DirectSumAxis"], irs["AnonymousAxis"], irs["SequenceAxis"],
      irs["RepeatedGroup"], irs["SequenceZip"]}, head] := occ;
solverTermOccurrence[_] := Missing["NoOccurrence"];

solverTermSource[term_, state_Association] :=
  Lookup[Lookup[state, "SourceMap", <||>], solverTermOccurrence[term],
    irs["SourceRef"][{}, HoldComplete[term]]];

expandBoundSequencesInTerm[
    irs["SequenceAxis"][_, id_, meta_Association], state_Association] :=
  Module[{members = Lookup[state["Members"], id,
      solverFailure["UnboundSequence", "Constraints", <|"Sequence" -> id|>]]},
    If[ListQ[members] && Length[members] < Lookup[meta, "Minimum", 0],
      solverFailure["SequenceMinimum", "Constraints", <|
        "Sequence" -> id, "Minimum" -> meta["Minimum"],
        "Actual" -> Length[members]|>],
      members]];
expandBoundSequencesInTerm[
    head_[occ_, children_List, meta_Association], state_Association] /;
      MemberQ[{irs["ProductAxis"], irs["DirectSumAxis"]}, head] :=
  Module[{expanded = expandBoundSequencesInTerm[#, state] & /@ children},
    If[AnyTrue[expanded, solverFailureQ],
      First @ Select[expanded, solverFailureQ],
      head[occ, Flatten[expanded, 1], meta]]];
expandBoundSequencesInTerm[term_, _] := term;

expandCapturedSequence[irs["SequenceAxis"][occ_, id_, meta_Association],
    dims_List, state_Association] :=
  Catch[Module[{sequenceId = If[AssociationQ[id], occ, id],
      pattern = Lookup[meta, "Pattern", None], prior, terms, st = state, ids,
      equalities},
    prior = Lookup[st["Lengths"], sequenceId, Missing["NewSequence"]];
    If[! MissingQ[prior] && prior =!= Length[dims],
      Throw[solverFailure["SequenceLengthMismatch", "Constraints", <|
        "Sequence" -> sequenceId, "Expected" -> prior,
        "Actual" -> Length[dims]|>],
        solverTag]];
    terms = If[pattern === None,
      Table[irs["AxisOccurrence"][irs["SequenceOccurrence"][occ, k],
        irs["SequenceMemberId"][sequenceId, k],
        Join[meta, <|"SequenceIndex" -> k|>]], {k, Length[dims]}],
      Table[specializeSequenceTerm[pattern, occ, k], {k, Length[dims]}]];
    equalities = Join[
      {irs["SequenceLength"][sequenceId, Length[dims],
        solverTermSource[irs["SequenceAxis"][occ, id, meta], st]]},
      If[pattern === None, {},
      Flatten[Table[sequenceStaticEqualities[pattern, k],
        {k, Length[dims]}], 1]]];
    st = Join[st, <|
      "Lengths" -> Append[st["Lengths"], sequenceId -> Length[dims]],
      "Members" -> Append[st["Members"], sequenceId -> terms]|>];
    ids = DeleteDuplicates @ Cases[pattern,
      irs["AxisOccurrence"][_, inner_, _] :> inner, {0, Infinity}];
    Do[With[{members = Cases[terms,
        node : irs["AxisOccurrence"][_, irs["SequenceMemberId"][inner, _], _] :>
          node, Infinity]},
      If[members =!= {}, st = Join[st, <|"Members" ->
        Append[st["Members"], inner -> members]|>]]], {inner, ids}];
    st = Append[st, "PointwiseAxes" ->
      DeleteDuplicates @ Join[Lookup[st, "PointwiseAxes", {}], ids]];
    <|"Terms" -> terms, "Constraints" -> equalities, "State" -> st|>
  ], solverTag];
expandCapturedSequence[irs["RepeatedGroup"][occ_, pattern_, meta_Association],
    dims_List, state_Association] :=
  expandCapturedSequence[irs["SequenceAxis"][occ, occ,
    Join[meta, <|"Pattern" -> pattern|>]], dims, state];

specializeSequenceTerm[
    irs["AxisOccurrence"][occ_, id_, meta_Association], outerOcc_, k_] :=
  irs["AxisOccurrence"][irs["SequenceOccurrence"][occ, k],
    irs["SequenceMemberId"][id, k],
    Join[meta, <|"SequenceIndex" -> k,
      "SequenceOccurrence" -> outerOcc|>]];
specializeSequenceTerm[
    head_[occ_, children_List, meta_Association], outerOcc_, k_] /;
      MemberQ[{irs["ProductAxis"], irs["DirectSumAxis"]}, head] :=
  head[irs["SequenceOccurrence"][occ, k],
    specializeSequenceTerm[#, outerOcc, k] & /@ children,
    Join[meta, <|"SequenceIndex" -> k|>]];
specializeSequenceTerm[term_, _, _] := term;

sequenceStaticEqualities[pattern_, k_Integer] :=
  Cases[pattern,
    irs["AxisOccurrence"][_, id_, meta_Association] /;
        Lookup[meta, "SyntaxRole", None] =!= "Binder" :>
      irs["EqualSizeExpr"][
        irs["SizeAxis"][irs["SequenceMemberId"][id, k]],
        irs["SizeAxis"][id], <|"SequenceIndex" -> k|>],
    {0, Infinity}];

expandOutputShapes[irs["Outputs"][shapes_List], state_Association] :=
  Catch[irs["Outputs"] @ Map[
    Function[shape,
      Module[{terms = Replace[shape, irs["Shape"][xs_List] :> xs], expanded},
        expanded = Flatten[expandOutputTerm[#, state] & /@ terms, 1];
        If[AnyTrue[expanded, solverFailureQ],
          Throw[First @ Select[expanded, solverFailureQ], solverTag]];
        irs["Shape"][expanded]]],
    shapes], solverTag];

expandOutputTerm[irs["RepeatedGroup"][occ_, child_, meta_Association],
    state_Association] :=
  Module[{ids, allMemberLists, pairs, memberLists, length},
    ids = DeleteDuplicates @ Cases[child,
      irs["AxisOccurrence"][_, id_, _] :> id, {0, Infinity}];
    allMemberLists = Lookup[state["Members"], ids, Missing["UnknownProjection"]];
    pairs = Select[Transpose[{ids, allMemberLists}],
      Function[pair, ListQ[pair[[2]]]]];
    ids = If[pairs === {}, {}, pairs[[All, 1]]];
    memberLists = If[pairs === {}, {}, pairs[[All, 2]]];
    If[ids === {} || AnyTrue[memberLists, MissingQ],
      {solverFailure["UnknownSequenceProjection", "Solve", <|
        "Expression" -> HoldComplete[child]|>]},
      length = DeleteDuplicates[Length /@ memberLists];
      If[Length[length] =!= 1,
        {solverFailure["SequenceProjectionLengthMismatch", "Solve", <|
          "Axes" -> ids|>]},
        Table[specializeOutputSequenceTerm[child, occ, k, state],
          {k, First[length]}]]]
  ];
expandOutputTerm[irs["SequenceAxis"][_, id_, _], state_Association] :=
  With[{members = Lookup[state["Members"], id, Missing["UnknownSequence"]]},
    If[MissingQ[members],
      {solverFailure["UnknownSequenceReference", "Solve", <|"Sequence" -> id|>]},
      members]];
expandOutputTerm[irs["SequenceProjection"][_,
    irs["SequenceReference"][id_, ___], _Association], state_Association] :=
  With[{members = Lookup[state["Members"], id, Missing["UnknownSequence"]]},
    If[MissingQ[members],
      {solverFailure["UnknownSequenceReference", "Solve", <|"Sequence" -> id|>]},
      members]];
expandOutputTerm[irs["SequenceZip"][occ_, CircleTimes, refs_List,
    meta_Association], state_Association] :=
  Module[{ids, memberLists, lengths},
    ids = Replace[refs, irs["SequenceReference"][id_] :> id, {1}];
    memberLists = Lookup[state["Members"], ids, Missing["UnknownSequence"]];
    If[AnyTrue[memberLists, MissingQ],
      {solverFailure["UnknownSequenceZipReference", "Solve", <|"Axes" -> ids|>]},
      lengths = DeleteDuplicates[Length /@ memberLists];
      If[Length[lengths] =!= 1,
        {solverFailure["SequenceZipLengthMismatch", "Solve", <|
          "Axes" -> ids, "Lengths" -> (Length /@ memberLists)|>]},
        Table[irs["ProductAxis"][irs["SequenceOccurrence"][occ, k],
          memberLists[[All, k]], Join[meta, <|"SequenceIndex" -> k|>]],
          {k, First[lengths]}]]]
  ];
expandOutputTerm[head_[occ_, children_List, meta_Association], state_Association] /;
    MemberQ[{irs["ProductAxis"], irs["DirectSumAxis"]}, head] :=
  Module[{expanded = expandOutputTerm[#, state] & /@ children},
    If[AnyTrue[Flatten[expanded, 1], solverFailureQ],
      {First @ Select[Flatten[expanded, 1], solverFailureQ]},
      {head[occ, Flatten[expanded, 1], meta]}]];
expandOutputTerm[term_, _] := {term};

specializeOutputSequenceTerm[
    irs["AxisOccurrence"][occ_, id_, meta_Association], outerOcc_, k_,
    state_Association] :=
  If[KeyExistsQ[state["Members"], id] && Length[state["Members"][id]] >= k,
    irs["AxisOccurrence"][irs["SequenceOccurrence"][occ, k],
      irs["SequenceMemberId"][id, k],
      Join[meta, <|"SequenceIndex" -> k,
        "SequenceOccurrence" -> outerOcc|>]],
    irs["AxisOccurrence"][irs["SequenceOccurrence"][occ, k], id,
      Join[meta, <|"SequenceIndex" -> k,
        "SequenceOccurrence" -> outerOcc|>]]];
specializeOutputSequenceTerm[head_[occ_, children_List, meta_Association],
    outerOcc_, k_, state_Association] /;
      MemberQ[{irs["ProductAxis"], irs["DirectSumAxis"]}, head] :=
  head[irs["SequenceOccurrence"][occ, k],
    specializeOutputSequenceTerm[#, outerOcc, k, state] & /@ children,
    Join[meta, <|"SequenceIndex" -> k|>]];
specializeOutputSequenceTerm[term_, _, _, _] := term;

sizeComposite[head_String, children_List] :=
  Catch[Module[{out = {}, r},
    Do[
      r = sizeExpression[child];
      If[solverFailureQ[r], Throw[r, solverTag]];
      AppendTo[out, r],
      {child, children}];
    irs[head][out]
  ], solverTag];

solveConstraintDesc[constraint : irs["ConstraintDesc"][a_Association]] :=
  Catch[Module[{normalized, constraints, axisIds, variables, idToVariable, equations,
          directSizes, conflict, result, concrete, rules, axisSizes, outputs,
          outShapes},
    normalized = a["Normalized"];
    constraints = Replace[a["Constraints"], irs["Constraints"][c_List] :> c];
    axisIds = DeleteDuplicates @ Join[
      Cases[constraints, irs["SizeAxis"][id_] :> id, Infinity],
      Cases[constraints,
        (irs["KnownSize"] | irs["InlineSizeCheck"])[id_, _, _] :> id,
        Infinity]];
    directSizes = GroupBy[
      Cases[constraints,
        (irs["EqualSize"] | irs["TensorDimension"])[
            irs["SizeAxis"][id_], ___, n_Integer, _] :> id -> n],
      First -> Last];
    conflict = SelectFirst[Normal[directSizes],
      Length[DeleteDuplicates[Last[#]]] > 1 &, Missing["NoConflict"]];
    If[! MissingQ[conflict],
      With[{conflictId = First[conflict]},
        Throw[solverFailure["ConflictingAxisSizes", "Solve", <|
          "Axis" -> conflictId,
          "Expected" -> First[Last[conflict]],
          "Actual" -> Last[Last[conflict]],
          "Sources" -> Cases[constraints,
            (irs["EqualSize"] | irs["TensorDimension"])[
                irs["SizeAxis"][id_], ___, source_] /;
                id === conflictId :> source]
        |>], solverTag]]];
    variables = solverVariable /@ axisIds;
    idToVariable = AssociationThread[axisIds, variables];
    equations = constraintEquation[#, idToVariable] & /@ constraints;
    If[AnyTrue[equations, solverFailureQ],
      Throw[First @ Select[equations, solverFailureQ], solverTag]];
    result = Quiet @ Check[
      Solve[Join[equations, Thread[variables > 0]], variables, Integers], $Failed];
    If[result === $Failed || result === {},
      Throw[solverFailure["UnsatisfiableConstraints", "Solve",
        <|"Constraints" -> constraint|>], solverTag]];
    concrete = Select[result,
      AllTrue[variables /. #, IntegerQ[#] && # > 0 &] &];
    If[Length[concrete] =!= 1,
      Throw[solverFailure[
        If[concrete === {}, "UnderdeterminedConstraints", "NonUniqueConstraints"],
        "Solve", <|"Solutions" -> result|>], solverTag]];
    rules = First[concrete];
    axisSizes = AssociationThread[axisIds, variables /. rules];
    outputs = a["SolvedOutputs"];
    outShapes = concreteOutputShapes[outputs, axisSizes];
    If[solverFailureQ[outShapes], Throw[outShapes, solverTag]];
    irs["SolvedDesc"][<|
      "Normalized" -> normalized,
      "Constraints" -> constraint,
      "InputShapes" -> a["InputShapes"],
      "Inputs" -> a["SolvedInputs"],
      "Outputs" -> a["SolvedOutputs"],
      "SequenceCaptures" -> a["SequenceCaptures"],
      "SourceMap" -> a["SourceMap"],
      "OutputShapes" -> outShapes,
      "AxisSizes" -> axisSizes
    |>]
  ], solverTag];
solveConstraintDesc[other_] := solverFailure["ExpectedConstraintDesc", "Solve",
  <|"Expression" -> HoldComplete[other]|>];

solverVariable[irs["AxisId"][n_Integer]] := Indexed[solverAxis, {n}];
solverVariable[irs["SequenceMemberId"][irs["AxisId"][n_Integer], k_Integer]] :=
  Indexed[solverSequenceAxis, {n, k}];
solverVariable[irs["SequenceMemberId"][irs["OccurrenceId"][n_Integer], k_Integer]] :=
  Indexed[solverAnonymousSequence, {n, k}];

constraintEquation[irs["KnownSize"][id_, n_, source_], vars_Association] :=
  If[IntegerQ[n] && n > 0, vars[id] == n,
    solverFailure["InvalidKnownSize", "Constraints",
      <|"Axis" -> id, "Value" -> HoldComplete[n], "Source" -> source|>]];
constraintEquation[irs["InlineSizeCheck"][id_, n_, source_], vars_Association] :=
  If[IntegerQ[n] && n > 0, vars[id] == n,
    solverFailure["InvalidKnownSize", "Constraints",
      <|"Axis" -> id, "Value" -> HoldComplete[n], "Source" -> source|>]];
constraintEquation[irs["TensorDimension"][expr_, _, _, n_Integer, _],
    vars_Association] := algebraicSize[expr, vars] == n;
constraintEquation[irs["SequenceLength"][_, n_Integer, _], _Association] := n >= 0;
constraintEquation[irs["EqualSize"][expr_, n_Integer, _], vars_Association] :=
  algebraicSize[expr, vars] == n;
constraintEquation[irs["EqualSizeExpr"][left_, right_, _], vars_Association] :=
  algebraicSize[left, vars] == algebraicSize[right, vars];
constraintEquation[other_, _] := solverFailure["UnsupportedConstraint", "Constraints",
  <|"Constraint" -> HoldComplete[other]|>];

algebraicSize[irs["SizeAxis"][id_], vars_Association] := vars[id];
algebraicSize[irs["SizeLiteral"][n_Integer], _] := n;
algebraicSize[irs["SizeProduct"][xs_List], vars_Association] :=
  Times @@ Table[algebraicSize[x, vars], {x, xs}];
algebraicSize[irs["SizeSum"][xs_List], vars_Association] :=
  Plus @@ Table[algebraicSize[x, vars], {x, xs}];

concreteOutputShapes[irs["Outputs"][shapes_List], sizes_Association] :=
  Catch[Module[{out = {}, terms, dims, value},
    Do[
      terms = Replace[shape, irs["Shape"][t_List] :> t];
      dims = {};
      Do[
        value = concreteTermSize[term, sizes];
        If[solverFailureQ[value], Throw[value, solverTag]];
        AppendTo[dims, value],
        {term, terms}];
      AppendTo[out, dims],
      {shape, shapes}];
    out
  ], solverTag];
concreteOutputShapes[other_, _] := solverFailure["InvalidOutputIR", "Solve",
  <|"Expression" -> HoldComplete[other]|>];

concreteTermSize[term_, sizes_Association] :=
  Module[{expr = sizeExpression[term], value},
    If[solverFailureQ[expr], expr,
      value = algebraicSize[expr, Association @ KeyValueMap[
        (#1 -> #2) &, sizes]];
      If[IntegerQ[value] && value > 0, value,
        solverFailure["UnresolvedOutputSize", "Solve",
          <|"Term" -> HoldComplete[term], "Value" -> value|>]]]
  ];

solverFailure[tag_, stage_, details_Association] :=
  irs["FailureRecord"][tag, stage, details];
solverFailureQ[expr_] := Head[Unevaluated[expr]] === irs["FailureRecord"];

solverEnrichFailure[failure_, compiled_Association] :=
  Module[{surface = Lookup[compiled, "Surface", None], operator = None,
      source = irs["SourceRef"][{}, HoldComplete[None]]},
    Replace[surface,
      irs["SurfaceDesc"][held_HoldComplete, _, op_, _] :>
        (operator = op; source = irs["SourceRef"][{}, held])];
    irEnrichFailure[failure, <|"Operator" -> operator,
      "SourceReference" -> source, "MessageParameters" -> {}|>]
  ];
