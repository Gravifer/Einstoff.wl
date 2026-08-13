(* ::Package:: *)

(* Reduce path: Einstoff[ArrayReduce] / EinstoffReduce (einx reduction ops /
   einops.reduce).  The reducer is curried into the operator —
   Einstoff[ArrayReduce][reducer][desc, tensors, bindings] — so it reads like the
   einx entry points (sum/mean/…).  The rearrange pipeline with a reduction
   inserted after the decompose step: axes present on the LHS but absent on the
   RHS are reduced away with the reducer via ArrayReduce, then the surviving axes
   are permuted/recomposed exactly as in EinstoffMassage.

   NB the curried form means desc is NOT held (a hold attribute cannot survive a
   compound head, EinstoffReduce[reducer][…]) — and that is fine, even useful:
   Pattern holds each blank `name_` and RuleDelayed (`:>`) holds the RHS, so only
   a *bare* reference whose symbol is globally bound gets substituted; a symbol
   bound to an integer then reads as a literal dimension, and anything not a valid
   size is rejected by the existing satisfiability checks (cf. the uniform "desc is
   an ordinary expression" convention — no operator holds desc).

   Targeted axes are the einx way to mark the reduced axes (SPEC
   5.2, ex 5); a bare dropped axis is the einops way (`a b -> a`) — both reduce
   here, since the operator is unambiguously a reduction.  A targeted axis
   *kept* on the RHS is the feed-to-elementary-op path (not reduction), rejected.
   An output-only axis is repetition (SPEC 5.5) — reduce, then broadcast it on
   through the shared execution plan (e.g. einx.sum("a [b] -> a c", x, c=3)). *)

PackageScoped[{EinstoffReduce}]

EinstoffReduce::usage =
  "EinstoffReduce[reducer][desc, tensors, bindings] realizes a reduction (einx \
reduction ops / einops.reduce) of a single tensor: axes present on the LHS but \
absent on the RHS are reduced away with reducer (a function such as Total/Mean/\
Max, or a name like \"sum\"/\"mean\"/\"max\") via ArrayReduce, and the surviving \
axes are permuted/recomposed as in EinstoffMassage. Targeted axes mark \
the einx reduction style; a bare dropped axis is the einops style.";

Einstoff[ArrayReduce] := EinstoffReduce;
Einstoff["Reduce"] := EinstoffReduce;

Options[EinstoffReduce] = {TraceAction -> None, "Targeting" -> Automatic};

(* Resolve a reducer spec to a list-reducing function.  Accepts a raw function
   (Total, Mean, Max, Min, ...) as-is, or a convenience string matched
   case-insensitively.  The string set covers every einx reduction op
   (https://einx.readthedocs.io/en/stable/api/operations/reduction.html); each
   reducer receives the flat list of elements being combined (ArrayReduce hands
   f the combined slice as one vector), so list-level definitions suffice.  var
   and std are *population* (ddof = 0, matching numpy/einx) — deliberately NOT
   WL's sample-based Variance/StandardDeviation.  any/all test "nonzero". *)
reduceFunction[s_String] := Replace[ToLowerCase[s], {
  "sum" | "total" | "add" -> Total,
  "mean" | "average" -> Mean,
  "max" -> Max, "min" -> Min,
  "prod" | "product" | "times" -> (Times @@ # &),
  "var" | "variance" -> (Mean[(# - Mean[#])^2] &),
  "std" | "stddev" -> (Sqrt[Mean[(# - Mean[#])^2]] &),
  "count_nonzero" | "countnonzero" -> (Total[Unitize[#]] &),
  "any" -> (AnyTrue[#, # != 0 &] &),
  "all" -> (AllTrue[#, # != 0 &] &),
  "logsumexp" | "lse" -> (Max[#] + Log[Total[Exp[# - Max[#]]]] &),
  (* An unknown string is a typo, not a function: flag it so the caller rejects
     it loudly (otherwise it would be applied as `"name"[slice]` -> garbage). *)
  _ :> Missing["UnknownReducer", s]}];
reduceFunction[f_] := f;

(* Curried: Einstoff[ArrayReduce][reducer] is the operator, applied to
   [desc, tensors, bindings]. A subvalue of EinstoffReduce. *)
EinstoffReduce[reducerSpec_][desc_, tensors_, bindings_List : {},
    opts : OptionsPattern[EinstoffReduce]] :=
  Module[{reducer = reduceFunction[reducerSpec], targeting, planned},
    targeting = einCatch[validateTargetingOption[
      OptionValue[EinstoffReduce, {opts}, "Targeting"]]];
    Which[
      targeting === $Failed, $Failed,
      MissingQ[reducer],
        Message[Einstoff::unsupp,
          "unknown reducer name \"" <> ToString[reducerSpec] <> "\""];
        $Failed,
      True,
        planned = tryReduceIRPlan[Hold[desc], tensors, bindings, reducer, targeting,
          OptionValue[EinstoffReduce, {opts}, TraceAction]];
        If[plannerFailureQ[planned], reportPlannerFailure[planned], planned]
    ]
  ];
