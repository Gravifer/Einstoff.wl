(* ::Package:: *)

(* Direct-sum path: CirclePlus (einx `+`) — concatenation and splitting along an
   axis.  CirclePlus is a *parentheses* construct (composition level), orthogonal
   to Slot brackets; `(a + b)` is a direct sum, distinct from `(a b)` product
   (CircleTimes) and `[a]` bracket (Slot).

   Two directions (einx is positional, left-to-right — summand i ↔ operand i):

   * Concat — CirclePlus on the RHS: `{op1, …, opk} :> {{ … s1 ⊕ … ⊕ sk … }}`.
     Each operand is aligned to the output shape with the top-level CirclePlus axes
     replaced by one Cartesian summand combination (reusing materializeOutput, so a
     scalar operand or an integer summand broadcasts to fill — einx's
     `b c, -> b (c + 1)` with 42), then the blocks are Join'd along those concat
     axes. IMPLEMENTED.

   * Split — CirclePlus on the LHS: `{{ … a ⊕ b … }} :> {out1, out2, …}`. One input
     is sliced into contiguous Cartesian blocks along the top-level direct-sum axes
     (Take, left-to-right with the last axis varying fastest); each slice is then
     rearranged to its output shape (reusing materializeOutput). Returns a List of
     arrays. IMPLEMENTED.

   Surface: folded into the permissive Einstoff["Massage"] (einx puts `+` in `id`); the
   desc is routed here when it contains a CirclePlus.  The bijective Einstoff[ArrayReshape]
   / no-repetition Einstoff["ArrayContract"] guards reject a direct sum (it is a structural
   join/split, not a reshape/contraction).  Einstoff[Join] and Einstoff[Split] are the same
   machinery under a directional guard (Join: CirclePlus only on the RHS; Split: only on
   the LHS).

   Shared helpers (descParts, rearrangeAtoms, atomSize, materializeOutput,
   hasCirclePlus) live in Lowering.wl. *)

PackageExported[{EinstoffJoin, EinstoffSplit}]

EinstoffJoin::usage =
  "EinstoffJoin[desc, tensors, bindings] concatenates tensors along a direct-sum \
axis (einx `+`): the desc must carry a CirclePlus on the RHS only, e.g. \
{{m_, a_}, {m_, b_}} :> {{m, a \\[CirclePlus] b}}. desc is held.";

EinstoffSplit::usage =
  "EinstoffSplit[desc, tensors, bindings] splits one tensor along a direct-sum \
axis into multiple outputs (einx `+` on the LHS), e.g. \
{{m_, a_ \\[CirclePlus] b_}} :> {{m, a}, {m, b}} returns {arr1, arr2}. desc is held.";

Einstoff[Join] := EinstoffJoin;
Einstoff["Join"] := EinstoffJoin;
Einstoff[Split] := EinstoffSplit;
Einstoff["Split"] := EinstoffSplit;

Options[EinstoffJoin] = {TraceAction -> None};
Options[EinstoffSplit] = {TraceAction -> None};

(* A valid direct-sum summand: an axis name (bare or blank), an
   integer, or a CircleTimes product of those. A targeted direct sum or
   any other head is not supported. Shared by the concat and split handlers. *)
directSumSummandQ[s_] :=
  MatchQ[s, _Symbol | _Integer | Verbatim[Pattern][_Symbol, Verbatim[Blank[]]]] ||
    (Head[s] === CircleTimes && AllTrue[List @@ s, directSumSummandQ]);

directSumJoinBlocks[blocks_List, axes_List, counts_List] :=
  If[axes === {}, First[blocks],
    Module[{chunk, grouped, joined},
      chunk = Times @@ Rest[counts];
      grouped = Partition[blocks, chunk];
      joined = Table[
        directSumJoinBlocks[grouped[[i]], Rest[axes], Rest[counts]],
        {i, Length[grouped]}];
      Join[Sequence @@ joined, First[axes]]]];

directSumJoinHeldBlocks[blocks_List, axes_List, counts_List] :=
  If[axes === {}, First[blocks],
    Module[{chunk, grouped, joined},
      chunk = Times @@ Rest[counts];
      grouped = Partition[blocks, chunk];
      joined = Table[
        directSumJoinHeldBlocks[grouped[[i]], Rest[axes], Rest[counts]],
        {i, Length[grouped]}];
      heldJoin[joined, First[axes]]]];

(* ------------------------------------------------------------------ *)
(* Concat handler.  Called with the held desc (so EinstoffShapes still   *)
(* holds it), the operand tensors, and bindings.  lhs/rhs are re-parsed   *)
(* here.  Returns the concatenated array, or $Failed (message emitted).   *)
(* ------------------------------------------------------------------ *)

SetAttributes[directSumConcat, HoldFirst];

