(* ::Package:: *)

(* Einstoff parsing — shape-resolution / satisfiability layer.

   Given a `desc` (an einops/einx-style axis transformation written as
   `lhs :> rhs`, list-of-shapes both sides, see .agents/SPEC.md) and the *shapes*
   of input tensors plus an axis-size `bindings` list, decide whether the
   description is satisfiable and, if so, what the output shapes are.

   This is pure shape algebra over the pattern AST — no real arrays are
   touched and nothing is lowered to Transpose/ArrayReshape/etc.

   Scope (regular grammar subset): bare symbols (reference), `name_`
   (blank), integer immediates, `_`/`__`/`___`, named `Repeated` /
   `RepeatedNull` ellipses for shape resolution, `CircleTimes` (product),
   `CirclePlus` (direct sum), targeted wrappers, and multi-tensor shared
   axes. Named ellipses are resolver-only for now; lowerers reject them.

   Structured Package Format: shared internal symbols are declared with
   PackageScoped (they land in the ``Gravifer`Einstoff`PackageScope`` context); every helper below
   is left undeclared and is therefore private to this file
   (`Gravifer`Einstoff`Parsing`Private``). *)

PackageScoped[{
  EinstoffShapes,
  EinstoffParse,
  EinstoffMatch
}]

EinstoffShapes::usage =
  "EinstoffShapes[desc, inputShapes, bindings] resolves the einstoff \
description desc against the given input tensor shapes (lists of integers) \
and axis-size bindings, returning an association with keys \"Satisfiable\", \
\"OutputShapes\", \"Bindings\", \"Targeted\" and \"Reason\". desc is held.";

EinstoffParse::usage =
  "EinstoffParse[desc] normalizes desc (lhs :> rhs, or lhs -> rhs) into an \
association <|\"LHS\" -> shapes, \"RHS\" -> Hold[shapes]|>. desc is held.";

EinstoffMatch::usage =
  "EinstoffMatch[lhsShapes, inputShapes, bindings] binds axis sizes by \
matching the lhs shapes against the input shapes, returning an association \
with \"ok\" and either \"env\" or \"reason\".";

(* ------------------------------------------------------------------ *)
(* Parse / normalize the description.                                  *)
(* desc reaches us held; we keep the RHS held so that `:>` and `->`    *)
(* behave identically and unbound pattern symbols are not evaluated.   *)
(* ------------------------------------------------------------------ *)

SetAttributes[EinstoffParse, HoldFirst];
EinstoffParse[desc_] :=
  Module[{compiled, captured, a, result},
    compiled = compileHeldDescIR[Hold[desc], HoldComplete[{}], "Parse", <||>];
    captured = Lookup[compiled, "Captured", None];
    If[Head[captured] =!= Gravifer`Einstoff`Internal`IR`CapturedDesc,
      <|"LHS" -> $Failed, "RHS" -> $Failed|>,
      a = Replace[captured, Gravifer`Einstoff`Internal`IR`CapturedDesc[x_Association] :> x];
      result = <|"LHS" -> displayCapturedSurface[a["CanonicalLHS"]],
        "RHS" -> displayCapturedSurface[a["CanonicalRHS"]]|>;
      If[MatchQ[Lookup[compiled, "Surface", None],
          Gravifer`Einstoff`Internal`IR`SurfaceDesc[HoldComplete[_Rule], ___]],
        Append[result, "Warning" -> "prefer :> (RuleDelayed) over -> for desc"],
        result]
    ]
  ];

displayCapturedSurface[expr_] := FixedPoint[displayCapturedSurfaceStep, expr];

