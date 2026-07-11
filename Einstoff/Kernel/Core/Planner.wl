(* ::Package:: *)

(* Backend-neutral plans for the structural single-tensor subset.  Both immediate
   execution and held TraceAction rendering interpret the same ExecutionPlan. *)

PackageScoped[{
  planStructuralIR, planReduceIR, executeExecutionPlan, renderExecutionPlan,
  tryStructuralIRPlan, tryReduceIRPlan
}]

irp[name_String] := Symbol["Einstoff`Internal`IR`" <> name];

planStructuralIR[solved : irp["SolvedDesc"][a_Association], operator_] :=
  Catch[Module[{normalized, na, inputs, outputs, axisSizes, inShapes, outShapes,
          inTerms, outTerms, inAtoms, outAtoms, inKeys, outKeys, currentKeys,
          kept, steps = {}, size, key, perm, finalDims, violations,
          broadcastResult},
    normalized = a["Normalized"];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[na["Inputs"], irp["Inputs"][x_List] :> x];
    outShapes = Replace[na["Outputs"], irp["Outputs"][x_List] :> x];
    If[Length[inShapes] =!= 1 || Length[outShapes] =!= 1,
      Throw[plannerFailure["StructuralArity", <|
        "Inputs" -> Length[inShapes], "Outputs" -> Length[outShapes]|>], plannerTag]];
    axisSizes = a["AxisSizes"];
    inTerms = Replace[First[inShapes], irp["Shape"][x_List] :> x];
    outTerms = Replace[First[outShapes], irp["Shape"][x_List] :> x];
    inAtoms = flattenPlanTerms[inTerms, axisSizes];
    outAtoms = flattenPlanTerms[outTerms, axisSizes];
    If[plannerFailureQ[inAtoms], Throw[inAtoms, plannerTag]];
    If[plannerFailureQ[outAtoms], Throw[outAtoms, plannerTag]];
    inKeys = planAtomKey /@ inAtoms;
    outKeys = planAtomKey /@ outAtoms;
    If[! DuplicateFreeQ[inKeys],
      Throw[plannerFailure["RepeatedInputAtom", <|"Keys" -> inKeys|>], plannerTag]];
    If[! DuplicateFreeQ[outKeys],
      Throw[plannerFailure["DuplicateOutputAtom", <|"Keys" -> outKeys|>], plannerTag]];
    (* Named input atoms must be carried.  Anonymous literals may only disappear when
       they are units; a size>1 literal has no carryable identity. *)
    violations = Select[inAtoms,
      With[{k = planAtomKey[#], n = planAtomSize[#]},
        ! MemberQ[outKeys, k] && n > 1] &];
    If[violations =!= {},
      Throw[plannerFailure["DroppedNonUnitAtom", <|"Atoms" -> violations|>], plannerTag]];
    AppendTo[steps, irp["ReshapeStep"][planAtomSize /@ inAtoms]];
    kept = Select[inAtoms,
      MemberQ[outKeys, planAtomKey[#]] || planAtomSize[#] > 1 &];
    If[Length[kept] =!= Length[inAtoms],
      AppendTo[steps, irp["ReshapeStep"][planAtomSize /@ kept]]];
    currentKeys = planAtomKey /@ kept;
    broadcastResult = Catch[
      Do[
        key = planAtomKey[atom]; size = planAtomSize[atom];
        If[! MemberQ[currentKeys, key],
          If[operator =!= "Massage" && size > 1,
            Throw[plannerFailure["NonUnitBroadcast", <|
              "Atom" -> atom, "Size" -> size|>], planBroadcastTag]];
          AppendTo[steps, irp["BroadcastStep"][size, key]];
          currentKeys = Prepend[currentKeys, key]],
        {atom, outAtoms}];
      Null,
      planBroadcastTag];
    If[plannerFailureQ[broadcastResult], Throw[broadcastResult, plannerTag]];
    perm = InversePermutation @ Flatten[FirstPosition[currentKeys, #] & /@ outKeys];
    If[perm =!= Range[Length[perm]],
      AppendTo[steps, irp["TransposeStep"][perm]]];
    finalDims = a["OutputShapes"][[1]];
    (* Keep a final reshape even when dimensions are already atomic: besides making the
       plan canonical, this preserves the public TraceAction contract whose structural
       lowering is headed by ArrayReshape. *)
    AppendTo[steps, irp["RecomposeStep"][finalDims]];
    irp["ExecutionPlan"][steps, <|
      "Operator" -> operator, "InputCount" -> 1,
      "OutputShapes" -> a["OutputShapes"], "Solved" -> solved|>]
  ], plannerTag];
planStructuralIR[other_, operator_] :=
  plannerFailure["ExpectedSolvedDesc", <|
    "Expression" -> HoldComplete[other], "Operator" -> operator|>];

planReduceIR[solved : irp["SolvedDesc"][a_Association], reducer_] :=
  Catch[Module[{normalized, na, inShapes, outShapes, axisSizes, inTerms, outTerms,
          inAtoms, outAtoms, inKeys, outKeys, reducedPos, currentAtoms,
          currentKeys, steps = {}, broadcastResult, key, size, perm, finalDims,
          inputLiterals, outputLiterals},
    normalized = a["Normalized"];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[na["Inputs"], irp["Inputs"][x_List] :> x];
    outShapes = Replace[na["Outputs"], irp["Outputs"][x_List] :> x];
    If[Length[inShapes] =!= 1 || Length[outShapes] =!= 1,
      Throw[plannerFailure["ReduceArity", <|
        "Inputs" -> Length[inShapes], "Outputs" -> Length[outShapes]|>], plannerTag]];
    axisSizes = a["AxisSizes"];
    inTerms = Replace[First[inShapes], irp["Shape"][x_List] :> x];
    outTerms = Replace[First[outShapes], irp["Shape"][x_List] :> x];
    inAtoms = flattenPlanTerms[inTerms, axisSizes];
    outAtoms = flattenPlanTerms[outTerms, axisSizes];
    If[plannerFailureQ[inAtoms], Throw[inAtoms, plannerTag]];
    If[plannerFailureQ[outAtoms], Throw[outAtoms, plannerTag]];
    inKeys = planAtomKey /@ inAtoms; outKeys = planAtomKey /@ outAtoms;
    If[! DuplicateFreeQ[inKeys] || ! DuplicateFreeQ[outKeys],
      Throw[plannerFailure["RepeatedReduceAtom", <|
        "InputKeys" -> inKeys, "OutputKeys" -> outKeys|>], plannerTag]];
    inputLiterals = Cases[inAtoms,
      atom_Association /; atom["Kind"] === "Literal" :> atom["Size"]];
    outputLiterals = Cases[outAtoms,
      atom_Association /; atom["Kind"] === "Literal" :> atom["Size"]];
    If[Intersection[inputLiterals, outputLiterals] =!= {},
      Throw[plannerFailure["KeptLiteralAxis", <|
        "Sizes" -> Intersection[inputLiterals, outputLiterals]|>], plannerTag]];
    reducedPos = Select[Range[Length[inAtoms]],
      ! MemberQ[outKeys, inKeys[[#]]] &];
    AppendTo[steps, irp["ReshapeStep"][planAtomSize /@ inAtoms]];
    If[reducedPos =!= {},
      AppendTo[steps, irp["ReduceStep"][reducer, reducedPos]]];
    currentAtoms = Delete[inAtoms, List /@ reducedPos];
    currentKeys = planAtomKey /@ currentAtoms;
    broadcastResult = Catch[
      Do[
        key = planAtomKey[atom]; size = planAtomSize[atom];
        If[! MemberQ[currentKeys, key],
          AppendTo[steps, irp["BroadcastStep"][size, key]];
          currentKeys = Prepend[currentKeys, key]],
        {atom, outAtoms}];
      Null,
      planBroadcastTag];
    If[plannerFailureQ[broadcastResult], Throw[broadcastResult, plannerTag]];
    perm = InversePermutation @ Flatten[FirstPosition[currentKeys, #] & /@ outKeys];
    If[perm =!= Range[Length[perm]],
      AppendTo[steps, irp["TransposeStep"][perm]]];
    finalDims = a["OutputShapes"][[1]];
    AppendTo[steps, irp["RecomposeStep"][finalDims]];
    irp["ExecutionPlan"][steps, <|
      "Operator" -> "Reduce", "InputCount" -> 1,
      "OutputShapes" -> a["OutputShapes"], "Solved" -> solved|>]
  ], plannerTag];
planReduceIR[other_, reducer_] := plannerFailure["ExpectedSolvedDesc", <|
  "Expression" -> HoldComplete[other], "Reducer" -> HoldComplete[reducer]|>];

flattenPlanTerms[terms_List, sizes_Association] :=
  Catch[Module[{out = {}, r},
    Do[
      r = flattenPlanTerm[term, sizes];
      If[plannerFailureQ[r], Throw[r, plannerTag]];
      out = Join[out, r],
      {term, terms}];
    out
  ], plannerTag];

flattenPlanTerm[irp["AxisOccurrence"][occ_, id_, _], sizes_Association] :=
  {<|"Key" -> id, "Occurrence" -> occ, "Size" -> sizes[id],
    "Kind" -> "Axis"|>};
flattenPlanTerm[irp["LiteralAxis"][occ_, n_Integer, _], _] :=
  {<|"Key" -> {"Literal", occ}, "Occurrence" -> occ, "Size" -> n,
    "Kind" -> "Literal"|>};
flattenPlanTerm[irp["ProductAxis"][_, children_List, _], sizes_Association] :=
  flattenPlanTerms[children, sizes];
flattenPlanTerm[other_, _] := plannerFailure["UnsupportedPlanTerm", <|
  "Expression" -> HoldComplete[other]|>];

planAtomKey[a_Association] := a["Key"];
planAtomSize[a_Association] := a["Size"];

executeExecutionPlan[irp["ExecutionPlan"][steps_List, meta_Association],
    tensors_List] :=
  Catch[Module[{value, step},
    If[Length[tensors] =!= meta["InputCount"],
      Throw[plannerFailure["PlanInputCount", <|
        "Expected" -> meta["InputCount"], "Actual" -> Length[tensors]|>], plannerTag]];
    value = First[tensors];
    Do[
      step = st;
      value = executePlanStep[value, step];
      If[plannerFailureQ[value], Throw[value, plannerTag]],
      {st, steps}];
    value
  ], plannerTag];
executeExecutionPlan[other_, tensors_] := plannerFailure["ExpectedExecutionPlan", <|
  "Expression" -> HoldComplete[other], "Tensors" -> HoldComplete[tensors]|>];

executePlanStep[value_, irp["ReshapeStep"][dims_List]] := reshapeTo[value, dims];
executePlanStep[value_, irp["BroadcastStep"][n_Integer, _]] := ConstantArray[value, n];
executePlanStep[value_, irp["ReduceStep"][reducer_, pos_List]] :=
  ArrayReduce[reducer, value, pos];
executePlanStep[value_, irp["TransposeStep"][perm_List]] := Transpose[value, perm];
executePlanStep[value_, irp["RecomposeStep"][dims_List]] := reshapeTo[value, dims];
executePlanStep[_, other_] := plannerFailure["UnsupportedPlanStep", <|
  "Step" -> HoldComplete[other]|>];

renderExecutionPlan[irp["ExecutionPlan"][steps_List, meta_Association],
    tensors_List] :=
  Catch[Module[{held, step},
    If[Length[tensors] =!= meta["InputCount"],
      Throw[plannerFailure["PlanInputCount", <|
        "Expected" -> meta["InputCount"], "Actual" -> Length[tensors]|>], plannerTag]];
    held = heldValue[First[tensors]];
    Do[
      step = st;
      held = renderPlanStep[held, step];
      If[plannerFailureQ[held], Throw[held, plannerTag]],
      {st, steps}];
    held
  ], plannerTag];
renderExecutionPlan[other_, tensors_] := plannerFailure["ExpectedExecutionPlan", <|
  "Expression" -> HoldComplete[other], "Tensors" -> HoldComplete[tensors]|>];

renderPlanStep[held_HoldComplete, irp["ReshapeStep"][dims_List]] :=
  heldReshape[held, dims];
renderPlanStep[held_HoldComplete, irp["BroadcastStep"][n_Integer, _]] :=
  heldConstantArray[held, n];
renderPlanStep[held_HoldComplete, irp["ReduceStep"][reducer_, pos_List]] :=
  heldArrayReduce[held, reducer, pos];
renderPlanStep[held_HoldComplete, irp["TransposeStep"][perm_List]] :=
  heldTranspose[held, perm];
renderPlanStep[held_HoldComplete, irp["RecomposeStep"][dims_List]] :=
  heldReshape[held, dims];
renderPlanStep[_, other_] := plannerFailure["UnsupportedPlanStep", <|
  "Step" -> HoldComplete[other]|>];

(* Compatibility entrance: Missing means the legacy lowering owns this description.
   It intentionally emits no public message on fallback. *)
tryStructuralIRPlan[h_Hold, tensors_List, bindings_List, operator_String,
    targeting_, traceAction_] :=
  Catch[Module[{compiled, solvedBundle, solved, analysis, plan, held},
    compiled = compileHeldDescIR[h, HoldComplete[bindings], operator,
      <|"Targeting" -> targeting|>];
    If[Head[compiled["Normalized"]] =!= irp["NormalizedDesc"],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    solvedBundle = solveDescIR[compiled, Dimensions /@ tensors];
    solved = solvedBundle["Solved"];
    If[Head[solved] =!= irp["SolvedDesc"],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    analysis = analyzeSolvedDesc[solved, operator, targeting];
    If[Head[analysis] =!= irp["OperationAnalysis"] ||
        ! TrueQ[Replace[analysis, irp["OperationAnalysis"][a_Association] :> a["Valid"]]],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    plan = planStructuralIR[solved, operator];
    If[plannerFailureQ[plan], Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    If[traceActionEnabledQ[traceAction],
      held = renderExecutionPlan[plan, tensors];
      If[plannerFailureQ[held], Missing["UnsupportedIR"],
        traceReturnHeld[held, traceAction]],
      executeExecutionPlan[plan, tensors]]
  ], plannerFallbackTag];

tryReduceIRPlan[h_Hold, tensors_List, bindings_List, reducer_, targeting_,
    traceAction_] :=
  Catch[Module[{compiled, solvedBundle, solved, analysis, plan, held, targetIds, reducedIds},
    compiled = compileHeldDescIR[h, HoldComplete[bindings], "Reduce",
      <|"Targeting" -> targeting|>];
    If[Head[compiled["Normalized"]] =!= irp["NormalizedDesc"],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    solvedBundle = solveDescIR[compiled, Dimensions /@ tensors];
    solved = solvedBundle["Solved"];
    If[Head[solved] =!= irp["SolvedDesc"],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    analysis = analyzeSolvedDesc[solved, "Reduce", targeting];
    If[Head[analysis] =!= irp["OperationAnalysis"] ||
        ! TrueQ[Replace[analysis, irp["OperationAnalysis"][a_Association] :> a["Valid"]]],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    (* A kept target belongs to Map/Operate, not reduction. *)
    targetIds = DeleteDuplicates @ Cases[analysis,
      r_Association /; TrueQ[Lookup[r, "Targeted", False]] :> Lookup[r, "Axis"],
      Infinity];
    reducedIds = DeleteDuplicates @ Cases[analysis,
      irp["Reduced"][id_, _] :> id, Infinity];
    Which[
      targeting === True && Complement[reducedIds, targetIds] =!= {},
        Throw[Missing["UnsupportedIR"], plannerFallbackTag],
      targeting === Automatic && targetIds =!= {} &&
          Sort[reducedIds] =!= Sort[targetIds],
        Throw[Missing["UnsupportedIR"], plannerFallbackTag],
      True, Null];
    plan = planReduceIR[solved, reducer];
    If[plannerFailureQ[plan], Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    If[traceActionEnabledQ[traceAction],
      held = renderExecutionPlan[plan, tensors];
      If[plannerFailureQ[held], Missing["UnsupportedIR"],
        traceReturnHeld[held, traceAction]],
      executeExecutionPlan[plan, tensors]]
  ], plannerFallbackTag];

plannerFailure[tag_, details_Association] :=
  irp["FailureRecord"][tag, "Plan", details];
plannerFailureQ[expr_] := Head[Unevaluated[expr]] === irp["FailureRecord"];
