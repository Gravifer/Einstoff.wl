(* ::Package:: *)

(* Einstoff lowering — turning a satisfiable description into actual array
   operations.  Two paths are implemented so far:

   * Rearrange / reshape (einx.id / einops.rearrange) — permute + split + merge
     with no axis introduced or dropped.  Lowers to the native trio

         ArrayReshape  (decompose composites into atomic axes)
         Transpose     (permute atomic axes from LHS order to RHS order)
         ArrayReshape  (recompose composites on the output side)

   * Reduce (einx reduction ops / einops.reduce) — the rearrange pipeline with a
     reduction inserted after the decompose step: axes that appear on the LHS but
     not the RHS are reduced away with a user reducer (option Reducer, default
     Total) via the native ArrayReduce, then the surviving axes are permuted and
     recomposed exactly as in rearrange.  Bracketed (`Slot[...]`) axes are the
     einx way to mark the reduced axes (SPEC 5.2, ex 5); a bare dropped axis is
     the einops way (`a b -> a`) — both reduce here, since the operator is
     unambiguously a reduction.  A bracketed axis *kept* on the RHS is the
     feed-to-elementary-op path (not reduction) and is rejected.

   Out of scope still: variable-arity bracket ellipses (`Slot[___]`, SPEC ex 6),
   CirclePlus direct sums, repeat (RHS-only axes), and multi-tensor contraction /
   broadcast — separate code paths (SPEC 5.2, 9).  Anything outside the supported
   subset is rejected loudly rather than mis-compiled.

   Public surface: `Einstoff[ArrayReshape]` and `Einstoff[ArrayReduce]` are the
   operator forms demanded by CLAUDE.md; they resolve to
   `EinstoffRearrange[...]` / `EinstoffReduce[...]`. *)

PackageExported[{
  Einstoff,
  EinstoffRearrange,
  EinstoffReduce
}]

Einstoff::usage =
  "Einstoff[op] yields the Einstoff operator implementing op. \
Einstoff[ArrayReshape] gives the rearrange/reshape operator, applied as \
Einstoff[ArrayReshape][desc, tensors, bindings].";

EinstoffRearrange::usage =
  "EinstoffRearrange[desc, tensors, bindings] realizes a pure \
rearrange/reshape (einx.id / einops.rearrange) of a single tensor: it \
matches desc against the tensor shape to bind axis sizes, then emits \
ArrayReshape/Transpose/ArrayReshape to produce the output array. desc is \
held.";

EinstoffRearrange::unsupp = "`1`";
EinstoffRearrange::unsat =
  "description is not satisfiable against the given tensor(s): `1`";

EinstoffReduce::usage =
  "EinstoffReduce[desc, tensors, bindings] realizes a reduction (einx reduction \
ops / einops.reduce) of a single tensor: axes present on the LHS but absent on \
the RHS are reduced away with the Reducer option (default Total) via \
ArrayReduce, and the surviving axes are permuted/recomposed as in \
EinstoffRearrange. Bracketed (Slot) axes mark the einx reduction style; a bare \
dropped axis is the einops style. desc is held.";

EinstoffReduce::unsupp = "`1`";
EinstoffReduce::unsat =
  "description is not satisfiable against the given tensor(s): `1`";

(* ------------------------------------------------------------------ *)
(* Operator dispatch.                                                  *)
(* ------------------------------------------------------------------ *)

Einstoff[ArrayReshape] := EinstoffRearrange;
Einstoff["Reshape"] := EinstoffRearrange;
Einstoff["Rearrange"] := EinstoffRearrange;

Einstoff[ArrayReduce] := EinstoffReduce;
Einstoff["Reduce"] := EinstoffReduce;

(* ------------------------------------------------------------------ *)
(* Atomic-axis decomposition of one dimension term.                    *)
(* A "rearrange atom" is an axis that survives the transform unchanged  *)
(* (only its position / grouping changes).  Composites expand to their  *)
(* factors in order; everything else in the rearrange subset is a       *)
(* single atom.  Out-of-subset heads Throw[$Failed] (caught by caller). *)
(* ------------------------------------------------------------------ *)

rearrangeAtoms[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]]] := {s};
rearrangeAtoms[s_Symbol] := {s};
rearrangeAtoms[n_Integer] := {n};
rearrangeAtoms[CircleTimes[fs__]] := Join @@ (rearrangeAtoms /@ {fs});
rearrangeAtoms[other_] := (
  Message[EinstoffRearrange::unsupp,
    "unsupported term in ArrayReshape lowering: " <>
      ToString[other, InputForm] <>
      " (brackets, direct sums and ellipses are not part of the rearrange \
subset yet)"];
  Throw[$Failed]);