displayCapturedSurfaceStep[expr_] := expr /. {
  capturedBinder[name_String] :>
    RuleCondition[With[{s = axisSymbol[name]}, Pattern[s, Blank[]]]],
  capturedNamedSequence[name_String, 1, None] :>
    RuleCondition[With[{s = axisSymbol[name]}, Pattern[s, BlankSequence[]]]],
  capturedNamedSequence[name_String, 0, None] :>
    RuleCondition[With[{s = axisSymbol[name]}, Pattern[s, BlankNullSequence[]]]],
  capturedNamedSequence[name_String, 1, body_] :>
    RuleCondition[With[{s = axisSymbol[name]}, Pattern[s, Repeated[body]]]],
  capturedNamedSequence[name_String, 0, body_] :>
    RuleCondition[With[{s = axisSymbol[name]}, Pattern[s, RepeatedNull[body]]]],
  capturedLogicalAxis[name_String, _] :> RuleCondition[axisSymbol[name]],
  capturedAmbientAxis[context_String, name_String] :>
    RuleCondition[Symbol[context <> name]],
  capturedAmbientValue[value_] :> value,
  capturedSizedAxis[x_] :> x,
  capturedAnonymousAxis[] :> Blank[],
  capturedAnonymousSequence[1] :> BlankSequence[],
  capturedAnonymousSequence[0] :> BlankNullSequence[],
  capturedAnonymousSequence[0, "SlotSequence"] :> SlotSequence[1],
  capturedTarget[name_String, x_] :>
    RuleCondition[Switch[name, "Slot", Slot[x], "Highlighted", Highlighted[x],
      "Framed", Framed[x]]],
  capturedProduct[children_List] :>
    RuleCondition[Apply[CircleTimes, children]],
  capturedDirectSum[children_List] :>
    RuleCondition[Apply[CirclePlus, children]],
  capturedRepeated[x_, 1] :> Repeated[x],
  capturedRepeated[x_, 0] :> RepeatedNull[x]
};
(* Axis-name identities used by one shape term, for the within-shape uniqueness
   check.  A blank (name_), a bare reference, and a targeted string (Slot["name"])
   are all the axis `name`; integer immediates and the anonymous ellipses
   (_/__/___/##) are not names.  Composites/targets recurse into their parts. *)
termAxisNames[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]]] := {s};
termAxisNames[Verbatim[Pattern][s_Symbol, Verbatim[BlankSequence[]]]] := {s};
termAxisNames[Verbatim[Pattern][s_Symbol, Verbatim[BlankNullSequence[]]]] := {s};
termAxisNames[s_Symbol] := {s};
(* A string axis "a" is the axis `a`.  Route through axisSymbol (valueless when the name
   is shadowed) and validate first, so a raw shape that reaches the uniqueness check
   neither crashes on Symbol::symname nor mis-tallies a shadowed global's value.  An
   invalid string is not an axis name, so it contributes nothing. *)
termAxisNames[s_String] := If[validAxisNameQ[s], {axisSymbol[s]}, {}];
termAxisNames[Verbatim[Pattern][s_Symbol, Verbatim[Repeated][_]]] := {s};
termAxisNames[Verbatim[Pattern][s_Symbol, Verbatim[RepeatedNull][_]]] := {s};
termAxisNames[(CircleTimes | CirclePlus | Slot | Highlighted | Framed |
    Repeated | RepeatedNull)[xs___]] :=
  Join @@ (termAxisNames /@ {xs});
termAxisNames[_] := {};

(* First axis name occurring more than once *within a single shape*, else Missing[].
   einx forbids "multiple vectorized axes with the same name"; the same name across
   *different* shapes (operands, or input vs output) is fine — that is how shared /
   contracted / kept axes work. *)
