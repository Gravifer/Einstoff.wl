(* ::Package:: *)

(* Einstoff staged internal representation.

   Surface WL syntax is captured under HoldComplete, then compiled into these
   inert constructors.  Constructor symbols deliberately have no values: all
   construction, validation, allocation, and traversal logic lives in the
   package-scoped helpers below.  The context is not exported and is not placed
   on $ContextPath.

   AxisId and OccurrenceId wrap operation-local positive integers.  They do not
   create symbols or definitions per identity and require no cleanup. *)

PackageScoped[{
  irConstructors, irStageHeads, irStructuralHeads, irPlanStepHeads,
  irNewState, irInternAxis, irNewOccurrence, irAxisMetadata,
  irSurfaceDesc, irSourceRef, irFailure, irEnrichFailure,
  irStageQ, irValidQ, irValidate, irNodes, irFreeOfSurfaceSyntaxQ
}]

irConstructors = {
  Gravifer`Einstoff`Internal`IR`AxisId,
  Gravifer`Einstoff`Internal`IR`OccurrenceId,
  Gravifer`Einstoff`Internal`IR`SourceRef,
  Gravifer`Einstoff`Internal`IR`SurfaceDesc,
  Gravifer`Einstoff`Internal`IR`CapturedDesc,
  Gravifer`Einstoff`Internal`IR`NormalizedDesc,
  Gravifer`Einstoff`Internal`IR`ConstraintDesc,
  Gravifer`Einstoff`Internal`IR`SolvedDesc,
  Gravifer`Einstoff`Internal`IR`OperationAnalysis,
  Gravifer`Einstoff`Internal`IR`ExecutionPlan,
  Gravifer`Einstoff`Internal`IR`Inputs,
  Gravifer`Einstoff`Internal`IR`Outputs,
  Gravifer`Einstoff`Internal`IR`Shape,
  Gravifer`Einstoff`Internal`IR`AxisOccurrence,
  Gravifer`Einstoff`Internal`IR`LiteralAxis,
  Gravifer`Einstoff`Internal`IR`ProductAxis,
  Gravifer`Einstoff`Internal`IR`DirectSumAxis,
  Gravifer`Einstoff`Internal`IR`AnonymousAxis,
  Gravifer`Einstoff`Internal`IR`SequenceAxis,
  Gravifer`Einstoff`Internal`IR`RepeatedGroup,
  Gravifer`Einstoff`Internal`IR`SequenceReference,
  Gravifer`Einstoff`Internal`IR`SequenceProjection,
  Gravifer`Einstoff`Internal`IR`SequenceZip,
  Gravifer`Einstoff`Internal`IR`SequenceComposition,
  Gravifer`Einstoff`Internal`IR`SequenceMemberId,
  Gravifer`Einstoff`Internal`IR`SequenceOccurrence,
  Gravifer`Einstoff`Internal`IR`AxisTable,
  Gravifer`Einstoff`Internal`IR`AxisInfo,
  Gravifer`Einstoff`Internal`IR`BindingFacts,
  Gravifer`Einstoff`Internal`IR`BindingFact,
  Gravifer`Einstoff`Internal`IR`SourceMap,
  Gravifer`Einstoff`Internal`IR`Constraints,
  Gravifer`Einstoff`Internal`IR`EqualSize,
  Gravifer`Einstoff`Internal`IR`EqualSizeExpr,
  Gravifer`Einstoff`Internal`IR`KnownSize,
  Gravifer`Einstoff`Internal`IR`TensorDimension,
  Gravifer`Einstoff`Internal`IR`ProductSize,
  Gravifer`Einstoff`Internal`IR`SumSize,
  Gravifer`Einstoff`Internal`IR`SequenceLength,
  Gravifer`Einstoff`Internal`IR`RepeatedMemberConstraint,
  Gravifer`Einstoff`Internal`IR`CrossGroupLength,
  Gravifer`Einstoff`Internal`IR`InlineSizeCheck,
  Gravifer`Einstoff`Internal`IR`SizeAxis,
  Gravifer`Einstoff`Internal`IR`SizeLiteral,
  Gravifer`Einstoff`Internal`IR`SizeProduct,
  Gravifer`Einstoff`Internal`IR`SizeSum,
  Gravifer`Einstoff`Internal`IR`TargetPolicy,
  Gravifer`Einstoff`Internal`IR`OperationSpec,
  Gravifer`Einstoff`Internal`IR`Violation,
  Gravifer`Einstoff`Internal`IR`Effects,
  Gravifer`Einstoff`Internal`IR`Carried,
  Gravifer`Einstoff`Internal`IR`Reduced,
  Gravifer`Einstoff`Internal`IR`Contracted,
  Gravifer`Einstoff`Internal`IR`Broadcast,
  Gravifer`Einstoff`Internal`IR`TargetBlock,
  Gravifer`Einstoff`Internal`IR`DirectSumGroup,
  Gravifer`Einstoff`Internal`IR`UnitAxis,
  Gravifer`Einstoff`Internal`IR`InputValue,
  Gravifer`Einstoff`Internal`IR`IntermediateValue,
  Gravifer`Einstoff`Internal`IR`ReshapeStep,
  Gravifer`Einstoff`Internal`IR`TransposeStep,
  Gravifer`Einstoff`Internal`IR`ReduceStep,
  Gravifer`Einstoff`Internal`IR`ContractStep,
  Gravifer`Einstoff`Internal`IR`InnerStep,
  Gravifer`Einstoff`Internal`IR`TargetBlockStep,
  Gravifer`Einstoff`Internal`IR`BroadcastStep,
  Gravifer`Einstoff`Internal`IR`SliceStep,
  Gravifer`Einstoff`Internal`IR`ConcatenateStep,
  Gravifer`Einstoff`Internal`IR`RecomposeStep,
  Gravifer`Einstoff`Internal`IR`AssembleOutputsStep,
  Gravifer`Einstoff`Internal`IR`FailureRecord
};

