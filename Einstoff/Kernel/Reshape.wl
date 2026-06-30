(* ::Package:: *)

(* Massage — the permissive single-tensor ("univalent") structural engine
   (einx.id / einops.rearrange and friends).  It performs: permute + split + merge;
   repetition (an output-only axis broadcast, SPEC 5.5); direct sum (CirclePlus,
   delegated to the DirectSum path); and within-tensor *pairwise* contraction — a
   name repeated in the input and dropped on the output is summed over its coincident
   slots (the einsum-within-one-tensor case, e.g. the Ricci trace R^a_bad -> R_bd),
   via selfContract.

   This is the engine the guarded entrances delegate to: Einstoff["Massage"] is it,
   ungated.  (Increment 2 adds the guards: Einstoff[ArrayReshape] = pure-bijective,
   Einstoff["ArrayContract"] = no-repetition, Einstoff["einsum"] = pairwise contraction
   composing the cross-tensor Dot fold.)  A future cross-tensor backend parallel to
   this univalent engine is sketched as EinstoffTandem (see SPEC §9 / the design note).

   Sizing uses EinstoffMatch directly rather than EinstoffShapes: a within-tensor
   repeated index must be allowed here, whereas EinstoffShapes' axis-uniqueness check
   rejects a repeated name to protect the reduce / map / pure-reshape paths that cannot
   handle it.  Shared helpers (descParts, rearrangeAtoms, atomSize, selfContract,
   materializeOutput) live in Lowering.wl. *)

PackageExported[{EinstoffMassage}]

EinstoffMassage::usage =
  "EinstoffMassage[desc, tensors, bindings] is the permissive single-tensor \
structural engine: rearrange/split/merge, repetition (an output-only axis), direct \
sum, and within-tensor pairwise contraction (a repeated, dropped input axis is summed \
over its coincident slots). The named entrances (Einstoff[ArrayReshape], \
Einstoff[\"ArrayContract\"], Einstoff[\"einsum\"]) are guards that delegate here. \
desc is not held.";

Einstoff["Massage"] := EinstoffMassage;
(* Permissive aliases — kept until the guarded Einstoff[ArrayReshape] lands. *)
Einstoff[ArrayReshape] := EinstoffMassage;
Einstoff["Reshape"] := EinstoffMassage;
Einstoff["Rearrange"] := EinstoffMassage;

(* desc is NOT held (uniform convention): Pattern holds each binding `name_` and `:>`
   holds the RHS, so only a bare reference to a globally bound symbol is substituted. *)
EinstoffMassage[desc_, tensors_, bindings_List : {}] :=
  Module[{parts, lhs, rhs, m, env, lhsAtoms, rhsAtoms, sc, xc, atomsc, result},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;
    (* Direct sum: einx folds `+` into id. CirclePlus on the RHS is concatenation,
       on the LHS splitting — delegate either way. *)
    If[hasCirclePlus[rhs], Return[directSumConcat[desc, tensors, bindings]]];
    If[hasCirclePlus[lhs], Return[directSumSplit[desc, tensors, bindings]]];
    If[! MatchQ[tensors, {__}],
      Message[Einstoff::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[Einstoff::unsupp,
        "Massage lowering takes exactly one input and one output tensor \
(cross-tensor contraction is a separate path)"];
      Return[$Failed]];

    (* Bind axis sizes.  EinstoffMatch (not EinstoffShapes) so a within-tensor
       repeated index is allowed — unify binds it from the first occurrence and
       enforces equality on the second (which is exactly the contraction's validity). *)
    m = EinstoffMatch[lhs, Dimensions /@ tensors, bindings];
    If[! TrueQ[m["ok"]],
      Message[Einstoff::unsat, m["reason"]]; Return[$Failed]];
    env = m["env"];

    lhsAtoms = Catch[Join @@ (rearrangeAtoms /@ First[lhs])];
    rhsAtoms = Catch[Join @@ (rearrangeAtoms /@ First[rhs])];
    If[lhsAtoms === $Failed || rhsAtoms === $Failed, Return[$Failed]];
    (* An axis name may not repeat on the output (no einsum spelling for it). *)
    If[! DuplicateFreeQ[DeleteCases[rhsAtoms, _Integer]],
      Message[Einstoff::unsupp,
        "an axis name repeats on the output — output axes must be distinct"];
      Return[$Failed]];

    (* Self-contract a within-tensor repeated (dropped) index; identity otherwise. *)
    sc = Catch[selfContract[First[tensors], lhsAtoms, rhsAtoms, env]];
    If[sc === $Failed, Return[$Failed]];
    {xc, atomsc} = sc;
    (* Every surviving (non-contracted) input axis must be carried to the output.  A
       named axis is carried iff it appears on the RHS.  A literal input axis of size > 1
       cannot be carried (output literals are fresh broadcast axes — cf. einx rejecting
       'a 2 -> a 2'), so a surviving size-(>1) input literal is a drop.  A size-1 literal
       is a unit axis (squeezed by materializeOutput), so it is allowed.  A dropped
       size-(>1) axis is reduce, not rearrange/contract. *)
    If[AnyTrue[atomsc, ! MemberQ[rhsAtoms, #] && atomSize[#, env] > 1 &],
      Message[Einstoff::unsupp,
        "an input axis of size > 1 is dropped on the output — that is reduce, not \
rearrange/contract (a size-1 unit axis is squeezed; a literal size > 1 axis has no \
carryable identity — name it); use Einstoff[ArrayReduce]"];
      Return[$Failed]];

    result = Catch[materializeOutput[xc, atomsc, First[rhs], env]];
    If[result === $Failed,
      Message[Einstoff::unsat,
        "an output axis size is unbound or not a positive integer (a repeated axis \
needs a positive binding)"];
      Return[$Failed]];
    result
  ];
