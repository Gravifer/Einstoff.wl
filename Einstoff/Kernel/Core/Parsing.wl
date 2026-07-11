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

   Structured Package Format: public symbols are declared with
   PackageExported (they land in the `Einstoff`` context); every helper below
   is left undeclared and is therefore private to this file
   (`Einstoff`Parsing`Private``). *)

PackageExported[{
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
EinstoffParse[desc_] := withAxisScopeDeCanon @ parseDesc[Hold[desc]];

(* Both desc-boundary canonicalizers (normShapes released, normHeldShapes held) and
   canonHeld are shared through ShapeChecker.wl.  parseDesc is the held-RHS
   twin of descParts: it keeps the RHS held so EinstoffParse returns a normalized desc
   whose (fresh-canonicalized) axis symbols are not released before their sizes are
   substituted (evalOutShape releases it later under env).  Same {} -> 1 + CirclePlus-
   flatten policy as descParts; the LHS is flattened so the matcher (solveComposite) sees
   a flat summand list.  canonHeld rewrites every established axis name — blank `a_`,
   targeted #a/Highlighted/Framed, string "a" — to a fresh Temporary identity shared
   across its occurrences, so a shadowed global symbol cannot leak its value into an
   axis (and targeted strings are context-safe). *)
parseDesc[h : Hold[_RuleDelayed]] :=
  Module[{hr = canonHeld[h], rhs},
    If[hr === $Failed, <|"LHS" -> $Failed, "RHS" -> $Failed|>,
      rhs = normHeldShapes @ Extract[hr, {1, 2}, Hold];
      If[! declarativeRhsQ[compileDeclarativeRhsSurface[rhs]],
        $descRejectReason = "the descriptor RHS contains non-declarative WL computation";
        <|"LHS" -> $Failed, "RHS" -> $Failed|>,
        <|"LHS" -> normShapes @ Extract[hr, {1, 1}], "RHS" -> rhs|>]]];
parseDesc[h : Hold[_Rule]] :=
  Module[{hr = canonHeld[h], rhs},
    If[hr === $Failed, <|"LHS" -> $Failed, "RHS" -> $Failed|>,
      rhs = normHeldShapes @ Extract[hr, {1, 2}, Hold];
      If[! declarativeRhsQ[compileDeclarativeRhsSurface[rhs]],
        $descRejectReason = "the descriptor RHS contains non-declarative WL computation";
        <|"LHS" -> $Failed, "RHS" -> $Failed|>,
        <|"LHS" -> normShapes @ Extract[hr, {1, 1}], "RHS" -> rhs,
          "Warning" -> "prefer :> (RuleDelayed) over -> for desc"|>]]];
(* a structurally-malformed desc (not lhs :> rhs): no canonHeld ran, so clear any stale
   reject reason from a prior re-entrant parse (P3a) — EinstoffShapes' Reason must fall
   back to the generic desc-shape reason, not a stale invalid-name reason. *)
parseDesc[_] := ($descRejectReason = None; <|"LHS" -> $Failed, "RHS" -> $Failed|>);

(* Names that appear inside a target wrapper anywhere in lhs. By the time this
   runs the desc has been through canonHeld, so #name is Slot[freshSym] and a targeted
   blank is Highlighted[fresh_]/Framed[fresh_]. Used only for the informational
   "Targeted" field (§5.2); the fresh symbols are mapped back
   to the user's names by deCanon on the public output. *)
targetedNames[lhs_] :=
  DeleteDuplicates @ Flatten @
    Cases[lhs,
      s_ /; bracketWrapperQ[s] :>
        Cases[s, n_Symbol /; Context[n] =!= "System`" :> n, {0, Infinity}],
      {0, Infinity}];

rawSlotAxisNames[expr_] := DeleteDuplicates @ Flatten @ Cases[expr,
  sl_Slot :> Join[
    Cases[sl,
      Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> SymbolName[Unevaluated[s]],
      {0, Infinity}],
    Cases[sl,
      s_Symbol /; Context[s] =!= "System`" :> SymbolName[Unevaluated[s]],
      {0, Infinity}],
    Cases[sl,
      str_String /; validAxisNameQ[str] :> str,
      {0, Infinity}]],
  {0, Infinity}];

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
  withAxisScopeDeCanon @ Catch[
    Module[{compiled, normalized, solvedBundle, solved, solvedAssoc, axes, env},
      compiled = Quiet[compileMatchIR[lhsShapes, bindingsIn], {Einstoff::unsupp}];
      normalized = Lookup[compiled, "Normalized", Missing["Normalized"]];
      If[Head[normalized] =!= Einstoff`Internal`IR`NormalizedDesc,
        Throw[<|"ok" -> False,
          "reason" -> publicFailureReason[normalized, None]|>, publicMatchTag]];
      solvedBundle = solveDescIR[compiled, inputShapes];
      solved = Lookup[solvedBundle, "Solved", Missing["Solved"]];
      If[Head[solved] =!= Einstoff`Internal`IR`SolvedDesc,
        Throw[<|"ok" -> False,
          "reason" -> publicFailureReason[solved, normalized]|>, publicMatchTag]];
      solvedAssoc = Replace[solved,
        Einstoff`Internal`IR`SolvedDesc[a_Association] :> a];
      axes = publicNormalizedAxes[normalized];
      env = Association @ KeyValueMap[
        Function[{id, size}, publicAxisKey[id, axes] -> size],
        KeySelect[solvedAssoc["AxisSizes"],
          MatchQ[#, Einstoff`Internal`IR`AxisId[_Integer]] &]];
      <|"ok" -> True, "env" -> env|>
    ], publicMatchTag];

SetAttributes[compileMatchIR, HoldFirst];
compileMatchIR[lhs_, bindings_] :=
  compileHeldDescIR[Hold[lhs :> {}], HoldComplete[bindings], "Match", <||>];

SetAttributes[EinstoffShapes, HoldFirst];
EinstoffShapes[desc_, inputShapes_, bindings_ : {}] := withAxisScopeDeCanon @
  Catch[Module[{compiled, normalized, normalizedAssoc, axes, targetedIds,
          targeted, duplicate, solvedBundle, solved, solvedAssoc, bindingsOut},
    compiled = compileHeldDescIR[Hold[desc], HoldComplete[bindings], "Shapes", <||>];
    normalized = Lookup[compiled, "Normalized", Missing["Normalized"]];
    If[Head[normalized] =!= Einstoff`Internal`IR`NormalizedDesc,
      Throw[publicShapesFailure[normalized, None, {}], publicShapesTag]];
    normalizedAssoc = Replace[normalized,
      Einstoff`Internal`IR`NormalizedDesc[a_Association] :> a];
    axes = Replace[normalizedAssoc["Axes"],
      Einstoff`Internal`IR`AxisTable[a_Association] :> a];
    targetedIds = DeleteDuplicates @ Cases[normalizedAssoc["Inputs"],
      Einstoff`Internal`IR`AxisOccurrence[_, id_, meta_Association] /;
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
    If[Head[solved] =!= Einstoff`Internal`IR`SolvedDesc,
      Throw[publicShapesFailure[solved, normalized, targeted], publicShapesTag]];
    solvedAssoc = Replace[solved,
      Einstoff`Internal`IR`SolvedDesc[a_Association] :> a];
    bindingsOut = Association @ KeyValueMap[
      Function[{id, size}, publicAxisKey[id, axes] -> size],
      KeySelect[solvedAssoc["AxisSizes"],
        MatchQ[#, Einstoff`Internal`IR`AxisId[_Integer]] &]];
    <|"Satisfiable" -> True, "OutputShapes" -> solvedAssoc["OutputShapes"],
      "Bindings" -> bindingsOut, "Targeted" -> targeted, "Reason" -> ""|>
  ], publicShapesTag];

publicDuplicateOutputAxis[Einstoff`Internal`IR`Outputs[shapes_List]] :=
  SelectFirst[shapes,
    Function[shape, With[{ids = Cases[shape,
        Einstoff`Internal`IR`AxisOccurrence[_, id_, _] :> id, Infinity]},
      ! DuplicateFreeQ[ids]]], Missing["NoDuplicate"]] /.
    Einstoff`Internal`IR`Shape[terms_List] :>
      First @ Select[Cases[terms,
        Einstoff`Internal`IR`AxisOccurrence[_, id_, _] :> id, Infinity],
        Count[Cases[terms,
          Einstoff`Internal`IR`AxisOccurrence[_, other_, _] :> other, Infinity], #] > 1 &];
publicDuplicateOutputAxis[_] := Missing["NoDuplicate"];

publicAxisName[id_, axes_Association] := Replace[Lookup[axes, id, Missing[]],
  Einstoff`Internal`IR`AxisInfo[name_String, _Association] :> name];
publicAxisKey[id_, axes_Association] :=
  With[{name = publicAxisName[id, axes]},
    If[AssociationQ[$axisFresh] && KeyExistsQ[$axisFresh, name],
      $axisFresh[name], axisSymbol[name]]];

publicShapesFailure[failure_, normalized_, targeted_List] :=
  <|"Satisfiable" -> False,
    "Reason" -> publicFailureReason[failure, normalized],
    "OutputShapes" -> Missing[], "Bindings" -> <||>,
    "Targeted" -> targeted|>;

publicFailureReason[
    Einstoff`Internal`IR`FailureRecord[_, _, details_Association], _] /;
      StringQ[Lookup[details, "Reason", None]] := details["Reason"];
publicFailureReason[
    Einstoff`Internal`IR`FailureRecord["MalformedDescription", _, _], _] :=
  "description must be of the form lhs :> rhs (or lhs -> rhs), with each side a list of shapes";
publicFailureReason[
    Einstoff`Internal`IR`FailureRecord["OperandCountMismatch", _, d_Association], _] :=
  "operand count: desc has " <> ToString[d["Expected"]] <> " shape(s) but " <>
    ToString[d["Actual"]] <> " tensor shape(s) given";
publicFailureReason[
    Einstoff`Internal`IR`FailureRecord["ConflictingAxisSizes", _, d_Association],
    normalized_] :=
  With[{axes = publicNormalizedAxes[normalized]},
    "axis " <> publicAxisName[d["Axis"], axes] <> ": expected " <>
      ToString[d["Expected"]] <> " but tensor dimension is " <>
      ToString[d["Actual"]]];
publicFailureReason[
    Einstoff`Internal`IR`FailureRecord["ConflictingBindingFacts", _, d_Association],
    normalized_] :=
  With[{name = Lookup[d, "Name",
      publicAxisName[Lookup[d, "Axis", Missing[]], publicNormalizedAxes[normalized]]]},
    "conflicting sizes for axis " <> name <> ": " <>
      StringRiffle[ToString[#, InputForm] & /@ d["Values"], " versus "]];
publicFailureReason[
    Einstoff`Internal`IR`FailureRecord["RankMismatch", _, _], _] :=
  "no consistent axis binding (shape/rank mismatch)";
publicFailureReason[
    Einstoff`Internal`IR`FailureRecord["InvalidInputShapes", _, _], _] :=
  "input shapes must be a list of dimension lists";
publicFailureReason[
    Einstoff`Internal`IR`FailureRecord["InvalidKnownSize", _, _], _] :=
  "each binding must give a positive-integer axis size";
publicFailureReason[
    Einstoff`Internal`IR`FailureRecord["SequenceZipLengthMismatch", _, _], _] :=
  "captured axis sequences have different lengths";
publicFailureReason[Einstoff`Internal`IR`FailureRecord[tag_, _, _], _] :=
  "shape constraints are not satisfiable (" <> tag <> ")";
publicFailureReason[_, _] := "shape constraints are not satisfiable";

publicNormalizedAxes[Einstoff`Internal`IR`NormalizedDesc[a_Association]] :=
  Replace[a["Axes"], Einstoff`Internal`IR`AxisTable[x_Association] :> x];
publicNormalizedAxes[_] := <||>;