atomSize[n_Integer, _] := n;
atomSize[s_, env_] := Lookup[env, s, Throw[$Failed]];

(* ------------------------------------------------------------------ *)
(* The rearrange operator.                                             *)
(* desc reaches us held (HoldFirst); pattern substitution injects the  *)
(* actual rule wherever `desc` appears, so Extract[Hold[desc], ...] and *)
(* the EinstoffShapes call below both see the real lhs :> rhs.          *)
(* ------------------------------------------------------------------ *)

SetAttributes[EinstoffRearrange, HoldFirst];

EinstoffRearrange[desc_, tensors_, bindings_ : {}] :=
  Module[{lhs, heldRhs, rhs, inShapes, shp, env, x,
          lhsAtoms, rhsAtoms, decompDims, srcOrder, xr, xt, outDims},
    If[! MatchQ[Hold[desc], Hold[_Rule | _RuleDelayed]],
      Message[EinstoffRearrange::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    lhs = Extract[Hold[desc], {1, 1}];
    heldRhs = Extract[Hold[desc], {1, 2}, Hold];
    rhs = ReleaseHold[heldRhs];
    If[! MatchQ[tensors, {__}],
      Message[EinstoffRearrange::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[EinstoffRearrange::unsupp,
        "ArrayReshape lowering currently supports exactly one input and one \
output tensor (multi-tensor contraction/broadcast is a separate path)"];
      Return[$Failed]];

    inShapes = Dimensions /@ tensors;
    shp = EinstoffShapes[desc, inShapes, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[EinstoffRearrange::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    {lhsAtoms, rhsAtoms} = Catch[
      {Join @@ (rearrangeAtoms /@ First[lhs]),
       Join @@ (rearrangeAtoms /@ First[rhs])}];
    If[lhsAtoms === $Failed, Return[$Failed]];
    If[Sort[lhsAtoms] =!= Sort[rhsAtoms],
      Message[EinstoffRearrange::unsupp,
        "axes are not a permutation between input and output — an axis is \
introduced or dropped, which is repeat/reduce, not rearrange"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = Catch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[EinstoffRearrange::unsat, "an input axis size is unbound"];
      Return[$Failed]];
    srcOrder = Flatten[FirstPosition[lhsAtoms, #] & /@ rhsAtoms];
    outDims = Catch[
      (Times @@ (atomSize[#, env] & /@ rearrangeAtoms[#])) & /@ First[rhs]];
    If[outDims === $Failed, Return[$Failed]];

    xr = ArrayReshape[x, decompDims];
    xt = If[Length[srcOrder] <= 1, xr,
            Transpose[xr, InversePermutation[srcOrder]]];
    ArrayReshape[xt, outDims]
  ];

(* ================================================================== *)
(* Reduce path: Einstoff[ArrayReduce] / EinstoffReduce.                *)
(* ================================================================== *)

(* Bracket-aware atomic decomposition of one LHS term.  Like rearrangeAtoms,
   but unwraps Slot[...] brackets (marking the contained atoms as bracketed)
   and returns {atom, bracketedQ} pairs.  NB Table/List@@ rather than `&/@`:
   a factor can be Slot[...], and routing it through an anonymous Function
   would reinterpret an integer Slot as that function's argument slot (SPEC
   7.2).  Variable-arity ellipses are out of scope and Throw. *)
reduceAtoms[t_, br_ : False] :=
  Which[
    MatchQ[t, Verbatim[Pattern][_Symbol, Verbatim[Blank[]]]], {{t[[1]], br}},
    Head[t] === Symbol, {{t, br}},
    IntegerQ[t], {{t, br}},
    Head[t] === CircleTimes,
      Join @@ Table[reduceAtoms[f, br], {f, List @@ t}],
    Head[t] === Slot,
      Join @@ Table[reduceAtoms[f, True], {f, List @@ t}],
    True,
      (Message[EinstoffReduce::unsupp,
        "unsupported term in ArrayReduce lowering: " <>
          ToString[t, InputForm] <> " (CirclePlus and variable-arity bracket \
ellipses are not part of the reduce subset yet)"];
       Throw[$Failed])];

(* Resolve the Reducer option value to a list-reducing function.  Accepts a
   raw function (Total, Mean, Max, Min, ...) or a few convenience strings. *)
reduceFunction[f_] := f /. {
  "Sum" | "Total" | "Add" :> Total,
  "Mean" | "Average" :> Mean,
  "Max" :> Max, "Min" :> Min,
  "Prod" | "Product" | "Times" :> Function[l, Times @@ l]};

Options[EinstoffReduce] = {Reducer -> Total};

SetAttributes[EinstoffReduce, HoldFirst];

(* bindings is constrained to a List so that a trailing Reducer -> … option is
   never mis-captured as the bindings argument (CLAUDE.md). *)
EinstoffReduce[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  Module[{lhs, heldRhs, rhs, inShapes, shp, env, x, reducer,
          lhsTagged, lhsAtoms, lhsBr, rhsAtoms, reducedPos, keptOrder,
          decompDims, xr, xred, srcOrder, xt, outDims},
    If[! MatchQ[Hold[desc], Hold[_Rule | _RuleDelayed]],
      Message[EinstoffReduce::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    lhs = Extract[Hold[desc], {1, 1}];
    heldRhs = Extract[Hold[desc], {1, 2}, Hold];
    rhs = ReleaseHold[heldRhs];
    If[! MatchQ[tensors, {__}],
      Message[EinstoffReduce::unsupp,
        "tensors must be a non-empty list of arrays"]; Return[$Failed]];
    If[! MatchQ[lhs, {_List}] || ! MatchQ[rhs, {_List}] || Length[tensors] =!= 1,
      Message[EinstoffReduce::unsupp,
        "ArrayReduce lowering currently supports exactly one input and one \
output tensor"];
      Return[$Failed]];

    reducer = reduceFunction[OptionValue[EinstoffReduce, {opts}, Reducer]];

    inShapes = Dimensions /@ tensors;
    shp = EinstoffShapes[desc, inShapes, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[EinstoffReduce::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    (* Decompose: LHS bracket-aware (tagged), RHS plain (reuse rearrangeAtoms). *)
    lhsTagged = Catch[Join @@ Table[reduceAtoms[t, False], {t, First[lhs]}]];
    If[lhsTagged === $Failed, Return[$Failed]];
    rhsAtoms = Catch[Join @@ Table[rearrangeAtoms[t], {t, First[rhs]}]];
    If[rhsAtoms === $Failed, Return[$Failed]];
    lhsAtoms = lhsTagged[[All, 1]]; lhsBr = lhsTagged[[All, 2]];

    (* Every RHS atom must come from the (kept) LHS — a new output axis would be
       repeat, not reduce. *)
    If[! SubsetQ[lhsAtoms, rhsAtoms],
      Message[EinstoffReduce::unsupp,
        "an output axis is not present on the input — introducing an axis is \
repeat, not reduce"];
      Return[$Failed]];

    (* Reduced atoms = LHS atoms absent on RHS (1-indexed positions). *)
    reducedPos = Select[Range@Length[lhsAtoms], ! MemberQ[rhsAtoms, lhsAtoms[[#]]] &];

    (* A bracketed axis kept on the RHS is the feed-to-elementary-op path, not a
       reduction (SPEC 5.2) — reject rather than silently reduce/keep wrong. *)
    If[AnyTrue[Range@Length[lhsAtoms],
        lhsBr[[#]] && MemberQ[rhsAtoms, lhsAtoms[[#]]] &],
      Message[EinstoffReduce::unsupp,
        "a bracketed axis is kept on the output — feeding an axis whole to an \
elementary op is a separate path, not reduction"];
      Return[$Failed]];

    x = First[tensors];
    decompDims = Catch[atomSize[#, env] & /@ lhsAtoms];
    If[decompDims === $Failed,
      Message[EinstoffReduce::unsat, "an input axis size is unbound"];
      Return[$Failed]];

    xr = ArrayReshape[x, decompDims];
    xred = If[reducedPos === {}, xr, ArrayReduce[reducer, xr, reducedPos]];

    (* All axes reduced -> scalar; nothing left to permute or recompose. *)
    If[Length[reducedPos] === Length[lhsAtoms], Return[xred]];

    (* Surviving atoms, in their LHS-relative order (= xred's axis order). *)
    keptOrder = Delete[lhsAtoms, List /@ reducedPos];
    srcOrder = Flatten[FirstPosition[keptOrder, #] & /@ rhsAtoms];
    xt = If[Length[srcOrder] <= 1, xred,
            Transpose[xred, InversePermutation[srcOrder]]];
    outDims = Catch[
      (Times @@ (atomSize[#, env] & /@ rearrangeAtoms[#])) & /@ First[rhs]];
    If[outDims === $Failed, Return[$Failed]];
    ArrayReshape[xt, outDims]
  ];
