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
   An output-only axis is repetition (SPEC 5.5) — reduce, then broadcast it on,
   via the shared materializeOutput (e.g. einx.sum("a [b] -> a c", x, c=3)).

   Shared helpers (descParts, reduceAtoms, rearrangeAtoms, atomSize,
   materializeOutput) live in Lowering.wl. *)

PackageExported[{EinstoffReduce}]

EinstoffReduce::usage =
  "EinstoffReduce[reducer][desc, tensors, bindings] realizes a reduction (einx \
reduction ops / einops.reduce) of a single tensor: axes present on the LHS but \
absent on the RHS are reduced away with reducer (a function such as Total/Mean/\
Max, or a name like \"sum\"/\"mean\"/\"max\") via ArrayReduce, and the surviving \
axes are permuted/recomposed as in EinstoffMassage. Targeted axes mark \
the einx reduction style; a bare dropped axis is the einops style.";

Einstoff[ArrayReduce] := EinstoffReduce;
Einstoff["Reduce"] := EinstoffReduce;

Options[EinstoffReduce] = {TraceAction -> None};

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
    opts : OptionsPattern[EinstoffReduce]] := withAxisScope @
  Module[{parts, lhs, rhs, inShapes, shp, env, x, reducer,
          lhsTagged, lhsAtoms, lhsBr, rhsAtoms, reducedPos, keptOrder,
          decompDims, xr, xred, result, traceAction},
    traceAction = OptionValue[EinstoffReduce, {opts}, TraceAction];
    parts = descParts[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    {lhs, rhs} = parts;
    If[! MatchQ[tensors, {__}],
      Message[Einstoff::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[Einstoff::unsupp,
        "ArrayReduce lowering supports exactly one input and one output tensor"];
      Return[$Failed]];

    reducer = reduceFunction[reducerSpec];
    If[MissingQ[reducer],
      Message[Einstoff::unsupp,
        "unknown reducer name \"" <> ToString[reducerSpec] <> "\"; use one of \
sum/mean/var/std/prod/count_nonzero/any/all/max/min/logsumexp, or pass a function"];
      Return[$Failed]];

    (* A name repeated within an input shape is within-tensor contraction, which
       ArrayReduce does not do (the shape resolver no longer rejects it — that policy is
       now per-operator).  Reject here before lowering silently mis-reduces both slots. *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> axisDisplayName[firstDuplicateAxis[lhs]] <> " repeats within an input \
shape; ArrayReduce does not contract a repeated axis. Within-tensor contraction is \
Einstoff[\"ArrayContract\"] / Einstoff[\"einsum\"]"];
      Return[$Failed]];

    inShapes = Dimensions /@ tensors;
    shp = EinstoffShapes[desc, inShapes, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    (* Decompose: LHS bracket-aware (tagged), RHS plain (reuse rearrangeAtoms). *)
    lhsTagged = einCatch[Join @@ Table[reduceAtoms[t, False], {t, First[lhs]}]];
    If[lhsTagged === $Failed, Return[$Failed]];
    rhsAtoms = einCatch[Join @@ Table[rearrangeAtoms[t], {t, First[rhs]}]];
    If[rhsAtoms === $Failed, Return[$Failed]];
    lhsAtoms = lhsTagged[[All, 1]]; lhsBr = lhsTagged[[All, 2]];

    (* Reduced atoms = LHS atoms absent on RHS (1-indexed positions).  RHS-only
       atoms are not reduced — they are repetition axes, materialized below. *)
    reducedPos = Select[Range@Length[lhsAtoms], ! MemberQ[rhsAtoms, lhsAtoms[[#]]] &];

    (* A targeted axis kept on the RHS is the feed-to-elementary-op path, not a
       reduction (SPEC 5.2) — reject rather than silently reduce/keep wrong. *)
    If[AnyTrue[Range@Length[lhsAtoms],
        lhsBr[[#]] && MemberQ[rhsAtoms, lhsAtoms[[#]]] &],
      Message[Einstoff::unsupp,
        "a targeted axis is kept on the output; feeding an axis whole to an \
elementary op (softmax/flip/sort/…) is the Einstoff[Map][f] path, not reduction"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = einCatch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[Einstoff::unsat, "an input axis size is unbound"];
      Return[$Failed]];

    xr = reshapeTo[x, decompDims];     (* scalar-safe (decompDims may be {}) *)
    xred = If[reducedPos === {}, xr, ArrayReduce[reducer, xr, reducedPos]];

    (* Surviving atoms, in their LHS-relative order (= xred's axis order); then
       materialize repeats, permute to RHS order, and recompose. *)
    keptOrder = Delete[lhsAtoms, List /@ reducedPos];
    With[{xred0 = xred, keptOrder0 = keptOrder, rhs0 = First[rhs], env0 = env},
      result = einCatch[
        traceReturn[materializeOutput[xred0, keptOrder0, rhs0, env0], traceAction]]];
    If[result === $Failed,
      Message[Einstoff::unsat,
        "an output axis size is unbound (a repeated axis needs a binding)"];
      Return[$Failed]];
    result
  ];
