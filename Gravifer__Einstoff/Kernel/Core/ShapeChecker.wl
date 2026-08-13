(* ::Package:: *)

(* Surface hygiene, inline-size capture, public axis rendering, and the small
   uniqueness predicate shared with operation planning. Semantic axis identity is
   allocated exclusively by Compiler.wl as operation-local integer-backed IR IDs. *)

PackageScoped[{validAxisNameQ, axisSymbol, axisDisplayName, axisCurrentValue,
  holdPublicBindingKeys,
  firstDuplicateAxis,
  inlineSizedAxis, prepareInlineHeld, collectSurfacePolicy,
  inlineHeldSpecs, inlineSpecInfo,
  distinctAxesQ}]

holdBindingKey[k_Symbol] :=
  ToExpression[axisDisplayName[Unevaluated[k]], InputForm, HoldPattern];
holdBindingKey[k_] := HoldPattern[k];

holdBindingKeys[a_Association] :=
  Association @ KeyValueMap[(holdBindingKey[#1] -> #2) &, a];

holdPublicBindingKeys[a_Association] :=
  Association @ KeyValueMap[
    If[#1 === "Bindings" && AssociationQ[#2],
      #1 -> holdBindingKeys[#2],
      #1 -> holdPublicBindingKeys[#2]] &, a];
holdPublicBindingKeys[l_List] := holdPublicBindingKeys /@ l;
holdPublicBindingKeys[x_] := x;


(* A legal axis name string: an identifier (letter/$ start, letters/digits/$ tail).
   Rolled locally, NOT ResourceFunction["ValidSymbolIdentifierQ"] — that RF's CodeParser
   backend is unavailable in some kernels (returns False for every input) and is ~150x
   slower with per-call cloud traffic (benchmarked). *)
validAxisNameQ[s_String] :=
  StringMatchQ[s, (LetterCharacter | "$") ~~ (LetterCharacter | DigitCharacter | "$") ...];
validAxisNameQ[_] := False;

(* --- inline axis-size wrappers --------------------------------------------------- *)
(* Annotation[axis,n] and Labeled[n,axis] are surface-only binding forms.  Normalize
   both targeting/sizing nesting orders to one private marker before name collection.
   Explicit rules (not anonymous Functions) are required because Slot[...] may occur in
   the captured axis specification. *)
inlineSizedNormalize[h_Hold] := FixedPoint[inlineSizedNormalizeStep, h];
inlineSizedNormalizeStep[e_] := e /. {
  Annotation[x_, n_] :> inlineSizedAxis[x, n, Annotation],
  Labeled[n_, x_] :> inlineSizedAxis[x, n, Labeled],
  Framed[inlineSizedAxis[x_, n_, src_]] :>
    inlineSizedAxis[Framed[x], n, src],
  Highlighted[inlineSizedAxis[x_, n_, src_]] :>
    inlineSizedAxis[Highlighted[x], n, src],
  Slot[inlineSizedAxis[x_, n_, src_]] :>
    inlineSizedAxis[Slot[x], n, src]
};

inlineSpecInfo[HoldComplete[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]]]] :=
  <|"Name" -> SymbolName[Unevaluated[s]], "Kind" -> "blank",
    "TargetHead" -> None, "Binder" -> True|>;
inlineSpecInfo[HoldComplete[s_Symbol]] /; Context[Unevaluated[s]] =!= "System`" :=
  <|"Name" -> SymbolName[Unevaluated[s]], "Kind" -> "bare",
    "TargetHead" -> None, "Binder" -> False|>;
inlineSpecInfo[HoldComplete[s_String]] /; validAxisNameQ[s] :=
  <|"Name" -> s, "Kind" -> "string", "TargetHead" -> None,
    "Binder" -> False|>;
inlineSpecInfo[HoldComplete[Highlighted[x_]]] :=
  inlineTargetInfo[Highlighted, inlineSpecInfo[HoldComplete[x]]];
inlineSpecInfo[HoldComplete[Framed[x_]]] :=
  inlineTargetInfo[Framed, inlineSpecInfo[HoldComplete[x]]];
inlineSpecInfo[HoldComplete[Slot[x_String]]] :=
  inlineTargetInfo[Slot, inlineSpecInfo[HoldComplete[x]]];
inlineSpecInfo[_] := $Failed;

inlineTargetInfo[_, $Failed] := $Failed;
inlineTargetInfo[head_, info_Association] :=
  Append[info, "TargetHead" -> head];

inlineHeldSpecs[h_Hold] := Cases[h,
  inlineSizedAxis[x_, n_, src_] :>
    <|"Spec" -> HoldComplete[x], "Size" -> HoldComplete[n], "Source" -> src|>,
  {0, Infinity}];

prepareInlineHeld[h_Hold] :=
  Module[{hn = inlineSizedNormalize[h], specs, bad, info, reason},
    (* Any remaining Annotation/Labeled has unsupported arity/nesting, or an inline
       wrapper was nested inside another inline axis specification. *)
    Which[
      ! FreeQ[hn, _Annotation | _Labeled, {0, Infinity}, Heads -> True],
        reason = "Annotation/Labeled axis sizes use exactly the forms " <>
          "Annotation[axis, positiveInteger] or Labeled[positiveInteger, axis]";
        Failure["InvalidInlineBinding", <|"Reason" -> reason|>],
      True,
        specs = inlineHeldSpecs[hn];
        bad = SelectFirst[specs,
          (info = inlineSpecInfo[# ["Spec"]]; info === $Failed) &,
          Missing["NotFound"]];
        If[MissingQ[bad],
          <|"Held" -> hn, "Specs" -> specs|>,
          reason = "inline axis size wrapper has an unsupported axis " <>
            ToString[bad["Spec"], InputForm] <>
            "; use one named bare/string/blank axis, optionally targeted";
          Failure["InvalidInlineBinding", <|"Reason" -> reason,
            "Source" -> bad|>]]]
  ];

(* All axis-name strings appearing anywhere in a held-or-plain expression (blanks,
   bare symbols, slot symbols/strings, string terms), hygienically.  Over-collects
   across kinds — used only for the composite-factor / on-LHS membership questions. *)
axisNamesOf[e_] := DeleteDuplicates @ Join[
  Cases[e, Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> SymbolName[Unevaluated[s]], {0, Infinity}],
  Cases[e, Slot[s_Symbol] :> SymbolName[Unevaluated[s]], {0, Infinity}],
  Cases[e, str_String :> str, {0, Infinity}],
  Cases[e, s_Symbol /; Context[s] =!= "System`" &&
      Unevaluated[s] =!= inlineSizedAxis :> SymbolName[Unevaluated[s]],
    {0, Infinity}]];

(* Collect all surface spelling/targeting observations without allocating symbols or
   mutating package state. The result is the complete capture policy consumed by the
   compiler and binding normalizer. *)
collectSurfacePolicy[h_Hold] :=
  Catch[Module[{slotNames, targetStringNames, symbolBracketNames, badSlotNames,
          hNoBracket, blankNames, hNoBlank, bareNames, stringNames,
          stringTierNames, allStr, bad, symslot, mish, inlineSpecs, inlineInfos,
          inlineNames, hNames, kinds = <||>, addKind, reject, established},
    addKind[name_String, kind_String] :=
      kinds = Append[kinds, name -> Union[Lookup[kinds, name, {}], {kind}]];
    reject[reason_String] := Throw[
      Failure["SurfacePolicy", <|"Reason" -> reason|>], surfacePolicyTag];
    inlineSpecs = inlineHeldSpecs[h];
    inlineInfos = inlineSpecInfo[# ["Spec"]] & /@ inlineSpecs;
    inlineNames = DeleteDuplicates[Lookup[inlineInfos, "Name", {}]];
    (* Inline sizes are captured expressions, not shape syntax.  Remove them from the
       tree used for all axis-name collection so a string/value in the size position is
       never mistaken for an axis name. *)
    hNames = h /. inlineSizedAxis[x_, _, src_] :> inlineSizedAxis[x, src];
    (* Every axis name inside ANY target wrapper is targeted. Slot["a"] is the targeted
       string spelling; Highlighted/Framed carry the blank/bare spelling inside them.
       Collect ALL names inside the wrapper (do NOT drop the whole wrapper, which would
       miss composite factors and leave them un-canonicalized). *)
    slotNames = DeleteDuplicates @ Flatten @
      Cases[hNames, (Slot | Highlighted | Framed)[xs___] :> axisNamesOf[Hold[xs]], {0, Infinity}];
    targetStringNames = DeleteDuplicates @ Flatten @
      Cases[hNames, (Slot | Highlighted | Framed)[xs___] :>
        Cases[Hold[xs], str_String :> str, {0, Infinity}], {0, Infinity}];
    symbolBracketNames = Complement[slotNames, targetStringNames];
    badSlotNames = DeleteDuplicates @ Flatten @ Cases[hNames,
      Slot[xs___] :> Join[
        Cases[Hold[xs],
          Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> SymbolName[Unevaluated[s]],
          {0, Infinity}],
        Cases[Hold[xs],
          s_Symbol /; Context[s] =!= "System`" :> SymbolName[Unevaluated[s]],
          {0, Infinity}]],
      {0, Infinity}];
    If[badSlotNames =!= {},
      reject["Slot[...] targets only string-kind axes; use Highlighted[...] or " <>
        "Framed[...] for blank/bare targeted axis " <> First[badSlotNames]]];
    (* Blanks anywhere — including inside a targeted composite. *)
    blankNames = Cases[hNames,
      Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> SymbolName[Unevaluated[s]],
      {0, Infinity}];
    (* Bare strings / bare symbols OUTSIDE any target wrapper (plain string and bare
       refs); names inside wrappers were already taken as targeted axes above. *)
    hNoBracket = hNames /. (Slot | Highlighted | Framed)[___] :> Null;
    hNoBlank = hNoBracket /. Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> Null;
    bareNames = Cases[hNoBlank,
      s_Symbol /; Context[s] =!= "System`" && Unevaluated[s] =!= inlineSizedAxis :>
        SymbolName[Unevaluated[s]], {0, Infinity}];
    stringNames = Cases[hNoBracket, str_String :> str, {0, Infinity}];
    (* validate every string-sourced name (targeted or bare) *)
    allStr = DeleteDuplicates @ Cases[hNames, str_String :> str, {0, Infinity}];
    bad = Select[allStr, ! validAxisNameQ[#] &];
    If[bad =!= {},
      reject["invalid axis name string(s): " <> ToString[bad, InputForm] <>
        " (an axis name must be a valid identifier)"]];
    Scan[addKind[#, "blank"] &, blankNames];
    Scan[addKind[#, "bare"] &, bareNames];
    Scan[addKind[#, "slot"] &, slotNames];
    stringTierNames = DeleteDuplicates @ Join[stringNames, targetStringNames];
    Scan[addKind[#, "string"] &, stringTierNames];
    Do[
      addKind[info["Name"], info["Kind"]];
      addKind[info["Name"], "inline-sized"];
      If[info["TargetHead"] =!= None,
        addKind[info["Name"], "target:" <>
          SymbolName[info["TargetHead"]]]],
      {info, inlineInfos}];
    Scan[addKind[#, "target:Slot"] &, DeleteDuplicates @ Flatten @
      Cases[hNames, Slot[xs___] :> Cases[Hold[xs], str_String :> str, {0, Infinity}],
        {0, Infinity}]];
    Scan[addKind[#, "target:Highlighted"] &, DeleteDuplicates @ Flatten @
      Cases[hNames, Highlighted[xs___] :> Cases[Hold[xs], str_String :> str, {0, Infinity}],
        {0, Infinity}]];
    Scan[addKind[#, "target:Framed"] &, DeleteDuplicates @ Flatten @
      Cases[hNames, Framed[xs___] :> Cases[Hold[xs], str_String :> str, {0, Infinity}],
        {0, Infinity}]];
    Scan[addKind[#, "target:Highlighted"] &, DeleteDuplicates @ Flatten @
      Cases[hNames, Highlighted[xs___] :> axisNamesOf[Hold[xs]], {0, Infinity}]];
    Scan[addKind[#, "target:Framed"] &, DeleteDuplicates @ Flatten @
      Cases[hNames, Framed[xs___] :> axisNamesOf[Hold[xs]], {0, Infinity}]];
    (* A name appearing inside a CircleTimes / CirclePlus is a composite factor. Blank
       composite factors are still infer-only; externally supplied split factors should
       be spelled bare or string.  (SPEC 7.2: Cases patterns, no Slot in a `&`.) *)
    Scan[addKind[#, "composite"] &,
      DeleteDuplicates @ Flatten @ Cases[hNames,
        (CircleTimes | CirclePlus)[xs___] :> axisNamesOf[Hold[xs]], {0, Infinity}]];
    (* A name appearing anywhere in the LHS shapes is inferable from a tensor. *)
    Scan[addKind[#, "onlhs"] &, axisNamesOf @ Extract[hNames, {1, 1}, Hold]];
    (* mishmash: string spelling (a bare string term or #a = Slot["a"]) mixed with the
       symbol spelling for one name. Highlighted/Framed add targetedness, not a new
       spelling kind; Slot["a"] is targeted string. *)
    symslot = DeleteDuplicates @ Join[blankNames, bareNames, symbolBracketNames];
    mish = Intersection[symslot, stringTierNames];
    If[mish =!= {},
      reject["axis " <> First[mish] <>
        " is spelled both as a symbol/bracket and as the string \"" <>
        First[mish] <> "\"; use one spelling consistently"]];
    established = DeleteDuplicates @
      Join[blankNames, slotNames, stringNames, inlineNames];
    <|"EstablishedNames" -> established, "AxisKinds" -> kinds|>
  ], surfacePolicyTag];

axisDisplayName[x_Symbol] := SymbolName[Unevaluated[x]];
axisDisplayName[x_] := ToString[x, InputForm];

(* Project a logical axis name to a user-facing symbol only at the public API boundary.
   A shadowed Global symbol cannot be returned without evaluating to its value, so use a
   deterministic inert display-context symbol with the same SymbolName. This projection
   never participates in compiler identity and requires no clearing, Unique token, or
   lifecycle memo. The legacy reserved context is inspected only to retain its warning
   for a Protected+Locked external value. *)
axisSymbol[nm_String] :=
  If[axisShadowedQ[nm],
    If[legacyAxisCompromisedQ[nm],
      Message[Einstoff::privctx, "Gravifer`Einstoff`Axis`" <> nm]];
    Symbol["Gravifer`Einstoff`Internal`DisplayAxis`" <> nm],
    Symbol[nm]];

legacyAxisCompromisedQ[nm_String] :=
  With[{full = "Gravifer`Einstoff`Axis`" <> nm},
    axisShadowedQ[full] &&
      ContainsAll[axisAttributes[full], {Protected, Locked}]];

axisAttributes[name_String] := Quiet @
  ToExpression[name, InputForm,
    Function[s, Attributes[Unevaluated[s]], HoldAllComplete]];
(* The user's symbol for an axis name, parsed to a held (HoldComplete) symbol so its
   value is never triggered.  The one delicate hold-discipline step, factored out so the
   two probes below (shadowed? / current value) cannot drift.  HoldComplete[s_Symbol]
   when the name parses to a symbol, else HoldComplete[_] (e.g. a number string). *)
heldAxisSymbol[name_String] := Quiet @ ToExpression[name, InputForm, HoldComplete];

(* True iff the user's symbol currently HAS a value (is shadowed).  The test is "has a
   value" (ValueQ), NOT "value =!= Null", so a symbol shadowed to Null counts as shadowed;
   ValueQ holds its argument, so the value itself is never evaluated. *)
axisShadowedQ[name_String] :=
  Replace[heldAxisSymbol[name], {HoldComplete[s_Symbol] :> ValueQ[s], _ :> False}];

(* The current value of an axis name, or Missing["Unbound"] when it has none — for the
   shadowed-key diagnostic only.  `s` is returned only after ValueQ[s] confirms a value,
   so it then evaluates to that value; Missing (not Null) is the unbound sentinel so a
   Null-shadowed symbol is not mistaken for unbound. *)
axisCurrentValue[name_String] :=
  Replace[heldAxisSymbol[name], {
    HoldComplete[s_Symbol] :> If[ValueQ[s], s, Missing["Unbound"]],
    _ :> Missing["Unbound"]}];

(* Axis-uniqueness predicate: True iff no axis name repeats *within a single shape* of
   `shapes` (a repeat is within-tensor contraction, which only Massage/Contract/einsum
   lower).  The boolean companion of `firstDuplicateAxis` (Parsing.wl), which names the
   offending axis for a diagnostic. Kept as a named predicate so planning has one
   spelling for this policy; `firstDuplicateAxis` supplies the public diagnostic name. *)
distinctAxesQ[shapes_List] := MissingQ[firstDuplicateAxis[shapes]];
