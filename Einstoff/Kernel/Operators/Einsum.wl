(* ::Package:: *)

(* einsum entrance — the pairwise-contraction subset of NumPy / einops.einsum.

   A name repeated within one operand and dropped on the output is summed over its
   coincident slots (within-tensor contraction / partial trace, e.g. Ricci
   R^a_bad -> R_bd); a name shared across operands and dropped is summed across them
   (cross-tensor contraction).  Pairwise only — a name kept on the output (diagonal)
   or occurring >2 times (super-diagonal, non-tensorial) is rejected by the engines
   below; an output axis that appears on no input (repetition / broadcast) is rejected
   here, since einsum has no spelling for it.

   This is a thin dispatcher over the existing engines (option (A)):
     1 tensor      -> Einstoff["Massage"]  (within-tensor contraction + rearrange)
     >=2 tensors   -> the Einstoff[Dot] cross-tensor fold
   The mixed case (a within-operand repeat in a multi-tensor desc) is deferred.  A
   single dropped index (a plain sum-reduction, np.einsum "ab->a") is NOT part of the
   contraction subset — Massage rejects it pointing at Einstoff[ArrayReduce].  A future
   cross-tensor backend parallel to the univalent Massage is sketched as EinstoffTandem.

   Surface parsing, shape solving, and tensor execution are delegated to the staged
   compiler and shared execution-plan engine. *)

PackageExported[{EinstoffEinsum}]

EinstoffEinsum::usage =
  "EinstoffEinsum[desc, tensors, bindings] realizes the pairwise-contraction subset \
of einsum: within-tensor contraction (a repeated, dropped index summed over its \
coincident slots) for one tensor, and cross-tensor contraction for several. \
Einstoff[\"einsum\"]. Repetition (a new output axis) and single-index sum-reduction \
are out of scope (use Einstoff[\"Massage\"] / Einstoff[ArrayReduce]).";

Einstoff["einsum"] := EinstoffEinsum;
Einstoff["Einsum"] := EinstoffEinsum;

Options[EinstoffEinsum] = {TraceAction -> None, "Targeting" -> Automatic};

EinstoffEinsum[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  Module[{targeting, compiled, normalized, summary, planned, traceAction},
    traceAction = OptionValue[TraceAction];
    targeting = Catch[validateTargetingOption[OptionValue["Targeting"]], einThrowTag];
    If[plannerFailureQ[targeting], reportPlannerFailure[targeting],
    compiled = compileHeldDescIR[Hold[desc], HoldComplete[bindings], "einsum",
      <|"Targeting" -> targeting|>];
    normalized = Lookup[compiled, "Normalized", None];
    If[Head[normalized] =!= Einstoff`Internal`IR`NormalizedDesc,
      reportPlannerFailure[normalized],
    summary = einsumSummary[normalized];
    planned = Which[
      summary["DirectSum"],
        reportPlannerFailure @ einsumPolicyFailure["DirectSum",
          "einsum does not take a direct sum; use Einstoff[Join]/[Split]"],
      summary["OutputOnly"],
        reportPlannerFailure @ einsumPolicyFailure["OutputOnly",
          "einsum cannot introduce a broadcast/output-only axis"],
      summary["SingleDrop"],
        reportPlannerFailure @ einsumPolicyFailure["SingleDrop",
          "einsum does not perform single-axis reduction; use Einstoff[ArrayReduce]"],
      Length[tensors] > 1 && summary["WithinRepeat"],
        reportPlannerFailure @ einsumPolicyFailure["WithinRepeat",
          "contract a within-operand repeated index before a multi-tensor einsum"],
      Length[tensors] === 1,
        tryStructuralCompiledIRPlan[compiled, tensors, "Massage",
          targeting, traceAction],
      True,
        tryInnerCompiledIRPlan[compiled, tensors, Times, Plus,
          targeting, traceAction]];
    If[plannerFailureQ[planned], reportPlannerFailure[planned], planned]]]
  ];

einsumPolicyFailure[tag_String, reason_String] :=
  Einstoff`Internal`IR`FailureRecord["Einsum" <> tag, "Analysis", <|
    "Operator" -> "einsum", "Reason" -> reason, "MessageParameters" -> {}|>];

einsumSummary[Einstoff`Internal`IR`NormalizedDesc[a_Association]] :=
  Module[{inputs, outputs, inputShapes, inputIds, outputIds},
    inputs = a["Inputs"]; outputs = a["Outputs"];
    inputShapes = Replace[inputs, Einstoff`Internal`IR`Inputs[x_List] :> x];
    inputIds = Cases[inputs,
      Einstoff`Internal`IR`AxisOccurrence[_, id_, _] :> id, Infinity];
    outputIds = Cases[outputs,
      Einstoff`Internal`IR`AxisOccurrence[_, id_, _] :> id, Infinity];
    <|"DirectSum" -> ! FreeQ[{inputs, outputs},
        Einstoff`Internal`IR`DirectSumAxis, Infinity],
      "OutputOnly" -> Complement[DeleteDuplicates[outputIds],
          DeleteDuplicates[inputIds]] =!= {} ||
        ! FreeQ[outputs, Einstoff`Internal`IR`LiteralAxis, Infinity],
      "SingleDrop" -> AnyTrue[DeleteDuplicates[inputIds],
        ! MemberQ[outputIds, #] && Count[inputIds, #] === 1 &],
      "WithinRepeat" -> AnyTrue[inputShapes,
        Function[shape, With[{ids = Cases[shape,
            Einstoff`Internal`IR`AxisOccurrence[_, id_, _] :> id, Infinity]},
          ! DuplicateFreeQ[ids]]]]|>
  ];