firstDuplicateAxis[shapes_List] :=
  Module[{dup = Missing["NoDuplicate"], rep},
    Do[
      rep = Select[Tally[Join @@ (termAxisNames /@ shape)], Last[#] > 1 &];
      If[rep =!= {}, dup = rep[[1, 1]]; Break[]],
      {shape, shapes}];
    dup];

(* Public staged shape resolution. *)

SetAttributes[EinstoffMatch, HoldFirst];
EinstoffMatch[lhsShapes_, inputShapes_, bindingsIn_ : {}] :=
  Catch[
    Module[{compiled, normalized, solvedBundle, solved, solvedAssoc, axes, env},
      compiled = Quiet[compileMatchIR[lhsShapes, bindingsIn], {Einstoff::unsupp}];
      normalized = Lookup[compiled, "Normalized", Missing["Normalized"]];
      If[Head[normalized] =!= Gravifer`Einstoff`Internal`IR`NormalizedDesc,
        Throw[<|"ok" -> False,
          "reason" -> publicFailureReason[normalized, None]|>, publicMatchTag]];
      solvedBundle = solveDescIR[compiled, inputShapes];
      solved = Lookup[solvedBundle, "Solved", Missing["Solved"]];
      If[Head[solved] =!= Gravifer`Einstoff`Internal`IR`SolvedDesc,
        Throw[<|"ok" -> False,
          "reason" -> publicFailureReason[solved, normalized]|>, publicMatchTag]];
      solvedAssoc = Replace[solved,
        Gravifer`Einstoff`Internal`IR`SolvedDesc[a_Association] :> a];
      axes = publicNormalizedAxes[normalized];
      env = Association @ KeyValueMap[
        Function[{id, size}, publicAxisKey[id, axes] -> size],
        KeySelect[solvedAssoc["AxisSizes"],
          MatchQ[#, Gravifer`Einstoff`Internal`IR`AxisId[_Integer]] &]];
      <|"ok" -> True, "env" -> env|>
    ], publicMatchTag];

SetAttributes[compileMatchIR, HoldFirst];
compileMatchIR[lhs_, bindings_] :=
  compileHeldDescIR[Hold[lhs :> {}], HoldComplete[bindings], "Match", <||>];

SetAttributes[EinstoffShapes, HoldFirst];
EinstoffShapes[desc_, inputShapes_, bindings_ : {}] :=
  holdPublicBindingKeys @ Catch[Module[{compiled, normalized, normalizedAssoc, axes, targetedIds,
          targeted, duplicate, solvedBundle, solved, solvedAssoc, bindingsOut},
    compiled = compileHeldDescIR[Hold[desc], HoldComplete[bindings], "Shapes", <||>];
    normalized = Lookup[compiled, "Normalized", Missing["Normalized"]];
    If[Head[normalized] =!= Gravifer`Einstoff`Internal`IR`NormalizedDesc,
      Throw[publicShapesFailure[normalized, None, {}], publicShapesTag]];
    normalizedAssoc = Replace[normalized,
      Gravifer`Einstoff`Internal`IR`NormalizedDesc[a_Association] :> a];
    axes = Replace[normalizedAssoc["Axes"],
      Gravifer`Einstoff`Internal`IR`AxisTable[a_Association] :> a];
    targetedIds = DeleteDuplicates @ Cases[normalizedAssoc["Inputs"],
      Gravifer`Einstoff`Internal`IR`AxisOccurrence[_, id_, meta_Association] /;
          Lookup[meta, "TargetHead", None] =!= None :> id, Infinity];
    targeted = publicAxisKey[#, axes] & /@ targetedIds;
    duplicate = publicDuplicateOutputAxis[normalizedAssoc["Outputs"]];
    If[! MissingQ[duplicate],
      Throw[<|"Satisfiable" -> False,
        "Reason" -> "axis " <> publicAxisName[duplicate, axes] <>
          " appears more than once within the output shape; output axis names must be " <>
          "distinct (einx forbids multiple vectorized axes with the same name)",
        "OutputShapes" -> Missing[], "Bindings" -> <||>,
        "Targeted" -> targeted|>, publicShapesTag]];
    solvedBundle = solveDescIR[compiled, inputShapes];
    solved = Lookup[solvedBundle, "Solved", Missing["Solved"]];
    If[Head[solved] =!= Gravifer`Einstoff`Internal`IR`SolvedDesc,
      Throw[publicShapesFailure[solved, normalized, targeted], publicShapesTag]];
    solvedAssoc = Replace[solved,
      Gravifer`Einstoff`Internal`IR`SolvedDesc[a_Association] :> a];
    bindingsOut = Association @ KeyValueMap[
      Function[{id, size}, publicAxisKey[id, axes] -> size],
      KeySelect[solvedAssoc["AxisSizes"],
        MatchQ[#, Gravifer`Einstoff`Internal`IR`AxisId[_Integer]] &]];
    <|"Satisfiable" -> True, "OutputShapes" -> solvedAssoc["OutputShapes"],
      "Bindings" -> bindingsOut, "Targeted" -> targeted, "Reason" -> ""|>
  ], publicShapesTag];

publicDuplicateOutputAxis[Gravifer`Einstoff`Internal`IR`Outputs[shapes_List]] :=
  SelectFirst[shapes,
    Function[shape, With[{ids = Cases[shape,
        Gravifer`Einstoff`Internal`IR`AxisOccurrence[_, id_, _] :> id, Infinity]},
      ! DuplicateFreeQ[ids]]], Missing["NoDuplicate"]] /.
    Gravifer`Einstoff`Internal`IR`Shape[terms_List] :>
      First @ Select[Cases[terms,
        Gravifer`Einstoff`Internal`IR`AxisOccurrence[_, id_, _] :> id, Infinity],
        Count[Cases[terms,
          Gravifer`Einstoff`Internal`IR`AxisOccurrence[_, other_, _] :> other, Infinity], #] > 1 &];
publicDuplicateOutputAxis[_] := Missing["NoDuplicate"];

publicAxisName[id_, axes_Association] := Replace[Lookup[axes, id, Missing[]],
  Gravifer`Einstoff`Internal`IR`AxisInfo[name_String, _Association] :> name];
publicAxisKey[id_, axes_Association] := axisSymbol[publicAxisName[id, axes]];

publicShapesFailure[failure_, normalized_, targeted_List] :=
  <|"Satisfiable" -> False,
    "Reason" -> publicFailureReason[failure, normalized],
    "OutputShapes" -> Missing[], "Bindings" -> <||>,
    "Targeted" -> targeted|>;

publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord[_, _, details_Association], _] /;
      StringQ[Lookup[details, "Reason", None]] := details["Reason"];
publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord["MalformedDescription", _, _], _] :=
  "description must be of the form lhs :> rhs (or lhs -> rhs), with each side a list of shapes";
publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord["OperandCountMismatch", _, d_Association], _] :=
  "operand count: desc has " <> ToString[d["Expected"]] <> " shape(s) but " <>
    ToString[d["Actual"]] <> " tensor shape(s) given";
publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord["ConflictingAxisSizes", _, d_Association],
    normalized_] :=
  With[{axes = publicNormalizedAxes[normalized]},
    "axis " <> publicAxisName[d["Axis"], axes] <> ": expected " <>
      ToString[d["Expected"]] <> " but tensor dimension is " <>
      ToString[d["Actual"]]];
publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord["ConflictingBindingFacts", _, d_Association],
    normalized_] :=
  With[{name = Lookup[d, "Name",
      publicAxisName[Lookup[d, "Axis", Missing[]], publicNormalizedAxes[normalized]]]},
    "conflicting sizes for axis " <> name <> ": " <>
      StringRiffle[ToString[#, InputForm] & /@ d["Values"], " versus "]];
publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord["RankMismatch", _, _], _] :=
  "no consistent axis binding (shape/rank mismatch)";
publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord["InvalidInputShapes", _, _], _] :=
  "input shapes must be a list of dimension lists";
publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord["InvalidKnownSize", _, _], _] :=
  "each binding must give a positive-integer axis size";
publicFailureReason[
    Gravifer`Einstoff`Internal`IR`FailureRecord["SequenceZipLengthMismatch", _, _], _] :=
  "captured axis sequences have different lengths";
publicFailureReason[Gravifer`Einstoff`Internal`IR`FailureRecord[tag_, _, _], _] :=
  "shape constraints are not satisfiable (" <> tag <> ")";
publicFailureReason[_, _] := "shape constraints are not satisfiable";

publicNormalizedAxes[Gravifer`Einstoff`Internal`IR`NormalizedDesc[a_Association]] :=
  Replace[a["Axes"], Gravifer`Einstoff`Internal`IR`AxisTable[x_Association] :> x];
publicNormalizedAxes[_] := <||>;
