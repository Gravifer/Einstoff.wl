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
  irSurfaceDesc, irSourceRef, irFailure,
  irStageQ, irValidQ, irValidate, irNodes, irFreeOfSurfaceSyntaxQ
}]

irConstructors = {
  Einstoff`Internal`IR`AxisId,
  Einstoff`Internal`IR`OccurrenceId,
  Einstoff`Internal`IR`SourceRef,
  Einstoff`Internal`IR`SurfaceDesc,
  Einstoff`Internal`IR`CapturedDesc,
  Einstoff`Internal`IR`NormalizedDesc,
  Einstoff`Internal`IR`ConstraintDesc,
  Einstoff`Internal`IR`SolvedDesc,
  Einstoff`Internal`IR`OperationAnalysis,
  Einstoff`Internal`IR`ExecutionPlan,
  Einstoff`Internal`IR`Inputs,
  Einstoff`Internal`IR`Outputs,
  Einstoff`Internal`IR`Shape,
  Einstoff`Internal`IR`AxisOccurrence,
  Einstoff`Internal`IR`LiteralAxis,
  Einstoff`Internal`IR`ProductAxis,
  Einstoff`Internal`IR`DirectSumAxis,
  Einstoff`Internal`IR`AnonymousAxis,
  Einstoff`Internal`IR`SequenceAxis,
  Einstoff`Internal`IR`RepeatedGroup,
  Einstoff`Internal`IR`SequenceReference,
  Einstoff`Internal`IR`SequenceProjection,
  Einstoff`Internal`IR`SequenceZip,
  Einstoff`Internal`IR`SequenceComposition,
  Einstoff`Internal`IR`AxisTable,
  Einstoff`Internal`IR`AxisInfo,
  Einstoff`Internal`IR`BindingFacts,
  Einstoff`Internal`IR`BindingFact,
  Einstoff`Internal`IR`SourceMap,
  Einstoff`Internal`IR`Constraints,
  Einstoff`Internal`IR`EqualSize,
  Einstoff`Internal`IR`KnownSize,
  Einstoff`Internal`IR`TensorDimension,
  Einstoff`Internal`IR`ProductSize,
  Einstoff`Internal`IR`SumSize,
  Einstoff`Internal`IR`SequenceLength,
  Einstoff`Internal`IR`RepeatedMemberConstraint,
  Einstoff`Internal`IR`CrossGroupLength,
  Einstoff`Internal`IR`InlineSizeCheck,
  Einstoff`Internal`IR`SizeAxis,
  Einstoff`Internal`IR`SizeLiteral,
  Einstoff`Internal`IR`SizeProduct,
  Einstoff`Internal`IR`SizeSum,
  Einstoff`Internal`IR`TargetPolicy,
  Einstoff`Internal`IR`Effects,
  Einstoff`Internal`IR`Carried,
  Einstoff`Internal`IR`Reduced,
  Einstoff`Internal`IR`Contracted,
  Einstoff`Internal`IR`Broadcast,
  Einstoff`Internal`IR`TargetBlock,
  Einstoff`Internal`IR`DirectSumGroup,
  Einstoff`Internal`IR`UnitAxis,
  Einstoff`Internal`IR`InputValue,
  Einstoff`Internal`IR`IntermediateValue,
  Einstoff`Internal`IR`ReshapeStep,
  Einstoff`Internal`IR`TransposeStep,
  Einstoff`Internal`IR`ReduceStep,
  Einstoff`Internal`IR`ContractStep,
  Einstoff`Internal`IR`InnerStep,
  Einstoff`Internal`IR`TargetBlockStep,
  Einstoff`Internal`IR`BroadcastStep,
  Einstoff`Internal`IR`SliceStep,
  Einstoff`Internal`IR`ConcatenateStep,
  Einstoff`Internal`IR`RecomposeStep,
  Einstoff`Internal`IR`AssembleOutputsStep,
  Einstoff`Internal`IR`FailureRecord
};

