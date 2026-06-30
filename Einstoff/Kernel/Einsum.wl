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

   Shared helpers (descParts, reduceAtoms, hasCirclePlus) live in Lowering.wl. *)

PackageExported[{EinstoffEinsum}]

EinstoffEinsum::usage =
  "EinstoffEinsum[desc, tensors, bindings] realizes the pairwise-contraction subset \
of einsum: within-tensor contraction (a repeated, dropped index summed over its \
coincident slots) for one tensor, and cross-tensor contraction for several. \
Einstoff[\"einsum\"]. Repetition (a new output axis) and single-index sum-reduction \
are out of scope (use Einstoff[\"Massage\"] / Einstoff[ArrayReduce]).";

Einstoff["einsum"] := EinstoffEinsum;
Einstoff["Einsum"] := EinstoffEinsum;

EinstoffEinsum[desc_, tensors_, bindings_List : {}] :=
  Module[{parts, lhs, rhs, opAtoms, rhsAtoms, allLhs},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
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
    opAtoms = Catch[Table[(Join @@ Table[reduceAtoms[t], {t, shp}])[[All, 1]], {shp, lhs}]];
    rhsAtoms = Catch[Join @@ Table[rearrangeAtoms[t], {t, First[rhs]}]];
    If[opAtoms === $Failed || rhsAtoms === $Failed, Return[$Failed]];

    (* Output atoms must be distinct (np.einsum errors on a repeated output subscript;
       Option B also rejects two equal literal integers). *)
    If[! DuplicateFreeQ[rhsAtoms],
      Message[Einstoff::unsupp,
        "einsum output axes must be distinct (no repeated output subscript)"];
      Return[$Failed]];
    (* einsum has no repetition: every output atom — a named axis OR a literal integer
       immediate — must appear on some input.  A literal output integer not present on
       the input is a broadcast (Reshape.wlt treats output integers as repetition), so
       it is rejected here too. *)
    allLhs = Join @@ opAtoms;
    If[AnyTrue[rhsAtoms, ! MemberQ[allLhs, #] &],
      Message[Einstoff::unsupp,
        "einsum cannot introduce a new output axis (that is repetition / broadcast \
— use Einstoff[\"Massage\"])"];
      Return[$Failed]];

    Which[
      Length[tensors] === 1,
        (* within-tensor contraction (+ rearrange) is exactly the Massage engine *)
        EinstoffMassage[desc, tensors, bindings],
      AnyTrue[opAtoms, ! DuplicateFreeQ[DeleteCases[#, _Integer]] &],
        (Message[Einstoff::unsupp,
          "einsum with a within-operand repeated index across multiple tensors is \
not supported yet (contract that tensor on its own first)"];
         $Failed),
      True,
        (* cross-tensor contraction is the Dot (Times/Plus) fold *)
        EinstoffDot[desc, tensors, bindings]]
  ];
