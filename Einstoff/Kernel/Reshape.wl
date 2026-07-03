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

   Sizing uses EinstoffMatch directly rather than EinstoffShapes: a within-tensor
   repeated index must be allowed here (unification binds it once and enforces equality),
   and EinstoffMatch is the bare resolver with no operator policy.  EinstoffShapes only
   adds the universal output-axis-uniqueness invariant, which this path does not need —
   the reduce / map / pure-reshape paths that cannot handle a repeated INPUT axis reject it
   themselves (distinctAxesQ), so that policy no longer lives in EinstoffShapes.  Shared
   helpers (descParts, rearrangeAtoms, atomSize, selfContract, materializeOutput) live in
   Lowering.wl. *)

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
(Einstoff[ArrayReshape]): permute/split/merge and unit-axis insert/squeeze only — an \
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

(* The three entrances are one engine under three policies, differing only in which
   non-bijective features they admit (element counts, single tensor):
     All        (EinstoffMassage)  — permissive: also repetition and direct sum
     "Reshape"  (EinstoffReshape)  — bijective: count-preserving reindexing only
     "Contract" (EinstoffContract) — no repetition; adds within-tensor contraction
   Keeping the policy inside the shared core (massageCore) means the guards are pure
   intent declarations and the classification of a rejected desc ("wrong guard" vs
   "wrong lowering") lives at the exact point each feature becomes known. *)
EinstoffMassage[desc_, tensors_, bindings_List : {}]  := massageCore[desc, tensors, bindings, All];
EinstoffReshape[desc_, tensors_, bindings_List : {}]  := massageCore[desc, tensors, bindings, "Reshape"];
EinstoffContract[desc_, tensors_, bindings_List : {}] := massageCore[desc, tensors, bindings, "Contract"];

(* desc is NOT held (uniform convention): Pattern holds each binding `name_` and `:>`
   holds the RHS, so only a bare reference to a globally bound symbol is substituted. *)
massageCore[desc_, tensors_, bindings_List, policy_] := withAxisScope @
  Module[{parts, lhs, rhs, m, env, lhsAtoms, rhsAtoms, sc, xc, atomsc, result,
          outOnly, repeated, contracted},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;
    (* Direct sum: einx folds `+` into id. CirclePlus on the RHS is concatenation, on
       the LHS splitting.  Only the permissive engine admits it; the bijective / contract
       guards treat a direct sum as a structural join/split that belongs elsewhere. *)
    If[hasCirclePlus[rhs] || hasCirclePlus[lhs],
      If[policy =!= All,
        Message[Einstoff::unsupp,
          "a direct sum (CirclePlus) is a structural join/split, not a " <>
          If[policy === "Reshape", "bijective reshape", "within-tensor contraction"] <>
          "; use Einstoff[Join]/[Split] or the permissive Einstoff[\"Massage\"]"];
        Return[$Failed]];
      If[hasCirclePlus[rhs], Return[directSumConcat[desc, tensors, bindings]]];
      Return[directSumSplit[desc, tensors, bindings]]];
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

    lhsAtoms = einCatch[Join @@ (rearrangeAtoms /@ First[lhs])];
    rhsAtoms = einCatch[Join @@ (rearrangeAtoms /@ First[rhs])];
    If[lhsAtoms === $Failed || rhsAtoms === $Failed, Return[$Failed]];
    (* An axis name may not repeat on the output (no einsum spelling for it). *)
    If[! DuplicateFreeQ[DeleteCases[rhsAtoms, _Integer]],
      Message[Einstoff::unsupp,
        "an axis name repeats on the output — output axes must be distinct"];
      Return[$Failed]];

    (* Self-contract a within-tensor repeated (dropped) index; identity otherwise. *)
    sc = einCatch[selfContract[First[tensors], lhsAtoms, rhsAtoms, env]];
    If[sc === $Failed, Return[$Failed]];
    {xc, atomsc} = sc;

    (* Policy gate for the guarded entrances.  With `atomsc` (the surviving input atoms
       after any within-tensor contraction) and the raw output atoms known, classify the
       two non-bijective features and reject those the policy forbids — before the shared
       drop-check / materialization, so the message names the guard, not the lowering:
         contracted — selfContract removed a repeated, dropped input axis (atomsc shrank);
                      forbidden by "Reshape" (bijective), admitted by "Contract".
         repeated   — an output-only atom (not carried from the input) whose size is > 1
                      (or unbound); that is repetition / broadcast, forbidden by both
                      guards.  A size-1 output-only axis is a unit-axis insert (still an
                      element-count-preserving reindexing), so it is NOT flagged. *)
    If[policy =!= All,
      contracted = atomsc =!= lhsAtoms;
      outOnly = Select[rhsAtoms, ! MemberQ[atomsc, #] &];
      repeated = AnyTrue[outOnly,
        With[{s = If[IntegerQ[#], #, Lookup[env, #, Missing[]]]},
          MissingQ[s] || TrueQ[s > 1]] &];
      If[policy === "Reshape" && contracted,
        Message[Einstoff::unsupp,
          "a within-tensor repeated axis is contracted — not a bijective reshape; use \
Einstoff[\"ArrayContract\"] or the permissive Einstoff[\"Massage\"]"];
        Return[$Failed]];
      If[repeated,
        Message[Einstoff::unsupp,
          "an output-only axis of size > 1 is repetition (broadcast), not a " <>
          If[policy === "Reshape", "bijective reshape", "contraction"] <>
          "; use the permissive Einstoff[\"Massage\"]"];
        Return[$Failed]]];

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

    result = einCatch[materializeOutput[xc, atomsc, First[rhs], env]];
    If[result === $Failed,
      Message[Einstoff::unsat,
        "an output axis size is unbound or not a positive integer (a repeated axis \
needs a positive binding)"];
      Return[$Failed]];
    result
  ];
