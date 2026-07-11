(* ::Package:: *)

(* Operator-neutral effect classification over a concrete SolvedDesc. *)

PackageScoped[{analyzeSolvedDesc, operationSpec}]

ira[name_String] := Symbol["Einstoff`Internal`IR`" <> name];

baseOperationSpec[input_, output_, repeated_, preservation_, function_] := <|
  "InputArity" -> input, "OutputArity" -> output,
  "RepeatedInputPolicy" -> repeated,
  "ShapePreservation" -> preservation,
  "UserFunctionContract" -> function
|>;

operationSpec["Massage"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{1, 1}, {1, Infinity}, "PairwiseOnly", "Structural", None], <|
    "Broadcast" -> True, "Reduce" -> True, "WithinContract" -> True,
    "CrossContract" -> False, "DirectSum" -> True|>];
operationSpec["Reshape"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{1, 1}, {1, 1}, False, "Bijective", None], <|
    "Broadcast" -> "UnitOnly", "Reduce" -> False, "WithinContract" -> False,
    "CrossContract" -> False, "DirectSum" -> False|>];
operationSpec["Contract"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{1, 1}, {1, 1}, "PairwiseOnly", "Contracting", None], <|
    "Broadcast" -> "UnitOnly", "Reduce" -> False, "WithinContract" -> True,
    "CrossContract" -> False, "DirectSum" -> False|>];
operationSpec["Reduce"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{1, 1}, {1, 1}, False, "Reducing", "Reducer"], <|
    "Broadcast" -> True, "Reduce" -> True, "WithinContract" -> False,
    "CrossContract" -> False, "DirectSum" -> False|>];
operationSpec["Map"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{1, 1}, {1, 1}, False, "TargetBlock", "MapFunction"], <|
    "Broadcast" -> True, "Reduce" -> False, "WithinContract" -> False,
    "CrossContract" -> False, "DirectSum" -> False,
    "TargetDrop" -> True|>];
operationSpec["Operate"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{1, 1}, {1, 1}, False, "ShapePreservingTargetBlock",
    "MapFunction"], <|
    "Broadcast" -> True, "Reduce" -> False, "WithinContract" -> False,
    "CrossContract" -> False, "DirectSum" -> False,
    "TargetDrop" -> False|>];
operationSpec["Dot"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{2, Infinity}, {1, 1}, "CrossPairwise", "Contracting",
    "InnerCombiners"], <|
    "Broadcast" -> True, "Reduce" -> False, "WithinContract" -> False,
    "CrossContract" -> True, "DirectSum" -> False|>];
operationSpec["Inner"] := operationSpec["Dot"];
operationSpec["Join"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{1, Infinity}, {1, 1}, False, "DirectSumJoin", None], <|
    "Broadcast" -> True, "Reduce" -> True, "WithinContract" -> False,
    "CrossContract" -> False, "DirectSum" -> True|>];
operationSpec["Split"] := ira["OperationSpec"] @ Join[
  baseOperationSpec[{1, 1}, {1, Infinity}, False, "DirectSumSplit", None], <|
    "Broadcast" -> True, "Reduce" -> True, "WithinContract" -> False,
    "CrossContract" -> False, "DirectSum" -> True|>];
operationSpec[other_] := ira["FailureRecord"]["UnknownOperatorSpec", "Analysis",
  <|"Operator" -> other|>];

