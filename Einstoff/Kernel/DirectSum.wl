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
     axis of size Σ sliced (Take) into multiple output tensors. NOT YET (phase 2).

   Surface: folded into Einstoff[ArrayReshape] (einx puts `+` in `id`); the desc is
   routed here when it contains a CirclePlus. Einstoff[Join] and Einstoff[Split] are
   the same machinery under a directional guard (Join: CirclePlus only on the RHS;
   Split: only on the LHS).

   Shared helpers (descParts, rearrangeAtoms, atomSize, materializeOutput,
   hasCirclePlus) live in Lowering.wl. *)

PackageExported[{EinstoffJoin, EinstoffSplit}]

EinstoffJoin::usage =
  "EinstoffJoin[desc, tensors, bindings] concatenates tensors along a direct-sum \
axis (einx `+`): the desc must carry a CirclePlus on the RHS only, e.g. \
{{m_, a_}, {m_, b_}} :> {{m, a \\[CirclePlus] b}}. desc is held.";

EinstoffSplit::usage =
  "EinstoffSplit[desc, tensors, bindings] splits a tensor along a direct-sum axis \
into multiple outputs (einx `+` on the LHS). Not yet implemented.";

Einstoff[Join] := EinstoffJoin;
Einstoff["Join"] := EinstoffJoin;
Einstoff[Split] := EinstoffSplit;
Einstoff["Split"] := EinstoffSplit;

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
        "concatenation supports exactly one top-level CirclePlus on the output \
(nested or multiple direct sums are not supported yet)"];
      Return[$Failed]];
    n = cpos[[1, 1]];                       (* concat axis = that term's position *)
    cp = out[[n]];
    summands = List @@ cp;
    k = Length[summands];

    (* Each summand must be a bare name or integer (no nested composite yet). *)
    If[! AllTrue[summands, MatchQ[#, _Symbol | _Integer] &],
      Message[Einstoff::unsupp,
        "each direct-sum summand must be a bound axis name or an integer \
(composite summands are not supported yet)"];
      Return[$Failed]];

    (* k operands, one per summand (positional: summand i <- operand i). *)
    If[! MatchQ[lhs, {___List}] || Length[lhs] =!= k || Length[tensors] =!= k,
      Message[Einstoff::unsupp,
        "direct-sum concatenation needs one operand per summand: the output has " <>
          ToString[k] <> " summand(s) but " <> ToString[Length[tensors]] <>
          " tensor(s) were given"];
      Return[$Failed]];

    shp = EinstoffShapes[desc, Dimensions /@ tensors, bindings];
    If[! TrueQ[shp["Satisfiable"]],
      Message[Einstoff::unsat, shp["Reason"]]; Return[$Failed]];
    env = shp["Bindings"];

    (* Align each operand to the output shape with CirclePlus -> its summand. *)
    aligned = Catch @ Table[
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
(* Public operators.                                                   *)
(* ------------------------------------------------------------------ *)

SetAttributes[EinstoffJoin, HoldFirst];
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

SetAttributes[EinstoffSplit, HoldFirst];
EinstoffSplit[desc_, tensors_, bindings_List : {}] :=
  Module[{parts},
    parts = descParts[Hold[desc]];
    If[parts === $Failed,
      Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"];
      Return[$Failed]];
    If[! hasCirclePlus[parts[[1]]],
      Message[Einstoff::unsupp,
        "Einstoff[Split] needs a direct-sum (CirclePlus) axis on the input (LHS)"];
      Return[$Failed]];
    Message[Einstoff::unsupp,
      "direct-sum splitting (CirclePlus on the LHS -> multiple outputs) is not \
implemented yet"];
    $Failed
  ];
