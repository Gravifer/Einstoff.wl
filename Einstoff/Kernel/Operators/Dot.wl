(* ::Package:: *)

(* Contraction path: Einstoff[Dot] and its generalization Einstoff[Inner].

   Einstoff[Dot] is einsum-style contraction (einx.dot): sum of products. It is the
   (Times, Plus) special case of Einstoff[Inner][mul, add], which contracts with an
   arbitrary "multiply" mul and "combine" add (cf. WL Inner — Dot == Inner[Times, _,
   _, Plus]).  Inner is curried: Einstoff[Inner][mul, add][desc, tensors, bindings].

   N-ary over two or more operands. An atomic axis is:
     contracted  if it is absent from the output (combined over),
     kept         if it is on the output — batch (shared across operands) or free.
   Brackets (Slot[...]) are the einx way to mark contracted axes; they are unwrapped
   here, since whether an axis contracts already follows from "shared & not on the
   output" (SPEC 5.2, ex 10).

   Lowering — pairwise left fold. `contractPair` contracts two atomic-axis tensors,
   keeping a given set of axes, by classifying their axes into batch B / contract K /
   free M,N, reshaping to [B,M,K] and [B,K,N], and a batched generalized inner
   product (MapThread of Inner[mul, …, add], or Dot for the Times/Plus fast path)
   -> [B,M,N]. The fold contracts operand 1·2, then ·3, … ; at each step the *kept*
   set is the global output axes plus every axis a later operand still needs, so an
   axis is combined only once nothing downstream needs it. For a semiring (mul, add)
   — (Times,Plus), tropical (Plus,Min), … — the fold is associative; the left-to-
   right order is the defined semantics regardless. The single remaining tensor is
   permuted/recomposed onto the output by the shared materializeOutput (which also
   broadcasts any output-only repetition axis, SPEC 5.5).

   An axis appearing in only one operand and neither kept nor shared would be a
   within-operand reduction before contraction — rejected (use ArrayReduce). A
   CirclePlus or variable-arity bracket ellipsis in a contraction shape is also
   rejected. Shared shape helpers live in ShapeChecker.wl; atom/materialization helpers
   live in Lowering.wl. *)

PackageExported[{EinstoffDot, EinstoffInner}]

EinstoffDot::usage =
  "EinstoffDot[desc, tensors, bindings] realizes an einsum-style contraction \
(einx.dot) of two or more tensors: shared axes absent from the output are summed, \
shared output axes are batch dims, one-sided output axes are free. It is the \
Times/Plus case of EinstoffInner.";

EinstoffInner::usage =
  "EinstoffInner[mul, add][desc, tensors, bindings] generalizes EinstoffDot: it \
contracts with an arbitrary elementwise mul and combiner add (cf. WL Inner), e.g. \
{Times, Plus} is Dot, {Plus, Min} is min-plus (tropical) contraction. Curried in \
(mul, add).";

Einstoff[Dot] := EinstoffDot;
Einstoff["Dot"] := EinstoffDot;
Einstoff[Inner] := EinstoffInner;
Einstoff["Inner"] := EinstoffInner;

Options[EinstoffDot] = {TraceAction -> None, "Targeting" -> Automatic};
Options[EinstoffInner] = {TraceAction -> None, "Targeting" -> Automatic};

innerLower[mul_, add_, desc_, tensors_, bindings_List, traceAction_, targeting_] :=
  Module[{planned = tryInnerIRPlan[Hold[desc], tensors, bindings, mul, add,
      targeting, traceAction]},
    Which[
      plannerFailureQ[planned],
        reportPlannerFailure[planned],
      True,
        planned
    ]
  ];

EinstoffDot[desc_, tensors_, bindings_List : {}, opts : OptionsPattern[]] :=
  innerLower[Times, Plus, desc, tensors, bindings,
    OptionValue[TraceAction], OptionValue["Targeting"]];

EinstoffInner[mul_, add_][desc_, tensors_, bindings_List : {},
    opts : OptionsPattern[EinstoffInner]] :=
  innerLower[mul, add, desc, tensors, bindings,
    OptionValue[EinstoffInner, {opts}, TraceAction],
    OptionValue[EinstoffInner, {opts}, "Targeting"]];