irStageHeads = {
  Gravifer`Einstoff`Internal`IR`SurfaceDesc,
  Gravifer`Einstoff`Internal`IR`CapturedDesc,
  Gravifer`Einstoff`Internal`IR`NormalizedDesc,
  Gravifer`Einstoff`Internal`IR`ConstraintDesc,
  Gravifer`Einstoff`Internal`IR`SolvedDesc,
  Gravifer`Einstoff`Internal`IR`OperationAnalysis,
  Gravifer`Einstoff`Internal`IR`ExecutionPlan
};

irStructuralHeads = {
  Gravifer`Einstoff`Internal`IR`Inputs,
  Gravifer`Einstoff`Internal`IR`Outputs,
  Gravifer`Einstoff`Internal`IR`Shape,
  Gravifer`Einstoff`Internal`IR`AxisOccurrence,
  Gravifer`Einstoff`Internal`IR`LiteralAxis,
  Gravifer`Einstoff`Internal`IR`ProductAxis,
  Gravifer`Einstoff`Internal`IR`DirectSumAxis,
  Gravifer`Einstoff`Internal`IR`AnonymousAxis,
  Gravifer`Einstoff`Internal`IR`SequenceAxis,
  Gravifer`Einstoff`Internal`IR`RepeatedGroup,
  Gravifer`Einstoff`Internal`IR`SequenceReference,
  Gravifer`Einstoff`Internal`IR`SequenceProjection,
  Gravifer`Einstoff`Internal`IR`SequenceZip,
  Gravifer`Einstoff`Internal`IR`SequenceComposition
};

irPlanStepHeads = {
  Gravifer`Einstoff`Internal`IR`ReshapeStep,
  Gravifer`Einstoff`Internal`IR`TransposeStep,
  Gravifer`Einstoff`Internal`IR`ReduceStep,
  Gravifer`Einstoff`Internal`IR`ContractStep,
  Gravifer`Einstoff`Internal`IR`InnerStep,
  Gravifer`Einstoff`Internal`IR`TargetBlockStep,
  Gravifer`Einstoff`Internal`IR`BroadcastStep,
  Gravifer`Einstoff`Internal`IR`SliceStep,
  Gravifer`Einstoff`Internal`IR`ConcatenateStep,
  Gravifer`Einstoff`Internal`IR`RecomposeStep,
  Gravifer`Einstoff`Internal`IR`AssembleOutputsStep
};

(* The constructors are data heads, not smart constructors.  Protecting the
   actual fully-qualified symbols prevents accidental definitions while leaving
   package reload and inspection possible (they are intentionally not Locked). *)
