(* ::Package:: *)

(* Backend-neutral plans for the structural single-tensor subset.  Both immediate
   execution and held TraceAction rendering interpret the same ExecutionPlan. *)

PackageScoped[{
  planStructuralIR, planSelfContractIR, planReduceIR, planMapIR, planInnerIR,
  planDirectSumIR,
  executeExecutionPlan,
  renderExecutionPlan, tryStructuralIRPlan, tryReduceIRPlan, tryMapIRPlan,
  tryInnerIRPlan, tryDirectSumIRPlan, plannerFailureQ
}]

irp[name_String] := Symbol["Einstoff`Internal`IR`" <> name];

planStructuralIR[solved : irp["SolvedDesc"][a_Association], operator_] :=
  Catch[Module[{normalized, na, inputs, outputs, axisSizes, inShapes, outShapes,
          inTerms, outTerms, inAtoms, outAtoms, inKeys, outKeys, currentKeys,
          kept, steps = {}, size, key, perm, finalDims, violations,
          broadcastResult},
    normalized = a["Normalized"];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[Lookup[a, "Inputs", na["Inputs"]],
      irp["Inputs"][x_List] :> x];
    outShapes = Replace[Lookup[a, "Outputs", na["Outputs"]],
      irp["Outputs"][x_List] :> x];
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

planSelfContractIR[solved : irp["SolvedDesc"][a_Association], operator_,
    targeting_] :=
  Catch[Module[{normalized, na, inShapes, outShapes, axisSizes, inTerms,
          outTerms, inAtoms, outAtoms, inKeys, outKeys, uniqueKeys,
          anyTargeted, groups = {}, positions, targetedPositions, currentAtoms,
          tailSteps},
    normalized = a["Normalized"];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[Lookup[a, "Inputs", na["Inputs"]],
      irp["Inputs"][x_List] :> x];
    outShapes = Replace[Lookup[a, "Outputs", na["Outputs"]],
      irp["Outputs"][x_List] :> x];
    If[Length[inShapes] =!= 1 || Length[outShapes] =!= 1,
      Throw[plannerFailure["SelfContractArity", <|
        "Inputs" -> Length[inShapes], "Outputs" -> Length[outShapes]|>], plannerTag]];
    axisSizes = a["AxisSizes"];
    inTerms = Replace[First[inShapes], irp["Shape"][x_List] :> x];
    outTerms = Replace[First[outShapes], irp["Shape"][x_List] :> x];
    inAtoms = flattenPlanTerms[inTerms, axisSizes];
    outAtoms = flattenPlanTerms[outTerms, axisSizes];
    If[plannerFailureQ[inAtoms] || plannerFailureQ[outAtoms],
      Throw[plannerFailure["UnsupportedSelfContractTerm", <||>], plannerTag]];
    inKeys = planAtomKey /@ inAtoms; outKeys = planAtomKey /@ outAtoms;
    If[! DuplicateFreeQ[outKeys],
      Throw[plannerFailure["RepeatedSelfContractOutput", <||>], plannerTag]];
    uniqueKeys = DeleteDuplicates[inKeys];
    anyTargeted = AnyTrue[inAtoms, TrueQ[Lookup[#, "Targeted", False]] &];
    Do[
      positions = Flatten @ Position[inKeys, key];
      targetedPositions = Select[positions,
        TrueQ[Lookup[inAtoms[[#]], "Targeted", False]] &];
      Switch[Length[positions],
        1,
          Null,
        2,
          If[MemberQ[outKeys, key],
            Throw[plannerFailure["KeptDiagonal", <|"Axis" -> key|>], plannerTag]];
          If[targeting === True && Length[targetedPositions] =!= 2,
            Throw[plannerFailure["SelfContractTargetsRequired", <|
              "Axis" -> key|>], plannerTag]];
          If[targeting === Automatic && anyTargeted &&
              Length[targetedPositions] =!= 2,
            Throw[plannerFailure["SelfContractTargetMismatch", <|
              "Axis" -> key|>], plannerTag]];
          AppendTo[groups, positions],
        3,
          If[targeting === False || ! MemberQ[outKeys, key] ||
              Length[targetedPositions] =!= 2,
            Throw[plannerFailure["UnsupportedKeptCarrier", <|
              "Axis" -> key|>], plannerTag]];
          AppendTo[groups, targetedPositions],
        _,
          Throw[plannerFailure["SuperDiagonal", <|
            "Axis" -> key, "Count" -> Length[positions]|>], plannerTag]],
      {key, uniqueKeys}];
    If[groups === {},
      Throw[plannerFailure["NoSelfContraction", <||>], plannerTag]];
    currentAtoms = Delete[inAtoms, List /@ Sort[Flatten[groups]]];
    tailSteps = planAtomTransformSteps[currentAtoms, outAtoms,
      a["OutputShapes"][[1]], operator === "Massage"];
    If[plannerFailureQ[tailSteps], Throw[tailSteps, plannerTag]];
    irp["ExecutionPlan"][Join[
      {irp["ReshapeStep"][planAtomSize /@ inAtoms],
       irp["ContractStep"][groups]},
      tailSteps], <|
        "Operator" -> operator, "InputCount" -> 1,
        "OutputShapes" -> a["OutputShapes"], "Solved" -> solved|>]
  ], plannerTag];
planSelfContractIR[other_, operator_, targeting_] := plannerFailure[
  "ExpectedSolvedDesc", <|"Expression" -> HoldComplete[other],
    "Operator" -> operator, "Targeting" -> targeting|>];

planReduceIR[solved : irp["SolvedDesc"][a_Association], reducer_] :=
  Catch[Module[{normalized, na, inShapes, outShapes, axisSizes, inTerms, outTerms,
          inAtoms, outAtoms, inKeys, outKeys, reducedPos, currentAtoms,
          currentKeys, steps = {}, broadcastResult, key, size, perm, finalDims,
          inputLiterals, outputLiterals},
    normalized = a["Normalized"];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[Lookup[a, "Inputs", na["Inputs"]],
      irp["Inputs"][x_List] :> x];
    outShapes = Replace[Lookup[a, "Outputs", na["Outputs"]],
      irp["Outputs"][x_List] :> x];
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

planMapIR[solved : irp["SolvedDesc"][a_Association], f_, strictQ_] :=
  Catch[Module[{normalized, na, inShapes, outShapes, axisSizes, inTerms, outTerms,
          inAtoms, outAtoms, inKeys, outKeys, targetAtoms, vmapAtoms, currentAtoms,
          currentKeys, order, perm, steps = {}, dropped, broadcastResult, key, size},
    normalized = a["Normalized"];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[Lookup[a, "Inputs", na["Inputs"]],
      irp["Inputs"][x_List] :> x];
    outShapes = Replace[Lookup[a, "Outputs", na["Outputs"]],
      irp["Outputs"][x_List] :> x];
    If[Length[inShapes] =!= 1 || Length[outShapes] =!= 1,
      Throw[plannerFailure["MapArity", <|
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
      Throw[plannerFailure["RepeatedMapAtom", <|
        "InputKeys" -> inKeys, "OutputKeys" -> outKeys|>], plannerTag]];
    targetAtoms = Select[inAtoms, TrueQ[Lookup[#, "Targeted", False]] &];
    vmapAtoms = Select[inAtoms, ! TrueQ[Lookup[#, "Targeted", False]] &];
    If[TrueQ[strictQ] && targetAtoms === {},
      Throw[plannerFailure["TargetRequired", <||>], plannerTag]];
    (* The first map-plan increment owns only statically shape-preserving blocks.
       Shape-changing target blocks remain on the compatibility path until the
       declarative RHS projection IR can name their produced dimensions. *)
    dropped = Select[inAtoms,
      ! MemberQ[outKeys, planAtomKey[#]] && planAtomSize[#] > 1 &];
    If[dropped =!= {} ||
        AnyTrue[targetAtoms, ! MemberQ[outKeys, planAtomKey[#]] &] ||
        (targetAtoms === {} && Complement[outKeys, inKeys] =!= {}),
      Throw[plannerFailure["ShapeChangingMap", <|"Dropped" -> dropped|>], plannerTag]];
    AppendTo[steps, irp["ReshapeStep"][planAtomSize /@ inAtoms]];
    order = Join[vmapAtoms, targetAtoms];
    perm = Flatten[FirstPosition[inKeys, planAtomKey[#]] & /@ order];
    If[Length[perm] > 1 && perm =!= Range[Length[perm]],
      AppendTo[steps, irp["TransposeStep"][InversePermutation[perm]]]];
    AppendTo[steps, irp["TargetBlockStep"][f, Length[vmapAtoms],
      Join[planAtomSize /@ vmapAtoms, planAtomSize /@ targetAtoms]]];
    currentAtoms = Select[order,
      MemberQ[outKeys, planAtomKey[#]] || planAtomSize[#] > 1 &];
    If[Length[currentAtoms] =!= Length[order],
      AppendTo[steps, irp["ReshapeStep"][planAtomSize /@ currentAtoms]]];
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
    AppendTo[steps, irp["RecomposeStep"][a["OutputShapes"][[1]]]];
    irp["ExecutionPlan"][steps, <|
      "Operator" -> If[TrueQ[strictQ], "Operate", "Map"],
      "InputCount" -> 1, "OutputShapes" -> a["OutputShapes"],
      "Solved" -> solved|>]
  ], plannerTag];
planMapIR[other_, f_, strictQ_] := plannerFailure["ExpectedSolvedDesc", <|
  "Expression" -> HoldComplete[other], "Function" -> HoldComplete[f],
  "Strict" -> strictQ|>];

planInnerIR[solved : irp["SolvedDesc"][a_Association], mul_, add_, targeting_] :=
  Catch[Module[{normalized, na, inShapes, outShapes, axisSizes, inputAtoms,
          outputAtoms, inputKeys, outputKeys, allInputKeys, contractedKeys,
          targetedOccurrences, contractedOccurrences, currentKeys,
          steps = {}, broadcastResult, key, size, perm},
    normalized = a["Normalized"];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[Lookup[a, "Inputs", na["Inputs"]],
      irp["Inputs"][x_List] :> x];
    outShapes = Replace[Lookup[a, "Outputs", na["Outputs"]],
      irp["Outputs"][x_List] :> x];
    If[Length[inShapes] < 2 || Length[outShapes] =!= 1,
      Throw[plannerFailure["InnerArity", <|
        "Inputs" -> Length[inShapes], "Outputs" -> Length[outShapes]|>], plannerTag]];
    axisSizes = a["AxisSizes"];
    inputAtoms = Map[
      flattenPlanTerms[Replace[#, irp["Shape"][x_List] :> x], axisSizes] &,
      inShapes];
    outputAtoms = flattenPlanTerms[
      Replace[First[outShapes], irp["Shape"][x_List] :> x], axisSizes];
    If[AnyTrue[inputAtoms, plannerFailureQ] || plannerFailureQ[outputAtoms],
      Throw[plannerFailure["UnsupportedInnerTerm", <||>], plannerTag]];
    If[Cases[Join[Flatten[inputAtoms], outputAtoms],
        atom_Association /; atom["Kind"] =!= "Axis"] =!= {},
      Throw[plannerFailure["InnerLiteralAxis", <||>], plannerTag]];
    inputKeys = (planAtomKey /@ #) & /@ inputAtoms;
    outputKeys = planAtomKey /@ outputAtoms;
    If[AnyTrue[inputKeys, ! DuplicateFreeQ[#] &] || ! DuplicateFreeQ[outputKeys],
      Throw[plannerFailure["RepeatedInnerAtom", <|
        "Inputs" -> inputKeys, "Output" -> outputKeys|>], plannerTag]];
    allInputKeys = DeleteDuplicates @ Flatten[inputKeys];
    contractedKeys = Select[allInputKeys, ! MemberQ[outputKeys, #] &];
    If[AnyTrue[contractedKeys,
        Function[id, Count[inputKeys, keys_ /; MemberQ[keys, id]] =!= 2]],
      Throw[plannerFailure["InvalidContractionMultiplicity", <|
        "Contracted" -> contractedKeys|>], plannerTag]];
    targetedOccurrences = Sort @ Cases[Flatten[inputAtoms],
      atom_Association /; TrueQ[atom["Targeted"]] :> atom["Occurrence"]];
    contractedOccurrences = Sort @ Cases[Flatten[inputAtoms],
      atom_Association /; MemberQ[contractedKeys, atom["Key"]] :>
        atom["Occurrence"]];
    Which[
      targeting === True && targetedOccurrences =!= contractedOccurrences,
        Throw[plannerFailure["InnerTargetsRequired", <||>], plannerTag],
      targeting === Automatic && targetedOccurrences =!= {} &&
          targetedOccurrences =!= contractedOccurrences,
        Throw[plannerFailure["InnerTargetMismatch", <||>], plannerTag],
      ! MemberQ[{False, Automatic, True}, targeting],
        Throw[plannerFailure["InvalidTargetPolicy", <|"Value" -> targeting|>], plannerTag],
      True, Null];
    currentKeys = contractionFoldLabels[inputKeys, outputKeys];
    If[plannerFailureQ[currentKeys], Throw[currentKeys, plannerTag]];
    AppendTo[steps,
      irp["InnerStep"][mul, add, inputKeys, outputKeys, axisSizes]];
    broadcastResult = Catch[
      Do[
        key = planAtomKey[atom]; size = planAtomSize[atom];
        If[! MemberQ[currentKeys, key],
          AppendTo[steps, irp["BroadcastStep"][size, key]];
          currentKeys = Prepend[currentKeys, key]],
        {atom, outputAtoms}];
      Null,
      planBroadcastTag];
    If[plannerFailureQ[broadcastResult], Throw[broadcastResult, plannerTag]];
    perm = InversePermutation @ Flatten[FirstPosition[currentKeys, #] & /@ outputKeys];
    If[perm =!= Range[Length[perm]],
      AppendTo[steps, irp["TransposeStep"][perm]]];
    AppendTo[steps, irp["RecomposeStep"][a["OutputShapes"][[1]]]];
    irp["ExecutionPlan"][steps, <|
      "Operator" -> If[mul === Times && add === Plus, "Dot", "Inner"],
      "InputCount" -> Length[inputKeys], "OutputShapes" -> a["OutputShapes"],
      "Solved" -> solved|>]
  ], plannerTag];
planInnerIR[other_, mul_, add_, targeting_] := plannerFailure[
  "ExpectedSolvedDesc", <|"Expression" -> HoldComplete[other],
    "Multiply" -> HoldComplete[mul], "Add" -> HoldComplete[add],
    "Targeting" -> targeting|>];

planDirectSumIR[solved : irp["SolvedDesc"][a_Association], direction_String] :=
  Catch[Module[{normalized, na, inShapes, outShapes, axisSizes, plan},
    normalized = a["Normalized"];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[Lookup[a, "Inputs", na["Inputs"]],
      irp["Inputs"][x_List] :> x];
    outShapes = Replace[Lookup[a, "Outputs", na["Outputs"]],
      irp["Outputs"][x_List] :> x];
    axisSizes = a["AxisSizes"];
    plan = Switch[direction,
      "Join", planDirectSumJoin[solved, inShapes, outShapes, axisSizes],
      "Split", planDirectSumSplit[solved, inShapes, outShapes, axisSizes],
      _, plannerFailure["UnknownDirectSumDirection", <|
        "Direction" -> direction|>]];
    If[plannerFailureQ[plan], Throw[plan, plannerTag]];
    plan
  ], plannerTag];
planDirectSumIR[other_, direction_String] := plannerFailure[
  "ExpectedSolvedDesc", <|"Expression" -> HoldComplete[other],
    "Direction" -> direction|>];

planDirectSumJoin[solved_, inShapes_List, outShapes_List, sizes_Association] :=
  Catch[Module[{outTerms, sumPositions, sums, counts, combinations, blockPlans,
          replacement, targetTerms, inputTerms, inputAtoms, targetAtoms, finalDims,
          steps, k},
    If[Length[outShapes] =!= 1,
      Throw[plannerFailure["JoinOutputArity", <|
        "Outputs" -> Length[outShapes]|>], plannerTag]];
    outTerms = Replace[First[outShapes], irp["Shape"][x_List] :> x];
    sumPositions = Flatten @ Position[outTerms, _?(Head[#] === irp["DirectSumAxis"] &), {1}];
    If[sumPositions === {} ||
        Cases[Delete[outTerms, List /@ sumPositions],
          _?(Head[#] === irp["DirectSumAxis"] &), Infinity] =!= {},
      Throw[plannerFailure["UnsupportedJoinSumPlacement", <||>], plannerTag]];
    sums = outTerms[[sumPositions]];
    If[AnyTrue[sums, ! planDirectSumUntargetedQ[#] &],
      Throw[plannerFailure["TargetedDirectSum", <||>], plannerTag]];
    counts = Length /@ (Replace[#, irp["DirectSumAxis"][_, xs_List, _] :> xs] & /@ sums);
    combinations = Tuples[Range /@ counts];
    k = Length[combinations];
    If[Length[inShapes] =!= k,
      Throw[plannerFailure["JoinInputArity", <|
        "Expected" -> k, "Actual" -> Length[inShapes]|>], plannerTag]];
    blockPlans = Table[
      replacement = Table[
        sumPositions[[j]] -> Replace[sums[[j]],
          irp["DirectSumAxis"][_, xs_List, _] :> xs[[combinations[[i, j]]]]],
        {j, Length[sumPositions]}];
      targetTerms = ReplacePart[outTerms, replacement];
      inputTerms = Replace[inShapes[[i]], irp["Shape"][x_List] :> x];
      inputAtoms = flattenPlanTerms[inputTerms, sizes];
      targetAtoms = flattenPlanTerms[targetTerms, sizes];
      If[plannerFailureQ[inputAtoms] || plannerFailureQ[targetAtoms],
        Throw[plannerFailure["UnsupportedJoinBlock", <|"Block" -> i|>], plannerTag]];
      finalDims = planTermSize[#, sizes] & /@ targetTerms;
      If[AnyTrue[finalDims, plannerFailureQ],
        Throw[First @ Select[finalDims, plannerFailureQ], plannerTag]];
      steps = planAtomTransformSteps[inputAtoms, targetAtoms, finalDims, True];
      If[plannerFailureQ[steps], Throw[steps, plannerTag]];
      irp["ExecutionPlan"][steps, <|
        "Operator" -> "JoinBlock", "InputCount" -> 1,
        "OutputShapes" -> {finalDims}|>],
      {i, k}];
    irp["ExecutionPlan"][
      {irp["ConcatenateStep"][sumPositions, counts, blockPlans]},
      <|"Operator" -> "Join", "InputCount" -> k,
        "OutputShapes" -> Replace[solved,
          irp["SolvedDesc"][sa_Association] :> sa["OutputShapes"]],
        "Solved" -> solved|>]
  ], plannerTag];

planDirectSumSplit[solved_, inShapes_List, outShapes_List, sizes_Association] :=
  Catch[Module[{inTerms, sumPositions, sums, summandLists, counts, combinations,
          k, sumSizes, ends, starts, specs, blockPlans, replacement, blockTerms,
          blockAtoms, outputTerms, outputAtoms, finalDims, steps, rank},
    If[Length[inShapes] =!= 1,
      Throw[plannerFailure["SplitInputArity", <|
        "Inputs" -> Length[inShapes]|>], plannerTag]];
    inTerms = Replace[First[inShapes], irp["Shape"][x_List] :> x];
    sumPositions = Flatten @ Position[inTerms, _?(Head[#] === irp["DirectSumAxis"] &), {1}];
    If[sumPositions === {} ||
        Cases[Delete[inTerms, List /@ sumPositions],
          _?(Head[#] === irp["DirectSumAxis"] &), Infinity] =!= {},
      Throw[plannerFailure["UnsupportedSplitSumPlacement", <||>], plannerTag]];
    sums = inTerms[[sumPositions]];
    If[AnyTrue[sums, ! planDirectSumUntargetedQ[#] &],
      Throw[plannerFailure["TargetedDirectSum", <||>], plannerTag]];
    summandLists = Replace[#, irp["DirectSumAxis"][_, xs_List, _] :> xs] & /@ sums;
    counts = Length /@ summandLists;
    combinations = Tuples[Range /@ counts];
    k = Length[combinations];
    If[Length[outShapes] =!= k,
      Throw[plannerFailure["SplitOutputArity", <|
        "Expected" -> k, "Actual" -> Length[outShapes]|>], plannerTag]];
    sumSizes = Map[planTermSize[#, sizes] &, summandLists, {2}];
    If[AnyTrue[Flatten[sumSizes], plannerFailureQ],
      Throw[First @ Select[Flatten[sumSizes], plannerFailureQ], plannerTag]];
    ends = Accumulate /@ sumSizes;
    starts = (Most[Accumulate[Prepend[#, 1]]] &) /@ sumSizes;
    rank = Length[inTerms];
    specs = Table[
      Table[
        With[{at = FirstPosition[sumPositions, d, Missing["NotSum"]]},
          If[MissingQ[at], All,
            {starts[[at[[1]], combinations[[i, at[[1]]]]]],
             ends[[at[[1]], combinations[[i, at[[1]]]]]]}]],
        {d, rank}],
      {i, k}];
    blockPlans = Table[
      replacement = Table[
        sumPositions[[j]] -> summandLists[[j, combinations[[i, j]]]],
        {j, Length[sumPositions]}];
      blockTerms = ReplacePart[inTerms, replacement];
      outputTerms = Replace[outShapes[[i]], irp["Shape"][x_List] :> x];
      blockAtoms = flattenPlanTerms[blockTerms, sizes];
      outputAtoms = flattenPlanTerms[outputTerms, sizes];
      If[plannerFailureQ[blockAtoms] || plannerFailureQ[outputAtoms],
        Throw[plannerFailure["UnsupportedSplitBlock", <|"Block" -> i|>], plannerTag]];
      finalDims = Replace[solved,
        irp["SolvedDesc"][sa_Association] :> sa["OutputShapes"][[i]]];
      steps = planAtomTransformSteps[blockAtoms, outputAtoms, finalDims, True];
      If[plannerFailureQ[steps], Throw[steps, plannerTag]];
      irp["ExecutionPlan"][steps, <|
        "Operator" -> "SplitBlock", "InputCount" -> 1,
        "OutputShapes" -> {finalDims}|>],
      {i, k}];
    irp["ExecutionPlan"][
      {irp["SliceStep"][specs, blockPlans], irp["AssembleOutputsStep"]},
      <|"Operator" -> "Split", "InputCount" -> 1,
        "OutputShapes" -> Replace[solved,
          irp["SolvedDesc"][sa_Association] :> sa["OutputShapes"]],
        "Solved" -> solved|>]
  ], plannerTag];

planAtomTransformSteps[inAtoms_List, outAtoms_List, finalDims_List,
    allowBroadcast_] :=
  Catch[Module[{inKeys, outKeys, violations, kept, currentKeys, steps = {},
          key, size, perm},
    inKeys = planAtomKey /@ inAtoms; outKeys = planAtomKey /@ outAtoms;
    If[! DuplicateFreeQ[inKeys] || ! DuplicateFreeQ[outKeys],
      Throw[plannerFailure["RepeatedBlockAtom", <||>], plannerTag]];
    violations = Select[inAtoms,
      ! MemberQ[outKeys, planAtomKey[#]] && planAtomSize[#] > 1 &];
    If[violations =!= {},
      Throw[plannerFailure["DroppedBlockAtom", <|"Atoms" -> violations|>], plannerTag]];
    AppendTo[steps, irp["ReshapeStep"][planAtomSize /@ inAtoms]];
    kept = Select[inAtoms,
      MemberQ[outKeys, planAtomKey[#]] || planAtomSize[#] > 1 &];
    If[Length[kept] =!= Length[inAtoms],
      AppendTo[steps, irp["ReshapeStep"][planAtomSize /@ kept]]];
    currentKeys = planAtomKey /@ kept;
    Do[
      key = planAtomKey[atom]; size = planAtomSize[atom];
      If[! MemberQ[currentKeys, key],
        If[! TrueQ[allowBroadcast] && size > 1,
          Throw[plannerFailure["BlockBroadcast", <|"Atom" -> atom|>], plannerTag]];
        AppendTo[steps, irp["BroadcastStep"][size, key]];
        currentKeys = Prepend[currentKeys, key]],
      {atom, outAtoms}];
    perm = InversePermutation @ Flatten[FirstPosition[currentKeys, #] & /@ outKeys];
    If[perm =!= Range[Length[perm]],
      AppendTo[steps, irp["TransposeStep"][perm]]];
    AppendTo[steps, irp["RecomposeStep"][finalDims]];
    steps
  ], plannerTag];

planTermSize[irp["AxisOccurrence"][_, id_, _], sizes_Association] := sizes[id];
planTermSize[irp["LiteralAxis"][_, n_Integer, _], _] := n;
planTermSize[irp["ProductAxis"][_, children_List, _], sizes_Association] :=
  Times @@ (planTermSize[#, sizes] & /@ children);
planTermSize[irp["DirectSumAxis"][_, children_List, _], sizes_Association] :=
  Plus @@ (planTermSize[#, sizes] & /@ children);
planTermSize[other_, _] := plannerFailure["UnsupportedPlanSizeTerm", <|
  "Expression" -> HoldComplete[other]|>];

planDirectSumUntargetedQ[
    irp["AxisOccurrence"][_, _, meta_Association]] := meta["TargetHead"] === None;
planDirectSumUntargetedQ[
    irp["LiteralAxis"][_, _, meta_Association]] := meta["TargetHead"] === None;
planDirectSumUntargetedQ[
    (irp["ProductAxis"] | irp["DirectSumAxis"])[_, children_List,
      meta_Association]] :=
  meta["TargetHead"] === None && AllTrue[children, planDirectSumUntargetedQ];
planDirectSumUntargetedQ[_] := False;

contractionFoldLabels[inputKeys_List, outputKeys_List] :=
  Catch[Fold[
    Function[{acc, i},
      Module[{next = inputKeys[[i]], keep, both, batch, left, right},
        keep = Union[outputKeys,
          If[i < Length[inputKeys], Flatten[inputKeys[[i + 1 ;;]]], {}]];
        If[AnyTrue[acc, ! MemberQ[next, #] && ! MemberQ[keep, #] &] ||
            AnyTrue[next, ! MemberQ[acc, #] && ! MemberQ[keep, #] &],
          Throw[plannerFailure["WithinOperandDrop", <|"Operand" -> i|>],
            plannerTag]];
        both = Intersection[acc, next];
        batch = Select[acc, MemberQ[both, #] && MemberQ[keep, #] &];
        left = Select[acc, ! MemberQ[next, #] && MemberQ[keep, #] &];
        right = Select[next, ! MemberQ[acc, #] && MemberQ[keep, #] &];
        Join[batch, left, right]
      ]],
    First[inputKeys], Range[2, Length[inputKeys]]],
  plannerTag];

flattenPlanTerms[terms_List, sizes_Association] :=
  Catch[Module[{out = {}, r},
    Do[
      r = flattenPlanTerm[term, sizes];
      If[plannerFailureQ[r], Throw[r, plannerTag]];
      out = Join[out, r],
      {term, terms}];
    out
  ], plannerTag];

flattenPlanTerm[irp["AxisOccurrence"][occ_, id_, meta_Association], sizes_Association] :=
  {<|"Key" -> id, "Occurrence" -> occ, "Size" -> sizes[id],
    "Kind" -> "Axis", "Targeted" -> (meta["TargetHead"] =!= None),
    "TargetHead" -> meta["TargetHead"]|>};
flattenPlanTerm[irp["LiteralAxis"][occ_, n_Integer, meta_Association], _] :=
  {<|"Key" -> {"Literal", occ}, "Occurrence" -> occ, "Size" -> n,
    "Kind" -> "Literal", "Targeted" -> (meta["TargetHead"] =!= None),
    "TargetHead" -> meta["TargetHead"]|>};
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
    value = If[meta["InputCount"] === 1, First[tensors], tensors];
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
executePlanStep[value_, irp["ContractStep"][groups_List]] :=
  TensorContract[value, groups];
executePlanStep[value_, irp["TargetBlockStep"][f_, level_Integer, expected_List]] :=
  Module[{mapped = If[level === 0, f[value], Map[f, value, {level}]]},
    If[Dimensions[mapped] === expected, mapped,
      plannerFailure["TargetBlockShape", <|
        "Expected" -> expected, "Actual" -> Dimensions[mapped]|>]]
  ];
executePlanStep[tensors_List,
    irp["InnerStep"][mul_, add_, labels_List, outputKeys_List,
      sizes_Association]] :=
  executeContractionFold[tensors, labels, outputKeys, sizes, mul, add];
executePlanStep[tensors_List,
    irp["ConcatenateStep"][axes_List, counts_List, plans_List]] :=
  Module[{blocks},
    blocks = MapThread[executeNestedPlan, {plans, tensors}];
    If[AnyTrue[blocks, plannerFailureQ],
      First @ Select[blocks, plannerFailureQ],
      plannerJoinBlocks[blocks, axes, counts]]
  ];
executePlanStep[value_, irp["SliceStep"][specs_List, plans_List]] :=
  MapThread[
    executeNestedPlan[#1, Take[value, Sequence @@ #2]] &,
    {plans, specs}];
executePlanStep[values_List, irp["AssembleOutputsStep"]] := values;
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
    held = If[meta["InputCount"] === 1, heldValue[First[tensors]],
      heldValue /@ tensors];
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
renderPlanStep[HoldComplete[value_], irp["ContractStep"][groups_List]] :=
  With[{g = groups}, HoldComplete[TensorContract[value, g]]];
renderPlanStep[held_HoldComplete,
    irp["TargetBlockStep"][f_, level_Integer, _List]] :=
  If[level === 0, heldApply[held, f], heldMapAt[held, f, level]];
renderPlanStep[helds_List,
    irp["InnerStep"][mul_, add_, labels_List, outputKeys_List,
      sizes_Association]] :=
  renderContractionFold[helds, labels, outputKeys, sizes, mul, add];
renderPlanStep[helds_List,
    irp["ConcatenateStep"][axes_List, counts_List, plans_List]] :=
  Module[{blocks = MapThread[renderNestedPlan, {plans, helds}]},
    If[AnyTrue[blocks, plannerFailureQ],
      First @ Select[blocks, plannerFailureQ],
      plannerJoinHeldBlocks[blocks, axes, counts]]
  ];
renderPlanStep[held_HoldComplete,
    irp["SliceStep"][specs_List, plans_List]] :=
  MapThread[renderNestedPlan[#1, heldTake[held, #2]] &, {plans, specs}];
renderPlanStep[helds_List, irp["AssembleOutputsStep"]] := heldList[helds];
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
  Catch[Module[{compiled, solvedBundle, solved, analysis, plan, held,
          normalized, na, inShapes, axisSizes, inAtoms, inKeys},
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
    normalized = Replace[solved,
      irp["SolvedDesc"][sa_Association] :> sa["Normalized"]];
    na = Replace[normalized, irp["NormalizedDesc"][x_Association] :> x];
    inShapes = Replace[solved,
      irp["SolvedDesc"][sa_Association] :>
        Replace[Lookup[sa, "Inputs", na["Inputs"]],
          irp["Inputs"][x_List] :> x]];
    axisSizes = Replace[solved,
      irp["SolvedDesc"][sa_Association] :> sa["AxisSizes"]];
    inAtoms = If[Length[inShapes] === 1,
      flattenPlanTerms[
        Replace[First[inShapes], irp["Shape"][x_List] :> x], axisSizes],
      plannerFailure["StructuralArity", <||>]];
    inKeys = If[plannerFailureQ[inAtoms], {}, planAtomKey /@ inAtoms];
    plan = If[inKeys =!= {} && ! DuplicateFreeQ[inKeys],
      planSelfContractIR[solved, operator, targeting],
      planStructuralIR[solved, operator]];
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
    If[Cases[solved,
        irp["SequenceMemberId"][irp["OccurrenceId"][_Integer], _Integer],
        Infinity] =!= {},
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

tryMapIRPlan[h_Hold, tensors_List, bindings_List, f_, strictQ_, traceAction_] :=
  Catch[Module[{operator, compiled, solvedBundle, solved, analysis, plan,
          executed, held},
    operator = If[TrueQ[strictQ], "Operate", "Map"];
    compiled = compileHeldDescIR[h, HoldComplete[bindings], operator, <||>];
    If[Head[compiled["Normalized"]] =!= irp["NormalizedDesc"],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    solvedBundle = solveDescIR[compiled, Dimensions /@ tensors];
    solved = solvedBundle["Solved"];
    If[Head[solved] =!= irp["SolvedDesc"],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    analysis = analyzeSolvedDesc[solved, operator, Automatic];
    If[Head[analysis] =!= irp["OperationAnalysis"] ||
        ! TrueQ[Replace[analysis,
          irp["OperationAnalysis"][a_Association] :> a["Valid"]]],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    plan = planMapIR[solved, f, strictQ];
    If[plannerFailureQ[plan], Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    executed = executeExecutionPlan[plan, tensors];
    If[plannerFailureQ[executed], executed,
      If[traceActionEnabledQ[traceAction],
        held = renderExecutionPlan[plan, tensors];
        If[plannerFailureQ[held], held, traceReturnHeld[held, traceAction]],
        executed]]
  ], plannerFallbackTag];

tryInnerIRPlan[h_Hold, tensors_List, bindings_List, mul_, add_, targeting_,
    traceAction_] :=
  Catch[Module[{operator, compiled, solvedBundle, solved, analysis, plan, held},
    operator = If[mul === Times && add === Plus, "Dot", "Inner"];
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
        ! TrueQ[Replace[analysis,
          irp["OperationAnalysis"][a_Association] :> a["Valid"]]],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    plan = planInnerIR[solved, mul, add, targeting];
    If[plannerFailureQ[plan], Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    If[traceActionEnabledQ[traceAction],
      held = renderExecutionPlan[plan, tensors];
      If[plannerFailureQ[held], held, traceReturnHeld[held, traceAction]],
      executeExecutionPlan[plan, tensors]]
  ], plannerFallbackTag];

tryDirectSumIRPlan[h_Hold, tensors_List, bindings_List, direction_String,
    traceAction_] :=
  Catch[Module[{compiled, solvedBundle, solved, analysis, plan, held},
    compiled = compileHeldDescIR[h, HoldComplete[bindings], direction, <||>];
    If[Head[compiled["Normalized"]] =!= irp["NormalizedDesc"],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    solvedBundle = solveDescIR[compiled, Dimensions /@ tensors];
    solved = solvedBundle["Solved"];
    If[Head[solved] =!= irp["SolvedDesc"],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    analysis = analyzeSolvedDesc[solved, direction, Automatic];
    If[Head[analysis] =!= irp["OperationAnalysis"] ||
        ! TrueQ[Replace[analysis,
          irp["OperationAnalysis"][a_Association] :> a["Valid"]]],
      Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    plan = planDirectSumIR[solved, direction];
    If[plannerFailureQ[plan], Throw[Missing["UnsupportedIR"], plannerFallbackTag]];
    If[traceActionEnabledQ[traceAction],
      held = renderExecutionPlan[plan, tensors];
      If[plannerFailureQ[held], held, traceReturnHeld[held, traceAction]],
      executeExecutionPlan[plan, tensors]]
  ], plannerFallbackTag];

executeNestedPlan[irp["ExecutionPlan"][steps_List, _Association], value_] :=
  Catch[Fold[
    Function[{current, step},
      Module[{next = executePlanStep[current, step]},
        If[plannerFailureQ[next], Throw[next, plannerTag], next]]],
    value, steps], plannerTag];

renderNestedPlan[irp["ExecutionPlan"][steps_List, _Association],
    held_HoldComplete] :=
  Catch[Fold[
    Function[{current, step},
      Module[{next = renderPlanStep[current, step]},
        If[plannerFailureQ[next], Throw[next, plannerTag], next]]],
    held, steps], plannerTag];

plannerJoinBlocks[blocks_List, axes_List, counts_List] :=
  If[axes === {}, First[blocks],
    Module[{chunk = Times @@ Rest[counts], grouped, joined},
      grouped = Partition[blocks, chunk];
      joined = plannerJoinBlocks[#, Rest[axes], Rest[counts]] & /@ grouped;
      Join[Sequence @@ joined, First[axes]]
    ]];

plannerJoinHeldBlocks[blocks_List, axes_List, counts_List] :=
  If[axes === {}, First[blocks],
    Module[{chunk = Times @@ Rest[counts], grouped, joined},
      grouped = Partition[blocks, chunk];
      joined = plannerJoinHeldBlocks[#, Rest[axes], Rest[counts]] & /@ grouped;
      heldJoin[joined, First[axes]]
    ]];

executeContractionFold[tensors_List, labels_List, outputKeys_List,
    sizes_Association, mul_, add_] :=
  First @ Fold[
    Function[{acc, i},
      Module[{keep = Union[outputKeys,
          If[i < Length[labels], Flatten[labels[[i + 1 ;;]]], {}]]},
        executeContractionPair[mul, add, acc[[1]], acc[[2]], tensors[[i]],
          labels[[i]], keep, sizes]
      ]],
    {First[tensors], First[labels]}, Range[2, Length[tensors]]];

executeContractionPair[mul_, add_, t1_, l1_List, t2_, l2_List, keep_List,
    sizes_Association] :=
  Module[{both, batch, contract, left, right, dims, prod, x1, x2, p1, p2,
          x1r, x2r, mm, resultLabels},
    dims[keys_] := Lookup[sizes, keys];
    prod[keys_] := Times @@ dims[keys];
    both = Intersection[l1, l2];
    batch = Select[l1, MemberQ[both, #] && MemberQ[keep, #] &];
    contract = Select[l1, MemberQ[both, #] && ! MemberQ[keep, #] &];
    left = Select[l1, ! MemberQ[l2, #] && MemberQ[keep, #] &];
    right = Select[l2, ! MemberQ[l1, #] && MemberQ[keep, #] &];
    x1 = If[l1 === {}, t1, ArrayReshape[t1, dims[l1]]];
    x2 = If[l2 === {}, t2, ArrayReshape[t2, dims[l2]]];
    p1 = Flatten[FirstPosition[l1, #] & /@ Join[batch, left, contract]];
    p2 = Flatten[FirstPosition[l2, #] & /@ Join[batch, contract, right]];
    If[Length[p1] > 1, x1 = Transpose[x1, InversePermutation[p1]]];
    If[Length[p2] > 1, x2 = Transpose[x2, InversePermutation[p2]]];
    x1r = If[l1 === {}, ArrayReshape[{t1}, {1, 1, 1}],
      ArrayReshape[x1, {prod[batch], prod[left], prod[contract]}]];
    x2r = If[l2 === {}, ArrayReshape[{t2}, {1, 1, 1}],
      ArrayReshape[x2, {prod[batch], prod[contract], prod[right]}]];
    mm = If[mul === Times && add === Plus,
      MapThread[Dot, {x1r, x2r}],
      MapThread[Inner[mul, #1, #2, add] &, {x1r, x2r}]];
    resultLabels = Join[batch, left, right];
    {If[resultLabels === {}, First @ Flatten[mm],
      ArrayReshape[mm, dims[resultLabels]]], resultLabels}
  ];

renderContractionFold[helds_List, labels_List, outputKeys_List,
    sizes_Association, mul_, add_] :=
  First @ Fold[
    Function[{acc, i},
      Module[{keep = Union[outputKeys,
          If[i < Length[labels], Flatten[labels[[i + 1 ;;]]], {}]]},
        renderContractionPair[mul, add, acc[[1]], acc[[2]], helds[[i]],
          labels[[i]], keep, sizes]
      ]],
    {First[helds], First[labels]}, Range[2, Length[helds]]];

renderContractionPair[mul_, add_, ht1_HoldComplete, l1_List,
    ht2_HoldComplete, l2_List, keep_List, sizes_Association] :=
  Module[{both, batch, contract, left, right, dims, prod, x1, x2, p1, p2,
          x1r, x2r, mm, resultLabels},
    dims[keys_] := Lookup[sizes, keys];
    prod[keys_] := Times @@ dims[keys];
    both = Intersection[l1, l2];
    batch = Select[l1, MemberQ[both, #] && MemberQ[keep, #] &];
    contract = Select[l1, MemberQ[both, #] && ! MemberQ[keep, #] &];
    left = Select[l1, ! MemberQ[l2, #] && MemberQ[keep, #] &];
    right = Select[l2, ! MemberQ[l1, #] && MemberQ[keep, #] &];
    x1 = If[l1 === {}, ht1, heldReshape[ht1, dims[l1]]];
    x2 = If[l2 === {}, ht2, heldReshape[ht2, dims[l2]]];
    p1 = Flatten[FirstPosition[l1, #] & /@ Join[batch, left, contract]];
    p2 = Flatten[FirstPosition[l2, #] & /@ Join[batch, contract, right]];
    If[Length[p1] > 1, x1 = heldTranspose[x1, InversePermutation[p1]]];
    If[Length[p2] > 1, x2 = heldTranspose[x2, InversePermutation[p2]]];
    x1r = If[l1 === {}, plannerHeldScalarBlock[ht1],
      heldReshape[x1, {prod[batch], prod[left], prod[contract]}]];
    x2r = If[l2 === {}, plannerHeldScalarBlock[ht2],
      heldReshape[x2, {prod[batch], prod[contract], prod[right]}]];
    mm = If[mul === Times && add === Plus,
      heldMapThreadDot[x1r, x2r],
      heldMapThreadInner[mul, add, x1r, x2r]];
    resultLabels = Join[batch, left, right];
    {If[resultLabels === {}, heldReshape[mm, {}],
      heldReshape[mm, dims[resultLabels]]], resultLabels}
  ];

plannerHeldScalarBlock[HoldComplete[e_]] :=
  HoldComplete[ArrayReshape[{e}, {1, 1, 1}]];

plannerFailure[tag_, details_Association] :=
  irp["FailureRecord"][tag, "Plan", details];
plannerFailureQ[expr_] := Head[Unevaluated[expr]] === irp["FailureRecord"];
