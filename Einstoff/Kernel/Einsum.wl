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

   Shared shape helpers (descParts, hasCirclePlus) live in ShapeChecker.wl; atom
   lowering helpers such as reduceAtoms live in Lowering.wl. *)

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

EinstoffEinsum[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] := withAxisScope @
  Module[{parts, lhs, rhs, opAtoms, rhsAtoms, allLhs, traceAction, targeting},
    traceAction = OptionValue[TraceAction];
    targeting = einCatch[validateTargetingOption[OptionValue["Targeting"]]];
    If[targeting === $Failed, Return[$Failed]];
    parts = descParts[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    {lhs, rhs} = parts;
    If[! MatchQ[tensors, {__}],
      Message[Einstoff::unsupp, "tensors must be a non-empty list of arrays"];
      Return[$Failed]];
    If[hasCirclePlus[lhs] || hasCirclePlus[rhs],
      Message[Einstoff::unsupp,
        "einsum does not take a direct sum (CirclePlus); use Einstoff[Join]/[Split]"];
      Return[$Failed]];

    (* Atoms per operand and on the output (bracket-aware: a marked contraction axis
       counts as its atom).  rearrangeAtoms/reduceAtoms Throw on unsupported terms. *)
    opAtoms = einCatch[Table[(Join @@ Table[reduceAtoms[t], {t, shp}])[[All, 1]], {shp, lhs}]];
    rhsAtoms = einCatch[Join @@ Table[rearrangeAtoms[t], {t, First[rhs]}]];
    If[opAtoms === $Failed || rhsAtoms === $Failed, Return[$Failed]];

    (* einsum has no repetition / broadcast: every output atom must be a NAMED axis that
       appears on some input.  A literal integer on the output is always a new broadcast
       axis under Massage (Option A), and numpy.einsum has no integer subscripts at all,
       so any output integer is rejected here regardless of the input; a named axis not
       on the input is repetition and likewise rejected. *)
    allLhs = Join @@ opAtoms;
    If[AnyTrue[rhsAtoms, IntegerQ[#] || ! MemberQ[allLhs, #] &],
      Message[Einstoff::unsupp,
        "einsum cannot introduce a new output axis: a literal integer axis, or a name \
absent from every input, is repetition / broadcast (use Einstoff[\"Massage\"])"];
      Return[$Failed]];

    Which[
      Length[tensors] === 1,
        (* within-tensor contraction (+ rearrange) is exactly the Massage engine *)
        EinstoffMassage[desc, tensors, bindings, TraceAction -> traceAction,
          "Targeting" -> targeting],
      AnyTrue[opAtoms, ! DuplicateFreeQ[DeleteCases[#, _Integer]] &],
        (Message[Einstoff::unsupp,
          "einsum with a within-operand repeated index across multiple tensors is \
not supported yet (contract that tensor on its own first)"];
         $Failed),
      True,
        (* cross-tensor contraction is the Dot (Times/Plus) fold *)
        EinstoffDot[desc, tensors, bindings, TraceAction -> traceAction,
          "Targeting" -> targeting]]
  ];
