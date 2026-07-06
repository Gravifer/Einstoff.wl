(* ::Package:: *)

(* Einstoff shape checker -- shared shape-DSL hygiene and type-checking helpers.

   This file owns the desc-boundary axis canonicalization, binding-key policy,
   shape normalization, and small shape predicates used by both the public
   shape APIs (Parsing.wl) and the runtime lowerers.  It does not touch array
   values or emit native array operations; that remains in Lowering.wl and the
   operator-specific lowering files. *)

PackageScoped[{descParts, canonHeld, canonBindingList, deCanon, withAxisScope,
  withAxisScopeDeCanon, validAxisNameQ, axisSymbol, axisDisplayName,
  descFailReturn, descFailReason, purgeAxisContext, $axisFresh, $descRejectReason,
  $axisFallbackMemo,
  normUnitTerms, flattenDirectSum,
  normShapes, normHeldShapes, firstDuplicateAxis,
  distinctAxesQ, bracketWrapperQ, hasCirclePlus, einAxisCatch, $einAxisFail}]

(* --- desc-boundary evaluation hygiene: axis-identity canonicalization ------------ *)
(* Named axes have a spelling kind (blank `a_`, bare `a`, string "a") and an orthogonal
   targeted bit (`#a` = targeted string, Highlighted/Framed for targeted
   blank/bare).  A globally *shadowed* axis
   symbol (Block[{c=3}, …]) must not leak its value into an axis identity.  We fix this
   at the desc boundary: every *established* axis name (spelled as a blank, targeted,
   or string somewhere in the desc) is rewritten to a fresh, value-less Temporary
   symbol shared by all its occurrences; a *bare* symbol whose name is NOT established
   is left untouched, so it env-captures on ReleaseHold (a bound `k` reads as its
   literal dimension — the opt-in "bare = value" path, SPEC).  The fresh symbols live
   in a per-parse dynamic scope ($axisFresh), so the two desc parses every operator
   runs (descParts for atoms; EinstoffShapes/EinstoffMatch for sizes) mint the SAME
   identities.  These Unique-generated Temporary symbols normally do not escape: a top-level
   public return (EinstoffShapes / EinstoffParse) is de-canonicalized (deCanon maps them
   back to the user's names).  A NESTED public call inside an already-open operator scope
   intentionally skips deCanon (withAxisScopeDeCanon) — so a user callback invoked mid-
   operation CAN observe fresh identities (e.g. a$10 as a Bindings key) until any result it
   captured is dropped; that is accepted.  Either way, once the scope closes and such
   results are gone the symbols are unreferenced and eligible for GC.  Shared by both desc
   entry points (descParts here, parseDesc in the shape layer). *)

$axisFresh = None;   (* Association name->fresh while an axis scope is open, else None *)
$axisKind  = None;   (* Association name->{kinds}: blank/bare/slot/string             *)
$descRejectReason = None;  (* set by collectEstablished when it rejects a desc with an
                              accurate Einstoff::unsupp reason, so the generic
                              "desc must be of the form lhs :> rhs" is not ALSO emitted *)
$axisFallbackMemo = <||>;  (* name -> fresh identity, used ONLY when the private
                              Einstoff`Axis` token for a shadowed name is un-sanitizable
                              (Protected+Locked).  Block'd per operation (scope open / raw
                              EinstoffMatch), so occurrences unify within one op; the
                              Temporary fallback symbols are eligible for GC once the op's
                              result is dropped (best effort, not guaranteed). *)

