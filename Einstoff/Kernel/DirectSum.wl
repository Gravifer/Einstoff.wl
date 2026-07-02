(* ::Package:: *)

(* Direct-sum path: CirclePlus (einx `+`) — concatenation and splitting along an
   axis.  CirclePlus is a *parentheses* construct (composition level), orthogonal
   to Slot brackets; `(a + b)` is a direct sum, distinct from `(a b)` product
   (CircleTimes) and `[a]` bracket (Slot).

   Two directions (einx is positional, left-to-right — summand i ↔ operand i):

   * Concat — CirclePlus on the RHS: `{op1, …, opk} :> {{ … s1 ⊕ … ⊕ sk … }}`.
     Each operand is aligned to the output shape with the CirclePlus replaced by
     its own summand block (reusing materializeOutput, so a scalar operand or an
     integer summand broadcasts to fill — einx's `b c, -> b (c + 1)` with 42), then
     the blocks are Join'd along the concat axis. IMPLEMENTED.

   * Split — CirclePlus on the LHS: `{{ … a ⊕ b … }} :> {out1, out2, …}`. One input
     axis of size Σ sliced (Take, contiguous left-to-right: output i ← summand i)
     into multiple output tensors; each slice is then rearranged to its output
     shape (reusing materializeOutput). Returns a List of arrays. IMPLEMENTED.

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

(* A valid direct-sum summand: an axis name (bare or a binding pattern), an
   integer, or a CircleTimes product of those. A Slot (bracketed direct sum) or
   any other head is not supported. Shared by the concat and split handlers. *)
directSumSummandQ[s_] :=
  MatchQ[s, _Symbol | _Integer | Verbatim[Pattern][_Symbol, Verbatim[Blank[]]]] ||
    (Head[s] === CircleTimes && AllTrue[List @@ s, directSumSummandQ]);

(* ------------------------------------------------------------------ *)
(* Concat handler.  Called with the held desc (so EinstoffShapes still   *)
(* holds it), the operand tensors, and bindings.  lhs/rhs are re-parsed   *)
(* here.  Returns the concatenated array, or $Failed (message emitted).   *)
(* ------------------------------------------------------------------ *)

SetAttributes[directSumConcat, HoldFirst];

directSumConcat[desc_, tensors_, bindings_List] :=
  Module[{parts, lhs, rhs, out, cpos, cp, summands, k, shp, env,
          aligned, n},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;

    (* Exactly one output shape, with exactly one top-level CirclePlus term. *)
    If[! MatchQ[rhs, {_List}],
      Message[Einstoff::unsupp,
        "direct-sum concatenation produces exactly one output tensor"];
      Return[$Failed]];
    out = First[rhs];
    cpos = Position[out, _CirclePlus, {1}];
    If[Length[cpos] =!= 1 || hasCirclePlus[Delete[out, cpos]],
      Message[Einstoff::unsupp,
        "concatenation supports exactly one direct-sum (CirclePlus) axis per output \
shape (top-level nesting like a \[CirclePlus] (b \[CirclePlus] c) is flattened and \
supported; more than one direct-sum axis, or a CirclePlus nested inside another term \
such as a CircleTimes, is not supported yet)"];
      Return[$Failed]];
    n = cpos[[1, 1]];                       (* concat axis = that term's position *)
    cp = out[[n]];
    summands = List @@ cp;
    k = Length[summands];

    (* Each summand must be a name, integer, or product of those (a CircleTimes
       block); a Slot (bracketed direct sum) is not supported. *)
    If[! AllTrue[summands, directSumSummandQ],
      Message[Einstoff::unsupp,
        "each direct-sum summand must be an axis name, an integer, or a product \
of those (bracketed direct sums are not supported yet)"];
      Return[$Failed]];

    (* k operands, one per summand (positional: summand i <- operand i). *)
    If[! MatchQ[lhs, {___List}] || Length[lhs] =!= k || Length[tensors] =!= k,
      Message[Einstoff::unsupp,
        "direct-sum concatenation needs one operand per summand: the output has " <>
          ToString[k] <> " summand(s) but " <> ToString[Length[tensors]] <>
          " tensor(s) were given"];
      Return[$Failed]];

    (* A name repeated within an input shape is within-tensor contraction; the direct-sum
       path (concat) cannot contract.  The resolver no longer rejects a repeated LHS, so
       guard here (this path is also reached via Einstoff["Massage"], so the message gives
       no redirect — within+direct-sum is unsupported everywhere). *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> ToString[firstDuplicateAxis[lhs]] <> " repeats within an input \
shape; the direct-sum path does not contract a repeated axis"];
      Return[$Failed]];

    shp = EinstoffShapes[desc, Dimensions /@ tensors, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    (* Align each operand to the output shape with CirclePlus -> its summand. *)
    aligned = einCatch @ Table[
      Module[{opShape = lhs[[i]], tensor = tensors[[i]], atoms, dims, target},
        atoms = If[opShape === {}, {}, Join @@ (rearrangeAtoms /@ opShape)];
        dims = atomSize[#, env] & /@ atoms;
        target = ReplacePart[out, n -> summands[[i]]];
        materializeOutput[
          If[dims === {}, tensor, ArrayReshape[tensor, dims]], atoms, target, env]],
      {i, k}];
    If[aligned === $Failed,
      Message[Einstoff::unsat,
        "an axis size is unbound while aligning a direct-sum operand"];
      Return[$Failed]];

    Join[Sequence @@ aligned, n]
  ];

(* ------------------------------------------------------------------ *)
(* Split handler.  CirclePlus on the LHS of a single input shape: slice the *)
(* concat axis into contiguous blocks (output i <- summand i, left-to-right) *)
(* and rearrange each block to its output shape.  Returns a List of arrays.  *)
(* ------------------------------------------------------------------ *)

SetAttributes[directSumSplit, HoldFirst];

directSumSplit[desc_, tensors_, bindings_List] :=
  Module[{parts, lhs, rhs, inShape, cpos, cp, summands, k, shp, env, x,
          ndims, n, outs},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    {lhs, rhs} = parts;

    (* Exactly one input shape with exactly one top-level CirclePlus term. *)
    If[! MatchQ[lhs, {_List}] || Length[tensors] =!= 1,
      Message[Einstoff::unsupp,
        "direct-sum splitting takes exactly one input tensor"];
      Return[$Failed]];
    inShape = First[lhs];
    cpos = Position[inShape, _CirclePlus, {1}];
    If[Length[cpos] =!= 1 || hasCirclePlus[Delete[inShape, cpos]],
      Message[Einstoff::unsupp,
        "splitting supports exactly one direct-sum (CirclePlus) axis per input shape \
(top-level nesting like a \[CirclePlus] (b \[CirclePlus] c) is flattened and \
supported; more than one direct-sum axis, or a CirclePlus nested inside another term \
such as a CircleTimes, is not supported yet)"];
      Return[$Failed]];
    n = cpos[[1, 1]];                       (* concat axis = that term's position *)
    cp = inShape[[n]];
    (* On the LHS the summands are binding patterns (q_, or patterns inside a
       product block); reduce to bare names at every level so sizing/ReplacePart
       see bare symbols, as on the concat (RHS) side. *)
    summands = (List @@ cp) //. Verbatim[Pattern][x_, _] :> x;
    k = Length[summands];

    If[! AllTrue[summands, directSumSummandQ],
      Message[Einstoff::unsupp,
        "each direct-sum summand must be an axis name, an integer, or a product \
of those (bracketed direct sums are not supported yet)"];
      Return[$Failed]];

    (* k outputs, one per summand (positional: summand i -> output i). *)
    If[! MatchQ[rhs, {___List}] || Length[rhs] =!= k,
      Message[Einstoff::unsupp,
        "direct-sum splitting needs one output per summand: the input has " <>
          ToString[k] <> " summand(s) but " <> ToString[Length[rhs]] <>
          " output shape(s) were given"];
      Return[$Failed]];

    (* A name repeated within the input shape is within-tensor contraction; the direct-sum
       path (split) cannot contract.  Guard here since the resolver no longer rejects a
       repeated LHS (also reachable via Einstoff["Massage"] — no redirect). *)
    If[! distinctAxesQ[lhs],
      Message[Einstoff::unsupp,
        "axis " <> ToString[firstDuplicateAxis[lhs]] <> " repeats within an input \
shape; the direct-sum path does not contract a repeated axis"];
      Return[$Failed]];

    shp = EinstoffShapes[desc, Dimensions /@ tensors, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    x = First[tensors];
    ndims = Length[inShape];
    outs = einCatch @ Module[{sz, en, st},
      (* block size of a summand = product over its atoms (a product block (a b)
         contributes a*b to the concat axis). *)
      sz = (Times @@ (atomSize[#, env] & /@ rearrangeAtoms[#])) & /@ summands;
      en = Accumulate[sz]; st = en - sz + 1;       (* contiguous block bounds *)
      Table[
        Module[{block, terms, atoms, dims},
          (* slice block i along axis n; All on every other axis *)
          block = Take[x, Sequence @@ Table[
            If[d === n, {st[[i]], en[[i]]}, All], {d, ndims}]];
          terms = ReplacePart[inShape, n -> summands[[i]]];
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
EinstoffJoin[desc_, tensors_, bindings_List : {}] :=
  Module[{parts},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    (* Guard: Join is concatenation — CirclePlus must be on the RHS only. *)
    If[hasCirclePlus[parts[[1]]],
      Message[Einstoff::unsupp,
        "Einstoff[Join] concatenates: CirclePlus must appear on the output (RHS), \
not the input (LHS) — use Einstoff[Split] for an input direct sum"];
      Return[$Failed]];
    If[! hasCirclePlus[parts[[2]]],
      Message[Einstoff::unsupp,
        "Einstoff[Join] needs a direct-sum (CirclePlus) axis on the output"];
      Return[$Failed]];
    directSumConcat[desc, tensors, bindings]
  ];

EinstoffSplit[desc_, tensors_, bindings_List : {}] :=
  Module[{parts},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    (* Guard: Split is the input direct sum — CirclePlus on the LHS only. *)
    If[hasCirclePlus[parts[[2]]],
      Message[Einstoff::unsupp,
        "Einstoff[Split] splits an input direct sum: CirclePlus must appear on the \
input (LHS), not the output (RHS) — use Einstoff[Join] for an output direct sum"];
      Return[$Failed]];
    If[! hasCirclePlus[parts[[1]]],
      Message[Einstoff::unsupp,
        "Einstoff[Split] needs a direct-sum (CirclePlus) axis on the input (LHS)"];
      Return[$Failed]];
    directSumSplit[desc, tensors, bindings]
  ];
