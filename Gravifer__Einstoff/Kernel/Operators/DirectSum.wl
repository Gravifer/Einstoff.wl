(* ::Package:: *)

(* Direct-sum path: CirclePlus (einx `+`) — concatenation and splitting along an
   axis.  CirclePlus is a *parentheses* construct (composition level), orthogonal
   to Slot brackets; `(a + b)` is a direct sum, distinct from `(a b)` product
   (CircleTimes) and `[a]` bracket (Slot).

   Two directions (einx is positional, left-to-right — summand i ↔ operand i):

   * Concat — CirclePlus on the RHS: `{op1, …, opk} :> {{ … s1 ⊕ … ⊕ sk … }}`.
     Each operand is aligned to the output shape with the top-level CirclePlus axes
     replaced by one Cartesian summand combination (the shared plan broadcasts a
     scalar operand or an integer summand broadcasts to fill — einx's
     `b c, -> b (c + 1)` with 42), then the blocks are Join'd along those concat
     axes. IMPLEMENTED.

   * Split — CirclePlus on the LHS: `{{ … a ⊕ b … }} :> {out1, out2, …}`. One input
     is sliced into contiguous Cartesian blocks along the top-level direct-sum axes
     (Take, left-to-right with the last axis varying fastest); each slice is then
     rearranged to its output shape through the shared plan. Returns a List of
     arrays. IMPLEMENTED.

   Surface: folded into the permissive Einstoff["Massage"] (einx puts `+` in `id`); the
   desc is routed here when it contains a CirclePlus.  The bijective Einstoff[ArrayReshape]
   / no-repetition Einstoff["ArrayContract"] guards reject a direct sum (it is a structural
   join/split, not a reshape/contraction).  Einstoff[Join] and Einstoff[Split] are the same
   machinery under a directional guard (Join: CirclePlus only on the RHS; Split: only on
   the LHS).

   Surface capture, analysis, and execution are delegated to the staged compiler and
   direct-sum planner. *)

PackageScoped[{EinstoffJoin, EinstoffSplit}]

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
    Which[
      heldRepeatedInputQ[h],
        Message[Einstoff::unsupp,
          "a direct-sum input may not repeat a carried axis"];
        $Failed,
      direction === "Join" && TrueQ[sides["LHS"]],
        Message[Einstoff::unsupp,
          "Einstoff[Join] requires CirclePlus on the output, not the input"];
        $Failed,
      direction === "Split" && TrueQ[sides["RHS"]],
        Message[Einstoff::unsupp,
          "Einstoff[Split] requires CirclePlus on the input, not the output"];
        $Failed,
      True,
        compiled = compileHeldDescIR[h, HoldComplete[bindings], direction, <||>];
        If[Head[Lookup[compiled, "Normalized", None]] ===
            Gravifer`Einstoff`Internal`IR`NormalizedDesc &&
            ! TrueQ[sides[If[direction === "Join", "RHS", "LHS"]]],
          Message[Einstoff::unsupp,
            "the direct-sum operator requires a CirclePlus axis"];
          $Failed,
        planned = tryDirectSumCompiledIRPlan[compiled, tensors, direction, traceAction];
        If[plannerFailureQ[planned], reportPlannerFailure[planned], planned]]
    ]
  ];