(* Open a per-parse identity scope around an operator body.  Re-entrant: a nested call
   (an operator's own EinstoffShapes/EinstoffMatch) reuses the already-open scope, so
   both parses share one identity memo.  HoldFirst — the body is the operator Module. *)
SetAttributes[withAxisScope, HoldFirst];
withAxisScope[body_] :=
  If[AssociationQ[$axisFresh], body,
    Block[{$axisFresh = <||>, $axisKind = <||>, $descRejectReason = None,
           $axisFallbackMemo = <||>},
      purgeAxisContext[]; einAxisCatch[body, $Failed]]];

(* Like withAxisScope, but for the user-facing public entries (EinstoffShapes,
   EinstoffParse): if THIS call owns the scope (it was not already open), de-canonicalize
   the result — mapping fresh axis identities back to the user's names.  When nested
   inside an operator (scope already open) it returns the fresh-keyed result untouched,
   because the operator consumes those identities internally (e.g. env keys must match
   the fresh atoms it decomposed). *)
SetAttributes[withAxisScopeDeCanon, HoldFirst];
withAxisScopeDeCanon[body_] :=
  If[AssociationQ[$axisFresh], body,
    Block[{$axisFresh = <||>, $axisKind = <||>, $descRejectReason = None,
           $axisFallbackMemo = <||>},
      purgeAxisContext[]; einAxisCatch[holdPublicBindingKeys @ deCanon[body], $Failed]]];

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


(* Shared desc-shape failure return for the operators.  descParts returns $Failed for
   BOTH a structurally-malformed desc (not lhs :> rhs) AND a canonHeld hygiene reject
   (invalid axis name / tier mishmash) — but the latter has already emitted an accurate
   Einstoff::unsupp via collectEstablished (recorded in $descRejectReason).  So emit the
   generic "must be of the form lhs :> rhs" message ONLY when there is no accurate reason,
   avoiding the double / misleading second message.  Returns $Failed. *)
descFailReturn[] := (
  If[$descRejectReason === None,
    Message[Einstoff::unsupp, "desc must be of the form lhs :> rhs"]];
  $Failed);

(* The reason string for a desc-shape failure, for EinstoffShapes' Reason field: the
   accurate canonHeld reason if one was recorded, else the generic shape reason. *)
descFailReason[] :=
  If[StringQ[$descRejectReason], $descRejectReason,
    "desc must be of the form lhs :> rhs (or lhs -> rhs)"];

(* A legal axis name string: an identifier (letter/$ start, letters/digits/$ tail).
   Rolled locally, NOT ResourceFunction["ValidSymbolIdentifierQ"] — that RF's CodeParser
   backend is unavailable in some kernels (returns False for every input) and is ~150x
   slower with per-call cloud traffic (benchmarked). *)
validAxisNameQ[s_String] :=
  StringMatchQ[s, (LetterCharacter | "$") ~~ (LetterCharacter | DigitCharacter | "$") ...];
validAxisNameQ[_] := False;

(* Fresh Temporary identity for a name, memoized within the open scope. *)
mkFresh[name_String] :=
  Lookup[$axisFresh, name,
    With[{u = Unique[name <> "$", {Temporary}]}, AssociateTo[$axisFresh, name -> u]; u]];

recordKind[name_String, kind_String] :=
  $axisKind[name] = Union[Lookup[$axisKind, name, {}], {kind}];

bracketWrapperQ[expr_] := MemberQ[{Slot, Highlighted, Framed}, Head[Unevaluated[expr]]];

(* All axis-name strings appearing anywhere in a held-or-plain expression (blanks,
   bare symbols, slot symbols/strings, string terms), hygienically.  Over-collects
   across kinds — used only for the composite-factor / on-LHS membership questions. *)
axisNamesOf[e_] := DeleteDuplicates @ Join[
  Cases[e, Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> SymbolName[Unevaluated[s]], {0, Infinity}],
  Cases[e, Slot[s_Symbol] :> SymbolName[Unevaluated[s]], {0, Infinity}],
  Cases[e, str_String :> str, {0, Infinity}],
  Cases[e, s_Symbol /; Context[s] =!= "System`" :> SymbolName[Unevaluated[s]], {0, Infinity}]];

(* Collect axis-name kinds from the held desc without evaluating any symbol (names via
   SymbolName[Unevaluated[…]]).  Detect a spelling-kind "mishmash" (a name spelled BOTH
   as a symbol and as a string) and reject an invalid string identifier.  Returns the
   established names (blank/targeted/string — a bare-only name is NOT established) or
   $Failed on a rejected desc.  Populates $axisKind as a side effect. *)
collectEstablished[h_Hold] :=
  Module[{slotNames, targetStringNames, symbolBracketNames, badSlotNames, hNoBracket,
          blankNames, hNoBlank, bareNames, stringNames, stringTierNames, allStr, bad,
          symslot, mish, lhs, lhsNoSlot, lhsNoBinder, lhsBare, lhsBareEstablished},
    (* Every axis name inside ANY target wrapper is targeted. Slot["a"] is the targeted
       string spelling; Highlighted/Framed carry the blank/bare spelling inside them.
       Collect ALL names inside the wrapper (do NOT drop the whole wrapper, which would
       miss composite factors and leave them un-canonicalized). *)
    slotNames = DeleteDuplicates @ Flatten @
      Cases[h, (Slot | Highlighted | Framed)[xs___] :> axisNamesOf[Hold[xs]], {0, Infinity}];
    targetStringNames = DeleteDuplicates @ Flatten @
      Cases[h, (Slot | Highlighted | Framed)[xs___] :>
        Cases[Hold[xs], str_String :> str, {0, Infinity}], {0, Infinity}];
    symbolBracketNames = Complement[slotNames, targetStringNames];
    badSlotNames = DeleteDuplicates @ Flatten @ Cases[h,
      Slot[xs___] :> Join[
        Cases[Hold[xs],
          Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> SymbolName[Unevaluated[s]],
          {0, Infinity}],
        Cases[Hold[xs],
          s_Symbol /; Context[s] =!= "System`" :> SymbolName[Unevaluated[s]],
          {0, Infinity}]],
      {0, Infinity}];
    If[badSlotNames =!= {},
      With[{r = "Slot[...] targets only string-kind axes; use Highlighted[...] or \
Framed[...] for blank/bare targeted axis " <> First[badSlotNames]},
        $descRejectReason = r; Message[Einstoff::unsupp, r]];
      Return[$Failed]];
    (* Blanks anywhere — including inside a targeted composite. *)
    blankNames = Cases[h,
      Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> SymbolName[Unevaluated[s]],
      {0, Infinity}];
    (* Bare strings / bare symbols OUTSIDE any target wrapper (plain string and bare
       refs); names inside wrappers were already taken as targeted axes above. *)
    hNoBracket = h /. (Slot | Highlighted | Framed)[___] :> Null;
    hNoBlank = hNoBracket /. Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> Null;
    bareNames = Cases[hNoBlank,
      s_Symbol /; Context[s] =!= "System`" :> SymbolName[Unevaluated[s]], {0, Infinity}];
    stringNames = Cases[hNoBracket, str_String :> str, {0, Infinity}];
    (* validate every string-sourced name (targeted or bare) *)
    allStr = DeleteDuplicates @ Cases[h, str_String :> str, {0, Infinity}];
    bad = Select[allStr, ! validAxisNameQ[#] &];
    If[bad =!= {},
      With[{r = "invalid axis name string(s): " <> ToString[bad, InputForm] <>
          " (an axis name must be a valid identifier)"},
        $descRejectReason = r; Message[Einstoff::unsupp, r]];
      Return[$Failed]];
    Scan[recordKind[#, "blank"] &, blankNames];
    Scan[recordKind[#, "bare"] &, bareNames];
    Scan[recordKind[#, "slot"] &, slotNames];
    stringTierNames = DeleteDuplicates @ Join[stringNames, targetStringNames];
    Scan[recordKind[#, "string"] &, stringTierNames];
    Scan[recordKind[#, "target:Slot"] &, DeleteDuplicates @ Flatten @
      Cases[h, Slot[xs___] :> Cases[Hold[xs], str_String :> str, {0, Infinity}],
        {0, Infinity}]];
    Scan[recordKind[#, "target:Highlighted"] &, DeleteDuplicates @ Flatten @
      Cases[h, Highlighted[xs___] :> Cases[Hold[xs], str_String :> str, {0, Infinity}],
        {0, Infinity}]];
    Scan[recordKind[#, "target:Framed"] &, DeleteDuplicates @ Flatten @
      Cases[h, Framed[xs___] :> Cases[Hold[xs], str_String :> str, {0, Infinity}],
        {0, Infinity}]];
    Scan[recordKind[#, "target:Highlighted"] &, DeleteDuplicates @ Flatten @
      Cases[h, Highlighted[xs___] :> axisNamesOf[Hold[xs]], {0, Infinity}]];
    Scan[recordKind[#, "target:Framed"] &, DeleteDuplicates @ Flatten @
      Cases[h, Framed[xs___] :> axisNamesOf[Hold[xs]], {0, Infinity}]];
    (* A name appearing inside a CircleTimes / CirclePlus is a composite factor. Blank
       composite factors are still infer-only; externally supplied split factors should
       be spelled bare or string.  (SPEC 7.2: Cases patterns, no Slot in a `&`.) *)
    Scan[recordKind[#, "composite"] &,
      DeleteDuplicates @ Flatten @ Cases[h,
        (CircleTimes | CirclePlus)[xs___] :> axisNamesOf[Hold[xs]], {0, Infinity}]];
    (* A name appearing anywhere in the LHS shapes is inferable from a tensor. *)
    Scan[recordKind[#, "onlhs"] &, axisNamesOf @ Extract[h, {1, 1}, Hold]];
    (* mishmash: string spelling (a bare string term or #a = Slot["a"]) mixed with the
       symbol spelling for one name. Highlighted/Framed add targetedness, not a new
       spelling kind; Slot["a"] is targeted string. *)
    symslot = DeleteDuplicates @ Join[blankNames, bareNames, symbolBracketNames];
    mish = Intersection[symslot, stringTierNames];
    If[mish =!= {},
      With[{r = "axis " <> First[mish] <> " is spelled both as a symbol/bracket and as \
the string \"" <> First[mish] <> "\"; use one spelling consistently"},
        $descRejectReason = r; Message[Einstoff::unsupp, r]];
      Return[$Failed]];
    (* WL pattern semantics are load-bearing for the desc surface: a repeated inferred
       input axis is written a_ ... a_, not a_ ... a.  A bare symbol on the LHS is a
       literal/env-capture position unless it is inside Slot; if its name has already
       been established by a blank/target/string in this desc, accepting it as an axis
       reference would silently teach the wrong RuleDelayed spelling. *)
    lhs = Extract[h, {1, 1}, Hold];
    lhsNoSlot = lhs /. (Slot | Highlighted | Framed)[___] :> Null;
    lhsNoBinder = lhsNoSlot /. Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> Null;
    lhsBare = DeleteDuplicates @ Cases[lhsNoBinder,
      s_Symbol /; Context[s] =!= "System`" :> SymbolName[Unevaluated[s]], {0, Infinity}];
    lhsBareEstablished = Intersection[lhsBare,
      DeleteDuplicates @ Join[blankNames, slotNames, stringNames]];
    If[lhsBareEstablished =!= {},
      With[{r = "bare axis " <> First[lhsBareEstablished] <> " appears on the LHS after \
that name is established; write " <> First[lhsBareEstablished] <>
              "_ for each inferred input occurrence (e.g. repeated/contracted axes use \
a_ ... a_), or use targeted notation for targeted axes"},
        $descRejectReason = r; Message[Einstoff::unsupp, r]];
      Return[$Failed]];
    DeleteDuplicates @ Join[blankNames, slotNames, stringNames]];

(* Rewrite the held desc: every established name -> its fresh Temporary symbol, at
   blank / targeted / string / bare-reference positions.  Bare names that are NOT
   established are left untouched (they env-capture on ReleaseHold).  One ReplaceAll
   pass: the fresh symbols carry a distinct name ("a$nn"), so no rule re-fires on them.
   Assumes an open axis scope (via withAxisScope). *)
canonHeld[h_Hold] :=
  Module[{estab, rules},
    (* Fresh per parse: clear any reject reason left by a PRIOR (re-entrant) parse in the
       same scope, so a reason is never stale.  collectEstablished sets it only on reject. *)
    $descRejectReason = None;
    estab = collectEstablished[h];
    If[estab === $Failed, Return[$Failed]];
    Scan[mkFresh, estab];
    (* Table, not `&`/Map: the rule bodies contain Slot[...], which an anonymous
       Function would capture as its own argument slots (SPEC 7.2). *)
    rules = Flatten @ Table[
      With[{name = nm, fr = $axisFresh[nm]},
        {Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] /;
            SymbolName[Unevaluated[s]] === name :> Pattern[fr, Blank[]],
         Slot[s_Symbol] /; SymbolName[Unevaluated[s]] === name :> Slot[fr],
         Slot[name] :> Slot[fr],
         ss_String /; ss === name :> fr,
         s_Symbol /; Context[s] =!= "System`" &&
            SymbolName[Unevaluated[s]] === name :> fr}],
      {nm, estab}];
    h /. rules];

(* Map fresh internal axis symbols back to symbols of their original user names, for
   user-facing output (EinstoffParse's normalized desc, EinstoffShapes' Bindings /
   Targeted).  Replaces at all levels including Association keys.  Outside a scope, or
   with no axes, it is the identity.  A shadowed name maps back to its (valued) symbol —
   acceptable for display; the engine already ran on the fresh identities. *)
deCanon[expr_] :=
  If[AssociationQ[$axisFresh] && Length[$axisFresh] > 0,
    deCanonApply[expr, Table[$axisFresh[nm] -> axisSymbol[nm], {nm, Keys[$axisFresh]}]],
    expr];

(* The user-facing display name of an axis identity, for interpolation into Reason /
   Message text (which deCanon cannot reach — a name baked into a string has no symbol
   subpart to rewrite).  A fresh canonical symbol maps back to its user name via the
   $axisFresh inverse; any other symbol (a raw plain / Einstoff`Axis` axis) uses its
   short SymbolName (drops the private context); a non-symbol prints via ToString.  Axis
   identities are always value-less (fresh / private-context / unbound), so evaluating x
   here is an identity — no shadowed value can leak. *)
axisDisplayName[x_] :=
  Module[{hit},
    (* map a canonical identity back to its user name: the scoped $axisFresh inverse, then
       the Protected+Locked fallback memo; else a plain symbol's short SymbolName. *)
    hit = If[AssociationQ[$axisFresh],
      SelectFirst[Keys[$axisFresh], $axisFresh[#] === x &], Missing[]];
    If[MissingQ[hit],
      hit = SelectFirst[Keys[$axisFallbackMemo], $axisFallbackMemo[#] === x &]];
    Which[
      ! MissingQ[hit], hit,
      Head[x] === Symbol, SymbolName[x],
      True, ToString[x, InputForm]]];
(* The axis symbol for a (validated) name string, without leaking a shadowed global.
   If the user's symbol is UNBOUND, use it directly (the clean Global`nm the caller
   expects).  If it is SHADOWED (Block[{c=3},…] — or even Block[{c=Null},…]), Symbol[nm]
   would evaluate to the value and leak it, so instead use a value-less symbol of the
   same name in a private context — SymbolName stays "nm", but no global value can leak.
   The test is *has a value* (ValueQ), NOT *value =!= Null*, so a symbol shadowed to Null
   is still treated as shadowed.  Deterministic per name, so every spelling of one axis
   ("a" / targeted string wrappers / a composite factor "a") maps to the SAME identity
   and unifies.
   Shared by deCanon (display) and the raw EinstoffMatch string-tier path (Parsing.wl),
   which would otherwise leak a shadowed global into env keys. *)
axisSymbol[nm_String] :=
  If[axisShadowedQ[nm],
    (* A shadowed name needs an identity other than the (valued) global symbol.  Prefer a
       value-less token in our private Einstoff`Axis` context (its SymbolName stays "nm").
       That context is sanitized ONCE per operation by purgeAxisContext (at the scope /
       raw-match boundary), NOT here on every call.  So here we only read the (already-
       sanitized) token: if it is STILL valued it is Protected+Locked and un-sanitizable, so
       fall back to a fresh unreachable identity; otherwise use it. *)
    If[axisShadowedQ["Einstoff`Axis`" <> nm],
      (* MEMOIZED per name (per-operation memo): axisSymbol is called once per occurrence,
         so a fresh Unique each time would give repeated occurrences of one name DIFFERENT
         identities and they would not unify.  Mint (and warn) once on the first miss. *)
      Lookup[$axisFallbackMemo, nm,
        (Message[Einstoff::privctx, "Einstoff`Axis`" <> nm];
         (* Mint in our OWN Einstoff`Fallback` context (not the caller's, usually Global`),
            Temporary so a Unique-generated token is eligible for GC once unreferenced (best
            effort — an outstanding result holding it as a key keeps it alive).  A separate
            context from Einstoff`Axis`, and the fresh number makes it unreachable.  If even
            this fresh token is somehow valued, the Fallback context itself is compromised —
            give up (Throw -> $Failed / ok->False). *)
         With[{u = Block[{$Context = "Einstoff`Fallback`", $ContextPath = {"System`"}},
             Unique[nm <> "$", {Temporary}]]},
           If[axisShadowedQ["Einstoff`Fallback`" <> SymbolName[u]],
             Throw[$Failed, $einAxisFail]];
           AssociateTo[$axisFallbackMemo, nm -> u]; u])],
      (* sanitizable: value-less private token.  Tagged Temporary as a hint, but a
         Symbol[…]-created token is not owned by a scope, so the name is not reliably
         GC'd — inert Einstoff`Axis` names may persist (see purgeAxisContext).  The value
         is the only thing that mattered, and it is gone. *)
      With[{s = Symbol["Einstoff`Axis`" <> nm]}, SetAttributes[s, Temporary]; s]],
    Symbol[nm]];

(* Sanitize the reserved Einstoff`Axis` identity context ONCE at an operation boundary: a
   user must not populate it, but as a defense drop any external VALUE.  CLEAR-ONLY (Clear,
   not ClearAll, and never Remove):
   - Clear removes only values (works even on a Locked symbol — Clear does not touch
     attributes), which is all we need: a value is the only thing that could leak.
   - NOT Remove: a token minted for a shadowed axis can already be a live KEY in a public
     result an earlier call returned (an EinstoffMatch env / EinstoffShapes Bindings).
     Remove would rewrite that key to Removed["…"], silently corrupting a result the user
     still holds.  A previously returned association must NOT decay because a later
     operation ran.  Leaving an inert, value-less name behind is harmless by comparison.
   - NOT ClearAll: it strips attributes (harmless-but-pointless here).
   A Protected+Locked token survives (Locked blocks Unprotect, Protected blocks Clear) and
   is handled by the axisSymbol fallback above.
   NB on accumulation: this purge clears VALUES, not names — inert, value-less
   Einstoff`Axis` symbol NAMES do accumulate across calls, and are NOT reliably reclaimed
   (a Symbol[…]-created token tagged Temporary is not owned by any scope, so nothing
   triggers its collection; the names persist even after ClearSystemCache).  That is an
   accepted tradeoff: leaking a value or corrupting a returned result (Remove -> Removed[…])
   is far worse than leaving reserved-context names behind.  A bounded, non-mutating sweep
   would need to skip any name still live as a key in an outstanding result — deferred. *)
purgeAxisContext[] :=
  Quiet[Unprotect["Einstoff`Axis`*"]; Clear["Einstoff`Axis`*"]];

(* Catch the axis-context-compromised abort (an un-mintable Einstoff`Fallback` token) and
   yield `fail`.  HoldFirst on the body; the fail value is eager. *)
SetAttributes[einAxisCatch, HoldFirst];
einAxisCatch[body_, fail_] := Catch[body, $einAxisFail, (fail) &];
(* ReplaceAll does not rewrite Association KEYS, so recurse: remap keys and values of
   every Association; a held desc (RHS) and plain shapes just take the value rules. *)
deCanonApply[a_Association, rules_] :=
  Association @ KeyValueMap[(Replace[#1, rules] -> deCanonApply[#2, rules]) &, a];
deCanonApply[l_List, rules_] := deCanonApply[#, rules] & /@ l;
deCanonApply[x_, rules_] := x /. rules;

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

(* Normalize + validate `bindings` for the matcher, in one of two modes — the single
   place binding-key policy lives.  "Scoped" (an open desc axis scope: the operator /
   EinstoffShapes path) canonicalizes each key against the parsed desc's axis identities
   ($axisFresh / $axisKind): a key naming an *established* axis becomes its fresh symbol,
   tier / Pattern / inference-only violations hard-reject, and a shadowed/junk key is
   warned and dropped; an unestablished key is left as-is.  "Raw" (standalone
   EinstoffMatch, no scope) converts a string-tier key "a" -> n and a prevalidated
   bracket key #a = Slot["a"] -> n to axisSymbol["a"] -> n (the same identity
   matchTerms' StringQ term and Slot splice use), validating the name so an illegal
   string is a clean reject rather than a Symbol::symname crash; other keys pass to the
   _Symbol / dup / size checks in EinstoffMatch.  Returns the normalized list, or a
   reason string on a hard reject. *)
canonBindingList[bindings_, mode_] :=
  Module[{out = {}},
    If[! MatchQ[bindings, {(_Rule | _RuleDelayed) ...}], Return[bindings]];
    If[mode === "Raw",
      Return[Catch[
        Replace[bindings,
          (* string key "a" -> n, or the canonical slot key #a = Slot["a"] -> n: both
             name the string-kind axis `a`.  Bare-symbol Slot[a] is not canonical, is
             evaluation-fragile (a shadowed a makes the key Slot[3] before we see it),
             and is left for the _Symbol/dup/size checks to reject. *)
          (h : (Rule | RuleDelayed))[(k_String) | Slot[k_String], v_] :>
            If[validAxisNameQ[k], h[axisSymbol[k], v],
              Throw["invalid axis name \"" <> k <> "\" in a binding key \
(must be a valid identifier)", "cblReject"]],
          {1}],
        "cblReject"]]];
    (* mode === "Scoped".  A hard reject Throws its reason string past the per-entry
       Module and the Do; a plain Return there would only exit the inner Module. *)
    Catch[
      Do[
        Module[{k = First[bd], v = Last[bd], kn, kk, kinds, hasBlank, hasSlot, hasStr,
                targetKinds, targetKeyQ, hit},
          (* classify the (already-evaluated) key *)
          Which[
            (* a Pattern key r_ -> n / r_ :> n: Pattern is HoldFirst so it survives
               evaluation.  It is never a binding — hard reject below. *)
            MatchQ[k, Verbatim[Pattern][_Symbol, Verbatim[Blank[]]]],
              kn = Replace[k,
                Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> SymbolName[Unevaluated[s]]];
              kk = "pattern",
            MatchQ[k, (_Slot | _Highlighted | _Framed)] && Length[k] === 1,
              kn = Replace[First[k],
                {s_Symbol :> SymbolName[Unevaluated[s]], str_String :> str, _ :> $Failed}];
              kk = "target:" <> SymbolName[Head[k]],
            StringQ[k], kn = k; kk = "string",
            (* An evaluated shadow-capture whose value is a System` symbol (e.g. {c->2}
               under c=Null arrives as {Null->2}; also True/False/E/…): never a legal axis
               name (axis names are always non-System), so treat it as junk — warned and
               dropped, not a bare axis "Null".  NB `Context` is HoldFirst, so `Context[k]`
               would inspect the Module local k rather than the key VALUE; `Evaluate[k]`
               forces the value through (`SymbolName[k]` already evaluates, since
               SymbolName is not HoldFirst). *)
            Head[k] === Symbol && Context[Evaluate[k]] === "System`",
              kn = $Failed; kk = "junk",
            (* a bare (unbound) non-System symbol is a legacy bare axis key *)
            Head[k] === Symbol, kn = SymbolName[k]; kk = "bare",
            True, kn = $Failed; kk = "junk"];
          Which[
            (* a Pattern key is a category error — the axis is sized by its name, not a
               matcher.  Reject with a redirect (never silently ignore). *)
            kk === "pattern",
              Throw["a Pattern key " <> kn <> "_ -> … is not a binding key; blank " <> kn <>
                "_ is inferred from the tensor; use a string, bare, or matching targeted key",
                "cblReject"],
            (* junk key (an evaluated shadowed symbol, e.g. {3->2} from c=3): warn + drop *)
            kn === $Failed,
              hit = SelectFirst[Keys[$axisFresh], axisCurrentValue[#] === k &];
              Message[Einstoff::evalkey,
                If[MissingQ[hit],
                  "binding key " <> ToString[k, InputForm] <>
                    " is not an axis name; ignoring it",
                  "binding key " <> ToString[k, InputForm] <> " is the current value of \
axis " <> hit <> " (probably a shadowed symbol); write #" <> hit <> " -> … or \"" <>
                    hit <> "\" -> …; ignoring it"]],
            (* key names an established axis: check the spelling kind, canonicalize *)
            KeyExistsQ[$axisFresh, kn],
              kinds = Lookup[$axisKind, kn, {}];
              hasBlank = MemberQ[kinds, "blank"];
              hasSlot = MemberQ[kinds, "slot"]; hasStr = MemberQ[kinds, "string"];
              targetKinds = Select[kinds, StringStartsQ[#, "target:"] &];
              targetKeyQ = StringStartsQ[kk, "target:"];
              Which[
                (* A blank on the LHS is inference-only everywhere, including inside
                   CircleTimes/CirclePlus.  To supply a composite factor size, spell that
                   factor as a string axis or a bare axis instead of a blank. *)
                MemberQ[kinds, "onlhs"] && hasBlank,
                  Throw["axis " <> kn <> " is inferred from the tensor (blank " <> kn <>
                    "_); to supply a size, spell the factor as a string \"" <> kn <>
                    "\" or as a bare symbol " <> kn, "cblReject"],
                kk === "target:Slot" && ! hasStr,
                  Throw["Slot[...] binding keys only target string-kind axes; use " <> kn <>
                    " -> … or the matching Highlighted/Framed key for symbol-kind axes",
                    "cblReject"],
                targetKeyQ && ! MemberQ[targetKinds, kk],
                  Throw["axis " <> kn <> " is not targeted with " <>
                    StringDelete[kk, "target:"] <> "[...] in the desc; bind it with " <>
                    If[hasStr, "\"" <> kn <> "\"", kn] <> " -> … or the matching target head",
                    "cblReject"],
                hasStr && kk =!= "string" && ! targetKeyQ,
                  Throw["axis \"" <> kn <> "\" is a string axis; bind it with \"" <> kn <>
                    "\" -> …, not " <> ToString[k, InputForm], "cblReject"],
                hasSlot && ! hasStr && kk === "string",
                  Throw["axis " <> kn <> " is a targeted symbol-kind axis; bind it with " <>
                    kn <> " -> … or the matching target-head key, not a string key",
                    "cblReject"],
                True, AppendTo[out, $axisFresh[kn] -> v]],
            (* key names no established axis: leave as-is (legacy bare/unbound axis) *)
            True, AppendTo[out, k -> v]]],
        {bd, bindings}];
      out,
      "cblReject"]];

(* --- desc-boundary canonicalization (shared by both entry points) ---------------- *)
(* Two orthogonal normalizations are applied once at the desc boundary so all
   downstream code sees a single spelling: {} unit terms become the literal 1, and
   nested CirclePlus is flattened.  descParts (here) and parseDesc (the shape layer)
   both route through normShapes / normHeldShapes below — the only difference is that
   the shape layer keeps the RHS held.  Keeping the policy in one place stops the two
   boundaries from drifting apart as the grammar evolves. *)

(* Normalize an in-shape unit term {} to the literal 1, at any depth WITHIN each shape
   (including inside a CircleTimes/CirclePlus), while leaving a whole-shape {} as a
   scalar (rank-0 operand).  So `{}` and `1` are the same unit axis in every term
   position; only a shape that *is* {} stays scalar. *)
normUnitTerms[shapes_] :=
  Replace[shapes, sh_List :> If[sh === {}, {}, sh /. {} -> 1], {1}];

(* CirclePlus (direct sum) is associative; canonicalize a ⊕ (b ⊕ c) to one flat summand
   list so the direct-sum paths see a single CirclePlus with all summands.  WL gives
   CirclePlus no attributes (neither Flat nor Orderless), so it does not collapse the
   nesting on its own; flattening preserves order (CirclePlus is not Orderless), which
   direct sum requires. *)
flattenDirectSum[expr_] :=
  expr //. CirclePlus[x___, CirclePlus[y___], z___] :> CirclePlus[x, y, z];

(* The one canonicalizer, in two forms for the two entry points.  normShapes normalizes
   a *released* list of shapes; normHeldShapes a *held* one (the shape layer holds the
   RHS so a globally-bound symbol is not released before its value is substituted).  Both
   apply the same policy: {} unit terms -> 1 and nested CirclePlus flattened.  In the held
   form the {} -> 1 rule runs at levels >= 3 of Hold[{shape, ...}] — term positions and
   deeper, never a level-2 whole-shape {} — matching normUnitTerms on the released form. *)
normShapes[shapes_] := flattenDirectSum @ normUnitTerms @ shapes;
normHeldShapes[hshapes_Hold] :=
  flattenDirectSum @ Replace[hshapes, {} -> 1, {3, Infinity}];

(* Operators are HoldFirst and pass Hold[desc]; descParts releases the RHS (at lowering
   time RHS symbols are atom labels, not values to substitute) and canonicalizes both
   sides.  parseDesc (Parsing.wl) is the held-RHS twin. *)
containsRepeatedTermQ[expr_] := ! FreeQ[HoldComplete[expr],
  Verbatim[Repeated][_] | Verbatim[RepeatedNull][_] |
    Verbatim[Pattern][_, Verbatim[Repeated][_]] |
    Verbatim[Pattern][_, Verbatim[RepeatedNull][_]] |
    Verbatim[Pattern][_, Verbatim[BlankSequence[]]] |
    Verbatim[Pattern][_, Verbatim[BlankNullSequence[]]]];

descParts[h : Hold[_Rule | _RuleDelayed]] :=
  Module[{hr = canonHeld[h]},
    If[hr === $Failed, $Failed,
      If[containsRepeatedTermQ[hr],
        Message[Einstoff::unsupp,
          "named axis-sequences are supported only for shape \
resolution for now; data lowering is deferred"];
        Return[$Failed]];
      {normShapes @ Extract[hr, {1, 1}],
       normShapes @ ReleaseHold @ Extract[hr, {1, 2}, Hold]}]];
(* a structurally-malformed desc (not lhs :> rhs): no canonHeld ran, so clear any stale
   reject reason from a prior parse (P3a) — the generic desc-shape message must fire *)
descParts[_] := ($descRejectReason = None; $Failed);

(* Does any shape in `shapes` contain a CirclePlus (direct-sum) term?  Used to
   route a desc into the direct-sum path and to guard Join/Split direction. *)
hasCirclePlus[shapes_] := ! FreeQ[shapes, CirclePlus];

(* Axis-uniqueness predicate: True iff no axis name repeats *within a single shape* of
   `shapes` (a repeat is within-tensor contraction, which only Massage/Contract/einsum
   lower).  The boolean companion of `firstDuplicateAxis` (Parsing.wl), which names the
   offending axis for a diagnostic.  The non-contracting operators (reduce/map/dot/
   direct-sum) guard with an explicit `If[! distinctAxesQ[lhs], Message[..]; Return[$Failed]]`
   — NOT a `/;`/`?`-gated definition — because they must emit a tailored Einstoff::unsupp
   message and return $Failed, whereas a failed pattern test would leave the call
   unevaluated (no message, breaking the `=== $Failed` contract).  Kept as a named predicate
   so the yes/no question has one spelling; `firstDuplicateAxis` supplies the axis on the
   reject path. *)
distinctAxesQ[shapes_List] := MissingQ[firstDuplicateAxis[shapes]];
