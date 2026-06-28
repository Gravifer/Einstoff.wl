(* ::Package:: *)

(* Reduce path: Einstoff[ArrayReduce] / EinstoffReduce (einx reduction ops /
   einops.reduce).  The rearrange pipeline with a reduction inserted after the
   decompose step: axes present on the LHS but absent on the RHS are reduced
   away with a user reducer (option Reducer, default Total) via ArrayReduce,
   then the surviving axes are permuted/recomposed exactly as in EinstoffRearrange.

   Bracketed (`Slot[...]`) axes are the einx way to mark the reduced axes (SPEC
   5.2, ex 5); a bare dropped axis is the einops way (`a b -> a`) — both reduce
   here, since the operator is unambiguously a reduction.  A bracketed axis
   *kept* on the RHS is the feed-to-elementary-op path (not reduction), rejected.
   An output-only axis is repetition (SPEC 5.5) — reduce, then broadcast it on,
   via the shared materializeOutput (e.g. einx.sum("a [b] -> a c", x, c=3)).

   Shared helpers (descParts, reduceAtoms, rearrangeAtoms, atomSize,
   materializeOutput) live in Lowering.wl. *)

PackageExported[{EinstoffReduce}]

EinstoffReduce::usage =
  "EinstoffReduce[desc, tensors, bindings] realizes a reduction (einx reduction \
ops / einops.reduce) of a single tensor: axes present on the LHS but absent on \
the RHS are reduced away with the Reducer option (default Total) via \
ArrayReduce, and the surviving axes are permuted/recomposed as in \
EinstoffRearrange. Bracketed (Slot) axes mark the einx reduction style; a bare \
dropped axis is the einops style. desc is held.";

Einstoff[ArrayReduce] := EinstoffReduce;
Einstoff["Reduce"] := EinstoffReduce;

(* Resolve a reducer spec to a list-reducing function.  Accepts a raw function
   (Total, Mean, Max, Min, ...) as-is, or a convenience string matched
   case-insensitively (einops uses lowercase: "sum", "mean", "max", ...). *)
reduceFunction[s_String] := Replace[ToLowerCase[s], {
  "sum" | "total" | "add" -> Total,
  "mean" | "average" -> Mean,
  "max" -> Max, "min" -> Min,
  "prod" | "product" | "times" -> (Times @@ # &),
  _ -> s}];
reduceFunction[f_] := f;

SetAttributes[EinstoffReduce, HoldFirst];

(* The reducer is a *positional* argument, not an option (avoid OptionsPattern
   clustering).  bindings is List-guarded, so a non-List 3rd argument is taken
   as the reducer — giving both Einstoff[ArrayReduce][desc, tensors, reducer]
   and Einstoff[ArrayReduce][desc, tensors, bindings, reducer], with desc still
   held (a hold attribute does not survive currying through a compound head). *)
EinstoffReduce[desc_, tensors_, bindings_List : {}, reducerSpec_ : Total] :=
  Module[{parts, lhs, rhs, inShapes, shp, env, x, reducer,
          lhsTagged, lhsAtoms, lhsBr, rhsAtoms, reducedPos, keptOrder,
          decompDims, xr, xred, result},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;
    If[! MatchQ[tensors, {__}],
      Message[Einstoff::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[Einstoff::unsupp,
        "ArrayReduce lowering supports exactly one input and one output tensor"];
      Return[$Failed]];

    reducer = reduceFunction[reducerSpec];

    inShapes = Dimensions /@ tensors;
    shp = EinstoffShapes[desc, inShapes, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    (* Decompose: LHS bracket-aware (tagged), RHS plain (reuse rearrangeAtoms). *)
    lhsTagged = Catch[Join @@ Table[reduceAtoms[t, False], {t, First[lhs]}]];
    If[lhsTagged === $Failed, Return[$Failed]];
    rhsAtoms = Catch[Join @@ Table[rearrangeAtoms[t], {t, First[rhs]}]];
    If[rhsAtoms === $Failed, Return[$Failed]];
    lhsAtoms = lhsTagged[[All, 1]]; lhsBr = lhsTagged[[All, 2]];

    (* Reduced atoms = LHS atoms absent on RHS (1-indexed positions).  RHS-only
       atoms are not reduced — they are repetition axes, materialized below. *)
    reducedPos = Select[Range@Length[lhsAtoms], ! MemberQ[rhsAtoms, lhsAtoms[[#]]] &];

    (* A bracketed axis kept on the RHS is the feed-to-elementary-op path, not a
       reduction (SPEC 5.2) — reject rather than silently reduce/keep wrong. *)
    If[AnyTrue[Range@Length[lhsAtoms],
        lhsBr[[#]] && MemberQ[rhsAtoms, lhsAtoms[[#]]] &],
      Message[Einstoff::unsupp,
        "a bracketed axis is kept on the output — feeding an axis whole to an \
elementary op is a separate path, not reduction"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = Catch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[Einstoff::unsat, "an input axis size is unbound"];
      Return[$Failed]];

    xr = ArrayReshape[x, decompDims];
    xred = If[reducedPos === {}, xr, ArrayReduce[reducer, xr, reducedPos]];

    (* Surviving atoms, in their LHS-relative order (= xred's axis order); then
       materialize repeats, permute to RHS order, and recompose. *)
    keptOrder = Delete[lhsAtoms, List /@ reducedPos];
    result = Catch[materializeOutput[xred, keptOrder, First[rhs], env]];
    If[result === $Failed,
      Message[Einstoff::unsat,
        "an output axis size is unbound (a repeated axis needs a binding)"];
      Return[$Failed]];
    result
  ];