directSumConcat[desc_, tensors_, bindings_List, traceAction_ : None] := withAxisScope @
  Module[{parts, lhs, rhs, out, cpos, cps, summandLists, counts, combos, k, shp,
          env, aligned, axes},
    parts = descParts[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    {lhs, rhs} = parts;

    (* Exactly one output shape, with one or more top-level CirclePlus terms. *)
    If[! MatchQ[rhs, {_List}],
      Message[Einstoff::unsupp,
        "direct-sum concatenation produces exactly one output tensor"];
      Return[$Failed]];
    out = First[rhs];
    If[Cases[out, t_ /; bracketWrapperQ[t] && ! FreeQ[t, CirclePlus], {1}] =!= {},
      Message[Einstoff::unsupp,
        "structural direct-sum concatenation uses a bare CirclePlus axis, not a \
targeted direct sum. Use an unwrapped CirclePlus for Einstoff[Join]/[Split]; targeted \
CirclePlus is only a single physical target axis for ArrayReduce"];
      Return[$Failed]];
    cpos = Flatten @ Position[out, _CirclePlus, {1}];
    If[cpos === {} || hasCirclePlus[Delete[out, List /@ cpos]],
      Message[Einstoff::unsupp,
        "concatenation supports only top-level direct-sum (CirclePlus) axes per output \
shape (top-level nesting like a \[CirclePlus] (b \[CirclePlus] c) is flattened and \
supported; a CirclePlus nested inside another term such as a CircleTimes is not \
supported yet)"];
      Return[$Failed]];
    cps = out[[cpos]];
    summandLists = List @@ # & /@ cps;
    counts = Length /@ summandLists;
    combos = Tuples[Range /@ counts];
    k = Length[combos];

    (* Each summand must be a name, integer, or product of those (a CircleTimes
       block); a targeted direct sum is not supported. *)
    If[! AllTrue[Flatten[summandLists], directSumSummandQ],
      Message[Einstoff::unsupp,
        "each direct-sum summand must be an axis name, an integer, or a product \
of those (targeted direct sums are not supported yet)"];
      Return[$Failed]];

    (* k operands, one per summand combination (positional: combo i <- operand i). *)
    If[! MatchQ[lhs, {___List}] || Length[lhs] =!= k || Length[tensors] =!= k,
      Message[Einstoff::unsupp,
        "direct-sum concatenation needs one operand per summand combination: the output has " <>
          ToString[k] <> " combination(s) but " <> ToString[Length[tensors]] <>
          " tensor(s) were given"];
      Return[$Failed]];

    (* The resolver no longer rejects a repeated LHS, so guard here.  A repeated name is
       read as within-tensor contraction (Massage/Contract/einsum only); this path is also
       reached via Einstoff["Massage"], so the message gives no redirect.  NB: a repeated
       *direct-sum summand* (b (q + q) -> …) would be an equal-size split, which the
       positional split machinery could support — that is a deferred feature; today the
       rule is simply "axis names distinct within a shape", so the message says so rather
       than asserting the user attempted a contraction. *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> axisDisplayName[firstDuplicateAxis[lhs]] <> " repeats within an input \
shape; the direct-sum path requires axis names distinct within a shape (name a repeated \
summand distinctly; within-tensor contraction is not supported here)"];
      Return[$Failed]];

    shp = EinstoffShapes[desc, Dimensions /@ tensors, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    If[traceActionEnabledQ[traceAction],
      aligned = einCatch @ Table[
        Module[{opShape = lhs[[i]], tensor = tensors[[i]], atoms, dims, target,
                replacements},
          atoms = If[opShape === {}, {}, Join @@ (rearrangeAtoms /@ opShape)];
          dims = atomSize[#, env] & /@ atoms;
          replacements = Table[
            cpos[[j]] -> summandLists[[j, combos[[i, j]]]],
            {j, Length[cpos]}];
          target = ReplacePart[out, replacements];
          materializeOutputExprHeld[
            If[dims === {}, heldValue[tensor], heldReshape[heldValue[tensor], dims]],
            atoms, target, env]],
        {i, k}];
      If[aligned === $Failed,
        Message[Einstoff::unsat,
          "an axis size is unbound while aligning a direct-sum operand"];
        Return[$Failed]];
      Return[traceReturnHeld[directSumJoinHeldBlocks[aligned, cpos, counts], traceAction]]];

    (* Align each operand to the output shape with CirclePlus -> its summands. *)
    aligned = einCatch @ Table[
      Module[{opShape = lhs[[i]], tensor = tensors[[i]], atoms, dims, target,
              replacements},
        atoms = If[opShape === {}, {}, Join @@ (rearrangeAtoms /@ opShape)];
        dims = atomSize[#, env] & /@ atoms;
        replacements = Table[
          cpos[[j]] -> summandLists[[j, combos[[i, j]]]],
          {j, Length[cpos]}];
        target = ReplacePart[out, replacements];
        materializeOutput[
          If[dims === {}, tensor, ArrayReshape[tensor, dims]], atoms, target, env]],
      {i, k}];
    If[aligned === $Failed,
      Message[Einstoff::unsat,
        "an axis size is unbound while aligning a direct-sum operand"];
      Return[$Failed]];

    axes = cpos;
    With[{aligned0 = aligned, axes0 = axes, counts0 = counts},
      traceReturn[directSumJoinBlocks[aligned0, axes0, counts0], traceAction]]
  ];

(* ------------------------------------------------------------------ *)
(* Split handler.  CirclePlus on the LHS of a single input shape: slice the *)
(* concat axes into contiguous Cartesian blocks (last axis fastest) and       *)
(* rearrange each block to its output shape.  Returns a List of arrays.       *)
(* ------------------------------------------------------------------ *)

SetAttributes[directSumSplit, HoldFirst];

directSumSplit[desc_, tensors_, bindings_List, traceAction_ : None] := withAxisScope @
  Module[{parts, lhs, rhs, inShape, cpos, cps, summandLists, counts, combos, k,
          shp, env, x, ndims, outs},
    parts = descParts[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    {lhs, rhs} = parts;

    (* Exactly one input shape with one or more top-level CirclePlus terms. *)
    If[! MatchQ[lhs, {_List}] || Length[tensors] =!= 1,
      Message[Einstoff::unsupp,
        "direct-sum splitting takes exactly one input tensor"];
      Return[$Failed]];
    inShape = First[lhs];
    If[Cases[inShape, t_ /; bracketWrapperQ[t] && ! FreeQ[t, CirclePlus], {1}] =!= {},
      Message[Einstoff::unsupp,
        "structural direct-sum splitting uses a bare CirclePlus axis, not a targeted \
direct sum. Use an unwrapped CirclePlus for Einstoff[Join]/[Split]; targeted CirclePlus \
is only a single physical target axis for ArrayReduce"];
      Return[$Failed]];
    cpos = Flatten @ Position[inShape, _CirclePlus, {1}];
    If[cpos === {} || hasCirclePlus[Delete[inShape, List /@ cpos]],
      Message[Einstoff::unsupp,
        "splitting supports only top-level direct-sum (CirclePlus) axes per input shape \
(top-level nesting like a \[CirclePlus] (b \[CirclePlus] c) is flattened and \
supported; a CirclePlus nested inside another term such as a CircleTimes is not \
supported yet)"];
      Return[$Failed]];
    (* On the LHS the summands are blanks (q_, or blanks inside a
       product block); reduce to bare names at every level so sizing/ReplacePart
       see bare symbols, as on the concat (RHS) side. *)
    cps = inShape[[cpos]];
    summandLists = ((List @@ #) //. Verbatim[Pattern][x_, _] :> x) & /@ cps;
    counts = Length /@ summandLists;
    combos = Tuples[Range /@ counts];
    k = Length[combos];

    If[! AllTrue[Flatten[summandLists], directSumSummandQ],
      Message[Einstoff::unsupp,
        "each direct-sum summand must be an axis name, an integer, or a product \
of those (targeted direct sums are not supported yet)"];
      Return[$Failed]];

    (* k outputs, one per summand combination (positional: combo i -> output i). *)
    If[! MatchQ[rhs, {___List}] || Length[rhs] =!= k,
      Message[Einstoff::unsupp,
        "direct-sum splitting needs one output per summand combination: the input has " <>
          ToString[k] <> " combination(s) but " <> ToString[Length[rhs]] <>
          " output shape(s) were given"];
      Return[$Failed]];

    (* Guard here since the resolver no longer rejects a repeated LHS.  A repeated name is
       read as within-tensor contraction (unsupported on this path).  NB the equal-summand
       case b (q + q) -> b q, b q is a deferred feature (see directSumConcat); today the
       rule is "axis names distinct within a shape", so the message states that plainly. *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> axisDisplayName[firstDuplicateAxis[lhs]] <> " repeats within an input \
shape; the direct-sum path requires axis names distinct within a shape (name a repeated \
summand distinctly; within-tensor contraction is not supported here)"];
      Return[$Failed]];

    shp = EinstoffShapes[desc, Dimensions /@ tensors, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    x = First[tensors];
    ndims = Length[inShape];
    If[traceActionEnabledQ[traceAction],
      outs = einCatch @ Module[{sizes, ends, starts},
        sizes = Table[
          (Times @@ (atomSize[#, env] & /@ rearrangeAtoms[#])) & /@ summandLists[[j]],
          {j, Length[summandLists]}];
        ends = Accumulate /@ sizes; starts = ends - sizes + 1;
        Table[
          Module[{combo = combos[[i]], specs, terms, atoms, dims, block, replacements},
            specs = Table[
              With[{j = FirstPosition[cpos, d, Missing["NotFound"]]},
                If[MissingQ[j], All,
                  {starts[[j[[1]], combo[[j[[1]]]]]], ends[[j[[1]], combo[[j[[1]]]]]]}]],
              {d, ndims}];
            replacements = Table[
              cpos[[j]] -> summandLists[[j, combo[[j]]]], {j, Length[cpos]}];
            terms = ReplacePart[inShape, replacements];
            atoms = If[terms === {}, {}, Join @@ (rearrangeAtoms /@ terms)];
            dims = atomSize[#, env] & /@ atoms;
            block = heldTakeValue[x, specs];
            materializeOutputExprHeld[
              If[dims === {}, block, heldReshape[block, dims]], atoms, rhs[[i]], env]],
          {i, k}]];
      If[outs === $Failed,
        Message[Einstoff::unsat,
          "an axis size is unbound while slicing a direct-sum block"];
        Return[$Failed]];
      Return[traceReturnHeld[heldList[outs], traceAction]]];

    outs = einCatch @ Module[{sizes, ends, starts},
      (* block size of a summand = product over its atoms (a product block (a b)
         contributes a*b to the concat axis). *)
      sizes = Table[
        (Times @@ (atomSize[#, env] & /@ rearrangeAtoms[#])) & /@ summandLists[[j]],
        {j, Length[summandLists]}];
      ends = Accumulate /@ sizes; starts = ends - sizes + 1;
      Table[
        Module[{combo = combos[[i]], block, terms, atoms, dims, specs, replacements},
          (* slice block i along axis n; All on every other axis *)
          specs = Table[
            With[{j = FirstPosition[cpos, d, Missing["NotFound"]]},
              If[MissingQ[j], All,
                {starts[[j[[1]], combo[[j[[1]]]]]], ends[[j[[1]], combo[[j[[1]]]]]]}]],
            {d, ndims}];
          block = Take[x, Sequence @@ specs];
          replacements = Table[
            cpos[[j]] -> summandLists[[j, combo[[j]]]], {j, Length[cpos]}];
          terms = ReplacePart[inShape, replacements];
          atoms = If[terms === {}, {}, Join @@ (rearrangeAtoms /@ terms)];
          dims = atomSize[#, env] & /@ atoms;
          materializeOutput[
            If[dims === {}, block, ArrayReshape[block, dims]], atoms, rhs[[i]], env]],
        {i, k}]];
    If[outs === $Failed,
      Message[Einstoff::unsat,
        "an axis size is unbound while slicing a direct-sum block"];
      Return[$Failed]];
    outs
  ];

(* ------------------------------------------------------------------ *)
(* Public operators.                                                   *)
(* ------------------------------------------------------------------ *)

(* desc not held (uniform convention); the internal directSum* / EinstoffShapes
   layer still holds it for structural resolution. *)
EinstoffJoin[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] := withAxisScope @
  Module[{parts, traceAction},
    traceAction = OptionValue[TraceAction];
    parts = descParts[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    (* Guard: Join is concatenation — CirclePlus must be on the RHS only. *)
    If[hasCirclePlus[parts[[1]]],
      Message[Einstoff::unsupp,
        "Einstoff[Join] concatenates: CirclePlus must appear on the output (RHS), \
not the input (LHS); use Einstoff[Split] for an input direct sum"];
      Return[$Failed]];
    If[! hasCirclePlus[parts[[2]]],
      Message[Einstoff::unsupp,
        "Einstoff[Join] needs a direct-sum (CirclePlus) axis on the output"];
      Return[$Failed]];
    directSumConcat[desc, tensors, bindings, traceAction]
  ];

EinstoffSplit[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] := withAxisScope @
  Module[{parts, traceAction},
    traceAction = OptionValue[TraceAction];
    parts = descParts[Hold[desc]];
    If[parts === $Failed, Return[descFailReturn[]]];
    (* Guard: Split is the input direct sum — CirclePlus on the LHS only. *)
    If[hasCirclePlus[parts[[2]]],
      Message[Einstoff::unsupp,
        "Einstoff[Split] splits an input direct sum: CirclePlus must appear on the \
input (LHS), not the output (RHS); use Einstoff[Join] for an output direct sum"];
      Return[$Failed]];
    If[! hasCirclePlus[parts[[1]]],
      Message[Einstoff::unsupp,
        "Einstoff[Split] needs a direct-sum (CirclePlus) axis on the input (LHS)"];
      Return[$Failed]];
    directSumSplit[desc, tensors, bindings, traceAction]
  ];
