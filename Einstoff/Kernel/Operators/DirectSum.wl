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

   Shared shape helpers (descParts, hasCirclePlus) live in ShapeChecker.wl; runtime
   helpers (rearrangeAtoms, atomSize, materializeOutput) live in Lowering.wl. *)

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
SetAttributes[directSumConcat, HoldFirst];

directSumConcat[desc_, tensors_, bindings_List, traceAction_ : None] :=
  Module[{planned = tryDirectSumIRPlan[
      Hold[desc], tensors, bindings, "Join", traceAction]},
    Which[
      plannerFailureQ[planned],
        reportPlannerFailure[planned],
      True,
        planned
    ]
  ];

(* ------------------------------------------------------------------ *)
(* Split handler.  CirclePlus on the LHS of a single input shape: slice the *)
(* concat axes into contiguous Cartesian blocks (last axis fastest) and       *)
(* rearrange each block to its output shape.  Returns a List of arrays.       *)
(* ------------------------------------------------------------------ *)

SetAttributes[directSumSplit, HoldFirst];

directSumSplit[desc_, tensors_, bindings_List, traceAction_ : None] :=
  Module[{planned = tryDirectSumIRPlan[
      Hold[desc], tensors, bindings, "Split", traceAction]},
    Which[
      plannerFailureQ[planned],
        reportPlannerFailure[planned],
      True,
        planned
    ]
  ];

(* ------------------------------------------------------------------ *)
(* Public operators.                                                   *)
(* ------------------------------------------------------------------ *)

(* Public direction guards preserve the embedded surface diagnostics; execution is
   delegated exclusively to the staged direct-sum planner. *)
EinstoffJoin[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  directSumPublic[Hold[desc], tensors, bindings, "Join", OptionValue[TraceAction]];

EinstoffSplit[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  directSumPublic[Hold[desc], tensors, bindings, "Split", OptionValue[TraceAction]];

directSumPublic[h_Hold, tensors_List, bindings_List, direction_String, traceAction_] :=
  Module[{compiled, sides, planned},
    sides = heldDirectSumSides[h];
    If[heldRepeatedInputQ[h],
      Message[Einstoff::unsupp,
        "a direct-sum input may not repeat a carried axis"];
      Return[$Failed]];
    compiled = compileHeldDescIR[h, HoldComplete[bindings], direction, <||>];
    Which[
      direction === "Join" && TrueQ[sides["LHS"]],
        Message[Einstoff::unsupp,
          "Einstoff[Join] requires CirclePlus on the output, not the input"];
        $Failed,
      direction === "Split" && TrueQ[sides["RHS"]],
        Message[Einstoff::unsupp,
          "Einstoff[Split] requires CirclePlus on the input, not the output"];
        $Failed,
      Head[Lookup[compiled, "Normalized", None]] ===
          Einstoff`Internal`IR`NormalizedDesc &&
          ! TrueQ[sides[If[direction === "Join", "RHS", "LHS"]]],
        Message[Einstoff::unsupp,
          "the direct-sum operator requires a CirclePlus axis"];
        $Failed,
      True,
        planned = tryDirectSumCompiledIRPlan[compiled, tensors, direction, traceAction];
        If[plannerFailureQ[planned], reportPlannerFailure[planned], planned]
    ]
  ];