SetAttributes[
  {
    Gravifer`Einstoff`Internal`IR`AxisId,
    Gravifer`Einstoff`Internal`IR`OccurrenceId,
    Gravifer`Einstoff`Internal`IR`SourceRef,
    Gravifer`Einstoff`Internal`IR`SurfaceDesc,
    Gravifer`Einstoff`Internal`IR`CapturedDesc,
    Gravifer`Einstoff`Internal`IR`NormalizedDesc,
    Gravifer`Einstoff`Internal`IR`ConstraintDesc,
    Gravifer`Einstoff`Internal`IR`SolvedDesc,
    Gravifer`Einstoff`Internal`IR`OperationAnalysis,
    Gravifer`Einstoff`Internal`IR`ExecutionPlan,
    Gravifer`Einstoff`Internal`IR`Inputs,
    Gravifer`Einstoff`Internal`IR`Outputs,
    Gravifer`Einstoff`Internal`IR`Shape,
    Gravifer`Einstoff`Internal`IR`AxisOccurrence,
    Gravifer`Einstoff`Internal`IR`LiteralAxis,
    Gravifer`Einstoff`Internal`IR`ProductAxis,
    Gravifer`Einstoff`Internal`IR`DirectSumAxis,
    Gravifer`Einstoff`Internal`IR`AnonymousAxis,
    Gravifer`Einstoff`Internal`IR`SequenceAxis,
    Gravifer`Einstoff`Internal`IR`RepeatedGroup,
    Gravifer`Einstoff`Internal`IR`SequenceReference,
    Gravifer`Einstoff`Internal`IR`SequenceProjection,
    Gravifer`Einstoff`Internal`IR`SequenceZip,
    Gravifer`Einstoff`Internal`IR`SequenceComposition,
    Gravifer`Einstoff`Internal`IR`SequenceMemberId,
    Gravifer`Einstoff`Internal`IR`SequenceOccurrence,
    Gravifer`Einstoff`Internal`IR`AxisTable,
    Gravifer`Einstoff`Internal`IR`AxisInfo,
    Gravifer`Einstoff`Internal`IR`BindingFacts,
    Gravifer`Einstoff`Internal`IR`BindingFact,
    Gravifer`Einstoff`Internal`IR`SourceMap,
    Gravifer`Einstoff`Internal`IR`Constraints,
    Gravifer`Einstoff`Internal`IR`EqualSize,
    Gravifer`Einstoff`Internal`IR`EqualSizeExpr,
    Gravifer`Einstoff`Internal`IR`KnownSize,
    Gravifer`Einstoff`Internal`IR`TensorDimension,
    Gravifer`Einstoff`Internal`IR`ProductSize,
    Gravifer`Einstoff`Internal`IR`SumSize,
    Gravifer`Einstoff`Internal`IR`SequenceLength,
    Gravifer`Einstoff`Internal`IR`RepeatedMemberConstraint,
    Gravifer`Einstoff`Internal`IR`CrossGroupLength,
    Gravifer`Einstoff`Internal`IR`InlineSizeCheck,
    Gravifer`Einstoff`Internal`IR`SizeAxis,
    Gravifer`Einstoff`Internal`IR`SizeLiteral,
    Gravifer`Einstoff`Internal`IR`SizeProduct,
    Gravifer`Einstoff`Internal`IR`SizeSum,
    Gravifer`Einstoff`Internal`IR`TargetPolicy,
    Gravifer`Einstoff`Internal`IR`OperationSpec,
    Gravifer`Einstoff`Internal`IR`Violation,
    Gravifer`Einstoff`Internal`IR`Effects,
    Gravifer`Einstoff`Internal`IR`Carried,
    Gravifer`Einstoff`Internal`IR`Reduced,
    Gravifer`Einstoff`Internal`IR`Contracted,
    Gravifer`Einstoff`Internal`IR`Broadcast,
    Gravifer`Einstoff`Internal`IR`TargetBlock,
    Gravifer`Einstoff`Internal`IR`DirectSumGroup,
    Gravifer`Einstoff`Internal`IR`UnitAxis,
    Gravifer`Einstoff`Internal`IR`InputValue,
    Gravifer`Einstoff`Internal`IR`IntermediateValue,
    Gravifer`Einstoff`Internal`IR`ReshapeStep,
    Gravifer`Einstoff`Internal`IR`TransposeStep,
    Gravifer`Einstoff`Internal`IR`ReduceStep,
    Gravifer`Einstoff`Internal`IR`ContractStep,
    Gravifer`Einstoff`Internal`IR`InnerStep,
    Gravifer`Einstoff`Internal`IR`TargetBlockStep,
    Gravifer`Einstoff`Internal`IR`BroadcastStep,
    Gravifer`Einstoff`Internal`IR`SliceStep,
    Gravifer`Einstoff`Internal`IR`ConcatenateStep,
    Gravifer`Einstoff`Internal`IR`RecomposeStep,
    Gravifer`Einstoff`Internal`IR`AssembleOutputsStep,
    Gravifer`Einstoff`Internal`IR`FailureRecord
  },
  Protected
];