analyzeSolvedDesc[solved : ira["SolvedDesc"][a_Association], operator_, targeting_] :=
  Catch[Module[{normalized, na, inputs, outputs, axisSizes, inRecords, outRecords,
          inputIds, outputIds, carriedIds, droppedIds, broadcastIds, effects = {},
          directSums, units, targetInputs, targetOutputs, spec, policy, violations},
    normalized = a["Normalized"];
    na = Replace[normalized, ira["NormalizedDesc"][x_Association] :> x];
    inputs = Replace[Lookup[a, "Inputs", na["Inputs"]],
      ira["Inputs"][x_List] :> x];
    outputs = Replace[Lookup[a, "Outputs", na["Outputs"]],
      ira["Outputs"][x_List] :> x];
    axisSizes = a["AxisSizes"];
    inRecords = occurrenceRecords[inputs, "Input"];
    outRecords = occurrenceRecords[outputs, "Output"];
    inputIds = DeleteDuplicates @ Cases[inRecords, r_Association :> r["Axis"]];
    outputIds = DeleteDuplicates @ Cases[outRecords, r_Association :> r["Axis"]];
    carriedIds = Intersection[inputIds, outputIds];
    droppedIds = Complement[inputIds, outputIds];
    broadcastIds = Complement[outputIds, inputIds];
    Do[AppendTo[effects, ira["Carried"][id,
      Select[inRecords, # ["Axis"] === id &],
      Select[outRecords, # ["Axis"] === id &]]], {id, carriedIds}];
    Do[AppendTo[effects, classifyDropped[id, inRecords]], {id, droppedIds}];
    Do[AppendTo[effects, ira["Broadcast"][id, axisSizes[id],
      Select[outRecords, # ["Axis"] === id &]]], {id, broadcastIds}];
    (* A kept axis may still have a targeted pair contracted while an untargeted
       occurrence carries the result (Einstoff's within-tensor extension). *)
    If[targeting =!= False,
      Do[
        With[{effect = classifyKeptTargetPair[id, inRecords, outRecords]},
          If[effect =!= None, AppendTo[effects, effect]]],
        {id, carriedIds}]];
    directSums = Join[
      Cases[inputs, d : ira["DirectSumAxis"][___] :> d, Infinity],
      Cases[outputs, d : ira["DirectSumAxis"][___] :> d, Infinity]];
    Do[AppendTo[effects, ira["DirectSumGroup"][d]], {d, directSums}];
    units = Join[
      Cases[inputs, u : ira["LiteralAxis"][_, 1, _] :> u, Infinity],
      Cases[outputs, u : ira["LiteralAxis"][_, 1, _] :> u, Infinity]];
    Do[AppendTo[effects, ira["UnitAxis"][u]], {u, units}];
    targetInputs = Select[inRecords, TrueQ[# ["Targeted"]] &];
    targetOutputs = Select[outRecords, TrueQ[# ["Targeted"]] &];
    If[targetInputs =!= {} || targetOutputs =!= {},
      AppendTo[effects, ira["TargetBlock"][targetInputs, targetOutputs]]];
    spec = operationSpec[operator];
    If[analysisFailureQ[spec], Throw[spec, analysisTag]];
    policy = compileTargetPolicy[targeting];
    If[analysisFailureQ[policy], Throw[policy, analysisTag]];
    violations = Join[
      validateArity[Length[inputs], Length[outputs], spec],
      validateEffects[effects, spec, axisSizes]];
    ira["OperationAnalysis"][<|
      "Solved" -> solved, "Operator" -> operator, "Spec" -> spec,
      "TargetPolicy" -> policy, "Effects" -> ira["Effects"][effects],
      "Violations" -> violations, "Valid" -> (violations === {})
    |>]
  ], analysisTag];

validateArity[inputCount_Integer, outputCount_Integer,
    ira["OperationSpec"][spec_Association]] :=
  Module[{violations = {}, input = spec["InputArity"], output = spec["OutputArity"]},
    If[! arityContainsQ[input, inputCount],
      AppendTo[violations, ira["Violation"]["InputArity", <|
        "Expected" -> input, "Actual" -> inputCount|>]]];
    If[! arityContainsQ[output, outputCount],
      AppendTo[violations, ira["Violation"]["OutputArity", <|
        "Expected" -> output, "Actual" -> outputCount|>]]];
    violations];

arityContainsQ[{min_Integer, Infinity}, n_Integer] := n >= min;
arityContainsQ[{min_Integer, max_Integer}, n_Integer] := min <= n <= max;
analyzeSolvedDesc[other_, operator_, targeting_] :=
  ira["FailureRecord"]["ExpectedSolvedDesc", "Analysis",
    <|"Expression" -> HoldComplete[other], "Operator" -> operator,
      "Targeting" -> targeting|>];

occurrenceRecords[shapes_List, side_String] :=
  Module[{out = {}, occs},
    Do[
      occs = Cases[shapes[[i]],
        node : ira["AxisOccurrence"][occ_, id_, meta_Association] :>
          <|"Axis" -> id, "Occurrence" -> occ, "Tensor" -> i,
            "Side" -> side, "Targeted" -> (meta["TargetHead"] =!= None),
            "TargetHead" -> meta["TargetHead"], "Node" -> node|>,
        Infinity];
      out = Join[out, occs],
      {i, Length[shapes]}];
    out
  ];

classifyDropped[id_, records_] :=
  Module[{occs = Select[records, # ["Axis"] === id &], tensors},
    tensors = DeleteDuplicates[Lookup[occs, "Tensor"]];
    If[Length[occs] === 1,
      ira["Reduced"][id, occs],
      ira["Contracted"][id,
        If[Length[tensors] === 1, "Within", "Cross"], occs]]
  ];

classifyKeptTargetPair[id_, in_, out_] :=
  Module[{ins, targeted, untargetedOut},
    ins = Select[in, # ["Axis"] === id &];
    targeted = Select[ins, TrueQ[# ["Targeted"]] &];
    untargetedOut = Select[out,
      # ["Axis"] === id && ! TrueQ[# ["Targeted"]] &];
    If[Length[targeted] === 2 && untargetedOut =!= {},
      ira["Contracted"][id, "WithinTargetPair", targeted], None]
  ];

validateEffects[effects_List, ira["OperationSpec"][spec_Association], sizes_Association] :=
  Module[{violations = {}, broadcasts, reduced, forbiddenReduced, within, cross,
          sums},
    broadcasts = Cases[effects, b : ira["Broadcast"][___] :> b];
    reduced = Cases[effects, r : ira["Reduced"][___] :> r];
    within = Cases[effects,
      c : ira["Contracted"][_, "Within" | "WithinTargetPair", _] :> c];
    cross = Cases[effects, c : ira["Contracted"][_, "Cross", _] :> c];
    sums = Cases[effects, s : ira["DirectSumGroup"][___] :> s];
    If[spec["Broadcast"] === False && broadcasts =!= {},
      AppendTo[violations, ira["Violation"]["Broadcast", broadcasts]]];
    If[spec["Broadcast"] === "UnitOnly" &&
        AnyTrue[broadcasts, Replace[#, ira["Broadcast"][_, n_, _] :> n > 1] &],
      AppendTo[violations, ira["Violation"]["NonUnitBroadcast", broadcasts]]];
    reduced = Select[reduced, Replace[#,
      ira["Reduced"][id_, _] :> Lookup[sizes, id, 2] > 1] &];
    forbiddenReduced = If[TrueQ[Lookup[spec, "TargetDrop", False]],
      Select[reduced, Replace[#,
        ira["Reduced"][_, records_List] :>
          ! AllTrue[records, TrueQ[Lookup[#, "Targeted", False]] &]] &],
      reduced];
    If[! TrueQ[spec["Reduce"]] && forbiddenReduced =!= {},
      AppendTo[violations, ira["Violation"]["Reduce", forbiddenReduced]]];
    If[! TrueQ[spec["WithinContract"]] && within =!= {},
      AppendTo[violations, ira["Violation"]["WithinContract", within]]];
    If[! TrueQ[spec["CrossContract"]] && cross =!= {},
      AppendTo[violations, ira["Violation"]["CrossContract", cross]]];
    If[! TrueQ[spec["DirectSum"]] && sums =!= {},
      AppendTo[violations, ira["Violation"]["DirectSum", sums]]];
    violations
  ];

analysisFailureQ[expr_] := Head[Unevaluated[expr]] === ira["FailureRecord"];
