(* ::Package:: *)

(* Massage — the permissive single-tensor ("univalent") structural engine
   (einx.id / einops.rearrange and friends).  It performs: permute + split + merge;
   repetition (an output-only axis broadcast, SPEC 5.5); direct sum (CirclePlus,
   delegated to the DirectSum path); and within-tensor *pairwise* contraction — a
   name repeated in the input and dropped on the output is summed over its coincident
   slots (the einsum-within-one-tensor case, e.g. the Ricci trace R^a_bad -> R_bd),
   via selfContract.

   This is the engine the guarded entrances delegate to: Einstoff["Massage"] is it,
   ungated.  The intent guards live here too, as thin policies over the shared
   `massageCore`: Einstoff[ArrayReshape] = EinstoffReshape = pure-bijective (count-
   preserving reindexing); Einstoff["ArrayContract"] = EinstoffContract = no-repetition
   (adds within-tensor contraction).  Einstoff["einsum"] (Einsum.wl) is the pairwise-
   contraction dispatcher composing the cross-tensor Dot fold.  A future cross-tensor
   backend parallel to this univalent engine is sketched as EinstoffTandem (see SPEC §9
   / the design note).

   Every entrance compiles to the shared structured IR and execution-plan engine.
   Operation policy, rather than a separate matcher/lowerer, decides which structural
   effects are admitted. *)

PackageExported[{EinstoffMassage, EinstoffReshape, EinstoffContract}]

EinstoffMassage::usage =
  "EinstoffMassage[desc, tensors, bindings] is the permissive single-tensor \
structural engine: rearrange/split/merge, repetition (an output-only axis), direct \
sum, and within-tensor pairwise contraction (a repeated, dropped input axis is summed \
over its coincident slots). The named entrances (Einstoff[ArrayReshape], \
Einstoff[\"ArrayContract\"], Einstoff[\"einsum\"]) are guards that delegate here. \
desc is not held.";

EinstoffReshape::usage =
  "EinstoffReshape[desc, tensors, bindings] is the bijective entrance \
(Einstoff[ArrayReshape]): permute/split/merge and unit-axis insert/squeeze only; an \
element-count-preserving reindexing. Repetition (an output-only axis of size > 1), \
within-tensor contraction, reduction, and direct sum are rejected (use \
Einstoff[\"ArrayContract\"], Einstoff[ArrayReduce], Einstoff[Join]/[Split], or the \
permissive Einstoff[\"Massage\"]). desc is not held.";

EinstoffContract::usage =
  "EinstoffContract[desc, tensors, bindings] is the within-tensor contraction entrance \
(Einstoff[\"ArrayContract\"]): everything EinstoffReshape allows plus a within-tensor \
pairwise contraction (a repeated, dropped input axis summed over its coincident slots). \
It admits no repetition (an output-only axis of size > 1) and no direct sum; a plain \
single-index sum-reduction is out of scope (use Einstoff[ArrayReduce]). desc is not held.";

Einstoff["Massage"]       := EinstoffMassage;
Einstoff[ArrayReshape]    := EinstoffReshape;
Einstoff["Reshape"]       := EinstoffReshape;
Einstoff["Rearrange"]     := EinstoffReshape;
Einstoff["ArrayContract"] := EinstoffContract;
Einstoff["Contract"]      := EinstoffContract;

Options[EinstoffMassage] = {TraceAction -> None, "Targeting" -> Automatic};
Options[EinstoffReshape] = {TraceAction -> None, "Targeting" -> Automatic};
Options[EinstoffContract] = {TraceAction -> None, "Targeting" -> Automatic};

(* The three entrances are one engine under three policies, differing only in which
   non-bijective features they admit (element counts, single tensor):
     All        (EinstoffMassage)  — permissive: also repetition and direct sum
     "Reshape"  (EinstoffReshape)  — bijective: count-preserving reindexing only
     "Contract" (EinstoffContract) — no repetition; adds within-tensor contraction
   Keeping the policy inside the shared core (massageCore) means the guards are pure
   intent declarations and the classification of a rejected desc ("wrong guard" vs
   "wrong lowering") lives at the exact point each feature becomes known. *)
EinstoffMassage[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  massageCore[desc, tensors, bindings, All, OptionValue[TraceAction],
    OptionValue["Targeting"]];
EinstoffReshape[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  massageCore[desc, tensors, bindings, "Reshape", OptionValue[TraceAction],
    OptionValue["Targeting"]];
EinstoffContract[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  massageCore[desc, tensors, bindings, "Contract", OptionValue[TraceAction],
    OptionValue["Targeting"]];

(* desc is NOT held (uniform convention): Pattern holds each binding `name_` and `:>`
   holds the RHS, so only a bare reference to a globally bound symbol is substituted. *)
massageCore[desc_, tensors_, bindings_List, policy_, traceAction_, targeting_] :=
  withAxisScope @ Catch[
    Module[{parts, lhs, rhs, targetingMode, planned, planOperator},
      targetingMode = einCatch[validateTargetingOption[targeting]];
      If[targetingMode === $Failed, Throw[$Failed, massageCoreTag]];
      parts = descParts[Hold[desc]];
      If[parts === $Failed, Throw[descFailReturn[], massageCoreTag]];
      {lhs, rhs} = parts;
      If[hasCirclePlus[rhs] || hasCirclePlus[lhs],
        If[policy =!= All,
          Message[Einstoff::unsupp,
            "a direct sum (CirclePlus) is a structural join/split; use Einstoff[Join]/[Split]"];
          Throw[$Failed, massageCoreTag]];
        Throw[If[hasCirclePlus[rhs],
          directSumConcat[desc, tensors, bindings, traceAction],
          directSumSplit[desc, tensors, bindings, traceAction]], massageCoreTag]];
      planOperator = Which[
        policy === "Reshape", "Reshape",
        policy === "Contract", "Contract",
        True, "Massage"];
      planned = tryStructuralIRPlan[Hold[desc], tensors, bindings, planOperator,
        targetingMode, traceAction];
      If[plannerFailureQ[planned], reportPlannerFailure[planned], planned]
    ], massageCoreTag];