irStageHeads = {
  Einstoff`Internal`IR`SurfaceDesc,
  Einstoff`Internal`IR`CapturedDesc,
  Einstoff`Internal`IR`NormalizedDesc,
  Einstoff`Internal`IR`ConstraintDesc,
  Einstoff`Internal`IR`SolvedDesc,
  Einstoff`Internal`IR`OperationAnalysis,
  Einstoff`Internal`IR`ExecutionPlan
};

irStructuralHeads = {
  Einstoff`Internal`IR`Inputs,
  Einstoff`Internal`IR`Outputs,
  Einstoff`Internal`IR`Shape,
  Einstoff`Internal`IR`AxisOccurrence,
  Einstoff`Internal`IR`LiteralAxis,
  Einstoff`Internal`IR`ProductAxis,
  Einstoff`Internal`IR`DirectSumAxis,
  Einstoff`Internal`IR`AnonymousAxis,
  Einstoff`Internal`IR`SequenceAxis,
  Einstoff`Internal`IR`RepeatedGroup,
  Einstoff`Internal`IR`SequenceReference,
  Einstoff`Internal`IR`SequenceProjection,
  Einstoff`Internal`IR`SequenceZip,
  Einstoff`Internal`IR`SequenceComposition
};

irPlanStepHeads = {
  Einstoff`Internal`IR`ReshapeStep,
  Einstoff`Internal`IR`TransposeStep,
  Einstoff`Internal`IR`ReduceStep,
  Einstoff`Internal`IR`ContractStep,
  Einstoff`Internal`IR`InnerStep,
  Einstoff`Internal`IR`TargetBlockStep,
  Einstoff`Internal`IR`BroadcastStep,
  Einstoff`Internal`IR`SliceStep,
  Einstoff`Internal`IR`ConcatenateStep,
  Einstoff`Internal`IR`RecomposeStep,
  Einstoff`Internal`IR`AssembleOutputsStep
};

(* The constructors are data heads, not smart constructors.  Protecting the
   actual fully-qualified symbols prevents accidental definitions while leaving
   package reload and inspection possible (they are intentionally not Locked). *)
SetAttributes[
  {
    Einstoff`Internal`IR`AxisId,
    Einstoff`Internal`IR`OccurrenceId,
    Einstoff`Internal`IR`SourceRef,
    Einstoff`Internal`IR`SurfaceDesc,
    Einstoff`Internal`IR`CapturedDesc,
    Einstoff`Internal`IR`NormalizedDesc,
    Einstoff`Internal`IR`ConstraintDesc,
    Einstoff`Internal`IR`SolvedDesc,
    Einstoff`Internal`IR`OperationAnalysis,
    Einstoff`Internal`IR`ExecutionPlan,
    Einstoff`Internal`IR`Inputs,
    Einstoff`Internal`IR`Outputs,
    Einstoff`Internal`IR`Shape,
    Einstoff`Internal`IR`AxisOccurrence,
    Einstoff`Internal`IR`LiteralAxis,
    Einstoff`Internal`IR`ProductAxis,
    Einstoff`Internal`IR`DirectSumAxis,
    Einstoff`Internal`IR`AnonymousAxis,
    Einstoff`Internal`IR`SequenceAxis,
    Einstoff`Internal`IR`RepeatedGroup,
    Einstoff`Internal`IR`SequenceReference,
    Einstoff`Internal`IR`SequenceProjection,
    Einstoff`Internal`IR`SequenceZip,
    Einstoff`Internal`IR`SequenceComposition,
    Einstoff`Internal`IR`AxisTable,
    Einstoff`Internal`IR`AxisInfo,
    Einstoff`Internal`IR`BindingFacts,
    Einstoff`Internal`IR`BindingFact,
    Einstoff`Internal`IR`SourceMap,
    Einstoff`Internal`IR`Constraints,
    Einstoff`Internal`IR`EqualSize,
    Einstoff`Internal`IR`KnownSize,
    Einstoff`Internal`IR`TensorDimension,
    Einstoff`Internal`IR`ProductSize,
    Einstoff`Internal`IR`SumSize,
    Einstoff`Internal`IR`SequenceLength,
    Einstoff`Internal`IR`RepeatedMemberConstraint,
    Einstoff`Internal`IR`CrossGroupLength,
    Einstoff`Internal`IR`InlineSizeCheck,
    Einstoff`Internal`IR`SizeAxis,
    Einstoff`Internal`IR`SizeLiteral,
    Einstoff`Internal`IR`SizeProduct,
    Einstoff`Internal`IR`SizeSum,
    Einstoff`Internal`IR`TargetPolicy,
    Einstoff`Internal`IR`Effects,
    Einstoff`Internal`IR`Carried,
    Einstoff`Internal`IR`Reduced,
    Einstoff`Internal`IR`Contracted,
    Einstoff`Internal`IR`Broadcast,
    Einstoff`Internal`IR`TargetBlock,
    Einstoff`Internal`IR`DirectSumGroup,
    Einstoff`Internal`IR`UnitAxis,
    Einstoff`Internal`IR`InputValue,
    Einstoff`Internal`IR`IntermediateValue,
    Einstoff`Internal`IR`ReshapeStep,
    Einstoff`Internal`IR`TransposeStep,
    Einstoff`Internal`IR`ReduceStep,
    Einstoff`Internal`IR`ContractStep,
    Einstoff`Internal`IR`InnerStep,
    Einstoff`Internal`IR`TargetBlockStep,
    Einstoff`Internal`IR`BroadcastStep,
    Einstoff`Internal`IR`SliceStep,
    Einstoff`Internal`IR`ConcatenateStep,
    Einstoff`Internal`IR`RecomposeStep,
    Einstoff`Internal`IR`AssembleOutputsStep,
    Einstoff`Internal`IR`FailureRecord
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
    If[! MissingQ[known], Return[{known, state}]];
    n = state["NextAxisId"];
    id = Einstoff`Internal`IR`AxisId[n];
    names = Append[state["NameToAxisId"], name -> id];
    table = Append[state["AxisMetadata"],
      id -> Einstoff`Internal`IR`AxisInfo[
        Lookup[metadata, "DisplayName", name], KeyDrop[metadata, "DisplayName"]]];
    {id, Join[state, <|
      "NameToAxisId" -> names,
      "AxisMetadata" -> table,
      "NextAxisId" -> n + 1
    |>]}
  ];