irNewState[] := <|
  "NameToAxisId" -> <||>,
  "AxisMetadata" -> <||>,
  "NextAxisId" -> 1,
  "NextOccurrenceId" -> 1
|>;

irAxisMetadata[state_Association] := state["AxisMetadata"];

(* Pure interning: return {id, newState}; never mutate caller state. *)
irInternAxis[name_String, metadata_Association, state_Association] :=
  Module[{known = Lookup[state["NameToAxisId"], name, Missing["NotInterned"]],
          n, id, names, table},
    If[! MissingQ[known],
      {known, state},
      n = state["NextAxisId"];
      id = Gravifer`Einstoff`Internal`IR`AxisId[n];
      names = Append[state["NameToAxisId"], name -> id];
      table = Append[state["AxisMetadata"],
        id -> Gravifer`Einstoff`Internal`IR`AxisInfo[
          Lookup[metadata, "DisplayName", name], KeyDrop[metadata, "DisplayName"]]];
      {id, Join[state, <|
        "NameToAxisId" -> names,
        "AxisMetadata" -> table,
        "NextAxisId" -> n + 1
      |>]}
    ]
  ];

irInternAxis[name_String, state_Association] := irInternAxis[name, <||>, state];

irNewOccurrence[state_Association] :=
  Module[{n = state["NextOccurrenceId"]},
    {Gravifer`Einstoff`Internal`IR`OccurrenceId[n],
      Join[state, <|"NextOccurrenceId" -> n + 1|>]}
  ];

SetAttributes[irSurfaceDesc, HoldAllComplete];
irSurfaceDesc[desc_, bindings_, operator_ : None, options_ : <||>] :=
  Gravifer`Einstoff`Internal`IR`SurfaceDesc[
    HoldComplete[desc], HoldComplete[bindings], operator, options];

irSourceRef[path_List, held_HoldComplete] :=
  Gravifer`Einstoff`Internal`IR`SourceRef[path, held];

irFailure[tag_String, stage_, details_Association : <||>] :=
  Gravifer`Einstoff`Internal`IR`FailureRecord[tag, stage, details];

irEnrichFailure[
    Gravifer`Einstoff`Internal`IR`FailureRecord[tag_, stage_, details_Association],
    additions_Association] :=
  Gravifer`Einstoff`Internal`IR`FailureRecord[tag, stage, Join[additions, details]];
irEnrichFailure[other_, _Association] := other;

irStageQ[expr_] := MemberQ[irStageHeads, Head[Unevaluated[expr]]];

irNodes[expr_] := Cases[Unevaluated[expr],
  n_ /; MemberQ[irConstructors, Head[Unevaluated[n]]], {0, Infinity}];

irFreeOfSurfaceSyntaxQ[expr_] :=
  FreeQ[
    Unevaluated[expr] /.
      Gravifer`Einstoff`Internal`IR`SourceRef[_List, _HoldComplete] :> Null,
    _Pattern | _Blank | _BlankSequence | _BlankNullSequence |
      _Rule | _RuleDelayed | _Slot | _SlotSequence |
      _Highlighted | _Framed | _Annotation | _Labeled,
    {0, Infinity}, Heads -> True];

irValidIdQ[Gravifer`Einstoff`Internal`IR`AxisId[n_Integer?Positive]] := True;
irValidIdQ[Gravifer`Einstoff`Internal`IR`OccurrenceId[n_Integer?Positive]] := True;
irValidIdQ[_] := False;

irValidSourceRefQ[Gravifer`Einstoff`Internal`IR`SourceRef[path_List, _HoldComplete]] :=
  VectorQ[path, IntegerQ[#] && # >= 0 &];
irValidSourceRefQ[_] := False;

irValidQ[Gravifer`Einstoff`Internal`IR`SurfaceDesc[
    _HoldComplete, _HoldComplete, _, opts_]] := AssociationQ[opts];
irValidQ[Gravifer`Einstoff`Internal`IR`CapturedDesc[assoc_Association]] :=
  ContainsAll[Keys[assoc], {"Surface", "CanonicalLHS", "CanonicalRHS",
    "EstablishedNames", "AxisKinds", "InlineBindingFacts",
    "ExternalBindings", "CaptureDiagnostics", "SourceMap"}] &&
    Head[assoc["CanonicalRHS"]] === Hold &&
    irFreeOfSurfaceSyntaxQ[assoc["CanonicalLHS"]] &&
    irFreeOfSurfaceSyntaxQ[assoc["CanonicalRHS"]] &&
    irSourceMapValidQ[assoc["SourceMap"]];
irValidQ[n : Gravifer`Einstoff`Internal`IR`NormalizedDesc[assoc_Association]] :=
  ContainsAll[Keys[assoc], {"Inputs", "Outputs", "Axes", "Bindings", "SourceMap"}] &&
    irFreeOfSurfaceSyntaxQ[n] && irNormalizedIdsValidQ[n] &&
    irSourceMapValidQ[assoc["SourceMap"]];
irValidQ[n : Gravifer`Einstoff`Internal`IR`ConstraintDesc[assoc_Association]] :=
  ContainsAll[Keys[assoc], {"Normalized", "InputShapes", "SolvedInputs",
    "SolvedOutputs", "SequenceCaptures", "SourceMap", "Constraints"}] &&
    Head[assoc["Normalized"]] === Gravifer`Einstoff`Internal`IR`NormalizedDesc &&
    irFreeOfSurfaceSyntaxQ[n] && irSourceMapValidQ[assoc["SourceMap"]];
irValidQ[n : Gravifer`Einstoff`Internal`IR`SolvedDesc[assoc_Association]] :=
  ContainsAll[Keys[assoc], {"Normalized", "Constraints", "InputShapes", "Inputs",
    "Outputs", "SequenceCaptures", "SourceMap", "OutputShapes", "AxisSizes"}] &&
    Head[assoc["Constraints"]] === Gravifer`Einstoff`Internal`IR`ConstraintDesc &&
    ListQ[assoc["OutputShapes"]] && AllTrue[assoc["OutputShapes"], ListQ] &&
    irFreeOfSurfaceSyntaxQ[n] &&
    irSourceMapValidQ[assoc["SourceMap"]];
irValidQ[n : Gravifer`Einstoff`Internal`IR`OperationAnalysis[assoc_Association]] :=
  ContainsAll[Keys[assoc], {"Solved", "Operator", "Spec", "TargetPolicy",
    "Effects", "Violations", "Valid"}] &&
    Head[assoc["Solved"]] === Gravifer`Einstoff`Internal`IR`SolvedDesc &&
    BooleanQ[assoc["Valid"]] && irFreeOfSurfaceSyntaxQ[n];
irValidQ[Gravifer`Einstoff`Internal`IR`ExecutionPlan[steps_List, ___]] :=
  AllTrue[steps, MemberQ[irPlanStepHeads, Head[Unevaluated[#]]] &];
irValidQ[id : (Gravifer`Einstoff`Internal`IR`AxisId[_] |
    Gravifer`Einstoff`Internal`IR`OccurrenceId[_])] := irValidIdQ[id];
irValidQ[src_Gravifer`Einstoff`Internal`IR`SourceRef] := irValidSourceRefQ[src];
irValidQ[_] := False;

irSourceMapValidQ[Gravifer`Einstoff`Internal`IR`SourceMap[map_Association]] :=
  AllTrue[Values[map], irValidSourceRefQ];
irSourceMapValidQ[_] := False;

irNormalizedIdsValidQ[expr_] := And[
  AllTrue[Cases[expr, id_Gravifer`Einstoff`Internal`IR`AxisId :> id, Infinity],
    irValidIdQ],
  AllTrue[Cases[expr, id_Gravifer`Einstoff`Internal`IR`OccurrenceId :> id, Infinity],
    irValidIdQ]
];

irValidate[expr_] := If[TrueQ[irValidQ[expr]], expr,
  irFailure["InvalidIR", Head[Unevaluated[expr]],
    <|"Expression" -> HoldComplete[expr]|>]];