irInternAxis[name_String, state_Association] := irInternAxis[name, <||>, state];

irNewOccurrence[state_Association] :=
  Module[{n = state["NextOccurrenceId"]},
    {Einstoff`Internal`IR`OccurrenceId[n],
      Join[state, <|"NextOccurrenceId" -> n + 1|>]}
  ];

SetAttributes[irSurfaceDesc, HoldAllComplete];
irSurfaceDesc[desc_, bindings_, operator_ : None, options_ : <||>] :=
  Einstoff`Internal`IR`SurfaceDesc[
    HoldComplete[desc], HoldComplete[bindings], operator, options];

irSourceRef[path_List, held_HoldComplete] :=
  Einstoff`Internal`IR`SourceRef[path, held];

irFailure[tag_String, stage_, details_Association : <||>] :=
  Einstoff`Internal`IR`FailureRecord[tag, stage, details];

irStageQ[expr_] := MemberQ[irStageHeads, Head[Unevaluated[expr]]];

irNodes[expr_] := Cases[Unevaluated[expr],
  n_ /; MemberQ[irConstructors, Head[Unevaluated[n]]], {0, Infinity}];

irFreeOfSurfaceSyntaxQ[expr_] := FreeQ[Unevaluated[expr],
  _Pattern | _Blank | _BlankSequence | _BlankNullSequence |
    _Rule | _RuleDelayed | _Slot | _SlotSequence |
    _Highlighted | _Framed | _Annotation | _Labeled,
  {0, Infinity}, Heads -> True];

irValidIdQ[Einstoff`Internal`IR`AxisId[n_Integer?Positive]] := True;
irValidIdQ[Einstoff`Internal`IR`OccurrenceId[n_Integer?Positive]] := True;
irValidIdQ[_] := False;

irValidSourceRefQ[Einstoff`Internal`IR`SourceRef[path_List, _HoldComplete]] :=
  VectorQ[path, IntegerQ[#] && # >= 0 &];
irValidSourceRefQ[_] := False;

irValidQ[Einstoff`Internal`IR`SurfaceDesc[
    _HoldComplete, _HoldComplete, _, opts_]] := AssociationQ[opts];
irValidQ[Einstoff`Internal`IR`CapturedDesc[assoc_Association]] := True;
irValidQ[n_Einstoff`Internal`IR`NormalizedDesc] := irFreeOfSurfaceSyntaxQ[n];
irValidQ[n_Einstoff`Internal`IR`ConstraintDesc] := irFreeOfSurfaceSyntaxQ[n];
irValidQ[n_Einstoff`Internal`IR`SolvedDesc] := irFreeOfSurfaceSyntaxQ[n];
irValidQ[n_Einstoff`Internal`IR`OperationAnalysis] := irFreeOfSurfaceSyntaxQ[n];
irValidQ[Einstoff`Internal`IR`ExecutionPlan[steps_List, ___]] :=
  AllTrue[steps, MemberQ[irPlanStepHeads, Head[Unevaluated[#]]] &];
irValidQ[id : (Einstoff`Internal`IR`AxisId[_] |
    Einstoff`Internal`IR`OccurrenceId[_])] := irValidIdQ[id];
irValidQ[src_Einstoff`Internal`IR`SourceRef] := irValidSourceRefQ[src];
irValidQ[_] := False;

irValidate[expr_] := If[TrueQ[irValidQ[expr]], expr,
  irFailure["InvalidIR", Head[Unevaluated[expr]],
    <|"Expression" -> HoldComplete[expr]|>]];
