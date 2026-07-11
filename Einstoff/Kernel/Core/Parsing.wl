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

(* ------------------------------------------------------------------ *)
(* Unification of an axis name to a concrete size.                     *)
(* ------------------------------------------------------------------ *)

unify[n_, d_, env_] :=
  If[KeyExistsQ[env, n],
    If[env[n] === d, env,
      (* axisDisplayName maps a fresh canonical symbol back to the user's axis name, so
         the reason reads "axis a: …" not the internal "axis a$11: …". *)
      (Sow["axis " <> axisDisplayName[n] <> ": expected " <> ToString[env[n]] <>
           " but tensor dimension is " <> ToString[d]]; $Failed)],
    Append[env, n -> d]];

(* ------------------------------------------------------------------ *)
(* Matcher state.  Scalar axis sizes stay in "Env"; named axis-sequence *)
(* captures stay private in "Seq" and are used only for RHS evaluation. *)
(* ------------------------------------------------------------------ *)

matchState[env_, seq_ : <||>] :=
  <|"Env" -> env, "Seq" -> seq, "RepeatedLength" -> Missing["Unset"]|>;

unifyState[n_, d_, state_] :=
  Module[{e2},
    If[KeyExistsQ[state["Seq"], n],
      Sow["axis " <> axisDisplayName[n] <>
        " is list-valued from a named axis-sequence and cannot also be a scalar axis"];
      Return[$Failed]];
    e2 = unify[n, d, state["Env"]];
    If[e2 === $Failed, $Failed, Append[state, "Env" -> e2]]];

stateRepeatedLengthOK[state_, k_] :=
  MissingQ[state["RepeatedLength"]] || state["RepeatedLength"] === k;

stateWithRepeatedLength[state_, k_] :=
  If[MissingQ[state["RepeatedLength"]],
    Append[state, "RepeatedLength" -> k],
    state];

stateDropScalarKeys[state_, keys_] := Append[state, "Env" -> KeyDrop[state["Env"], keys]];

addSequenceCapture[state_, key_, vals_] :=
  Which[
    KeyExistsQ[state["Env"], key],
      (Sow["axis " <> axisDisplayName[key] <>
        " is both a scalar axis and a named axis-sequence capture"]; $Failed),
    KeyExistsQ[state["Seq"], key],
      (Sow["axis " <> axisDisplayName[key] <>
        " is captured by more than one named axis-sequence"]; $Failed),
    True,
      Append[state, "Seq" -> Append[state["Seq"], key -> vals]]];

repeatedSpec[Verbatim[Pattern][s_Symbol, Verbatim[Repeated][body_]]] :=
  <|"Outer" -> s, "Body" -> body, "Min" -> 1, "Named" -> True|>;
repeatedSpec[Verbatim[Pattern][s_Symbol, Verbatim[RepeatedNull][body_]]] :=
  <|"Outer" -> s, "Body" -> body, "Min" -> 0, "Named" -> True|>;
repeatedSpec[Verbatim[Pattern][s_Symbol, Verbatim[BlankSequence[]]]] :=
  <|"Outer" -> s, "Body" -> Blank[], "Min" -> 1, "Named" -> True|>;
repeatedSpec[Verbatim[Pattern][s_Symbol, Verbatim[BlankNullSequence[]]]] :=
  <|"Outer" -> s, "Body" -> Blank[], "Min" -> 0, "Named" -> True|>;
repeatedSpec[Verbatim[Repeated][body_]] :=
  <|"Outer" -> None, "Body" -> body, "Min" -> 1, "Named" -> False|>;
repeatedSpec[Verbatim[RepeatedNull][body_]] :=
  <|"Outer" -> None, "Body" -> body, "Min" -> 0, "Named" -> False|>;
repeatedSpec[_] := None;

innerBinders[body_] := DeleteDuplicates @ Cases[body,
  Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] :> s, {0, Infinity}];

unsupportedRepeatedBodyQ[body_] :=
  ! FreeQ[HoldComplete[body],
    Verbatim[Repeated][_] | Verbatim[RepeatedNull][_] |
      Verbatim[PatternSequence][___]];

renameRepeatedBody[body_, rules_] :=
  body /. Join[
    Table[
      With[{old = First[r], new = Last[r]},
        Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]] /; s === old :>
          Pattern[new, Blank[]]],
      {r, rules}],
    Table[
      With[{old = First[r], new = Last[r]},
        s_Symbol /; s === old :> new],
      {r, rules}]];

instantiateRepeatedBody[expr_, env_] := expr /. {
  Verbatim[Pattern][sym_Symbol, Verbatim[Blank[]]] :>
    With[{n = sym}, Lookup[env, n, n]],
  str_String /; validAxisNameQ[str] && KeyExistsQ[env, axisSymbol[str]] :>
    With[{n = axisSymbol[str]}, env[n]],
  sym_Symbol /; KeyExistsQ[env, sym] :> With[{n = sym}, env[n]]};

capturedRepeatedTerm[body_, rules_, env_] :=
  instantiateRepeatedBody[renameRepeatedBody[body, rules], env];

capturedRepeatedTerm[body_, rules_, env_, dim_] :=
  Replace[capturedRepeatedTerm[body, rules, env],
    Verbatim[Blank[]] :> dim];

seqRule[key_, vals_] := key -> Apply[Sequence, vals];

seqRepeatRule[seq_Association] := {
  Verbatim[Repeated][sym_Symbol] :>
    RuleCondition[
      If[KeyExistsQ[seq, sym], Apply[Sequence, seq[sym]], Repeated[sym]]],
  Verbatim[RepeatedNull][sym_Symbol] :>
    RuleCondition[
      If[KeyExistsQ[seq, sym], Apply[Sequence, seq[sym]], RepeatedNull[sym]]]};

(* ------------------------------------------------------------------ *)
(* Composite (CircleTimes / CirclePlus) resolution against one dim.    *)
(* ------------------------------------------------------------------ *)

(* Map one composite factor to {expr, namedVars, anonVars}: a symbolic size with
   knowns substituted from env, each unbound axis left as its own symbol (named) or
   a fresh positive-integer placeholder (anon, for `_`). A CircleTimes factor
   recurses, distributing into a product — this is what lets a direct-sum summand
   itself be a product block, e.g. (a b) ⊕ c. An unsupported head yields $opaque. *)
sequenceBindingValue[Verbatim[Inactive][Sequence][xs___]] := {xs};
sequenceBindingValue[_] := Missing["NotSequenceBinding"];

validSequenceBindingQ[vals_List, min_] :=
  Length[vals] >= min && AllTrue[vals, IntegerQ[#] && # >= 1 &];

factorToExpr[f_, state_] :=
  Which[
    IntegerQ[f], {f, {}, {}},
    f === {}, {1, {}, {}},   (* in-shape unit-axis term {} == literal 1 *)
    MatchQ[f, Verbatim[Pattern][_Symbol, Verbatim[Blank][]]],
      With[{n = f[[1]]},
        If[KeyExistsQ[state["Env"], n], {state["Env"][n], {}, {}}, {n, {n}, {}}]],
    MatchQ[f, Verbatim[Pattern][_Symbol, Verbatim[BlankSequence[]]]],
      With[{n = f[[1]], vals = Lookup[state["Seq"], f[[1]], Missing["NoCapture"]]},
        If[ListQ[vals] && validSequenceBindingQ[vals, 1],
          {Times @@ vals, {}, {}}, $opaque]],
    MatchQ[f, Verbatim[Pattern][_Symbol, Verbatim[BlankNullSequence[]]]],
      With[{n = f[[1]], vals = Lookup[state["Seq"], f[[1]], Missing["NoCapture"]]},
        If[ListQ[vals] && validSequenceBindingQ[vals, 0],
          {Times @@ vals, {}, {}}, $opaque]],
    MatchQ[f, Verbatim[Blank[]]],   (* Temporary: a transient solve placeholder, GC'd after
       resolution — never escapes to the result, so it should not persist in the caller's
       context (consistent with the axis-identity symbols). *)
      With[{u = Unique["anon$", {Temporary}]}, {u, {}, {u}}],
    StringQ[f],            (* a string / #name axis inside a composite, e.g. (g #c) or ("a" "b") *)
      If[! validAxisNameQ[f], $opaque,   (* illegal name -> unsupported factor (rejected) *)
        With[{n = axisSymbol[f]},   (* valueless when shadowed — no leaked global into Solve *)
          If[KeyExistsQ[state["Env"], n], {state["Env"][n], {}, {}}, {n, {n}, {}}]]],
    bracketWrapperQ[f] && Length[f] === 1, factorToExpr[First[f], state],
    Head[f] === Symbol,
      If[KeyExistsQ[state["Env"], f], {state["Env"][f], {}, {}}, {f, {f}, {}}],
    Head[f] === CircleTimes,
      Module[{subs = Table[factorToExpr[g, state], {g, List @@ f}]},
        If[MemberQ[subs, $opaque], $opaque,
          {Times @@ subs[[All, 1]], Join @@ subs[[All, 2]], Join @@ subs[[All, 3]]}]],
    True, $opaque];

(* Resolve a CircleTimes (product) or CirclePlus (direct sum) term against one
   tensor dimension `d`. The factor sizes form an equation `op[…] == d`; the
   Mathematica CAS solves it over positive integers (Solve/Integers). A unique
   solution binds the named axes; multiple solutions are underdetermined; none is a
   mismatch. This subsumes the former single-unknown analytic logic and also
   handles product summands and any system the integers pin down uniquely. *)
solveComposite[op_, factors_, d_, state_, rest_, drest_] :=
  Module[{parsed, exprs, named, anon, allVars, eqn, sols, sol, e2},
    (* Table, not `&/@`: a factor can be Slot[...], which an anonymous Function
       would capture as its own argument slot (SPEC 7.2). *)
    parsed = Table[factorToExpr[f, state], {f, factors}];
    If[MemberQ[parsed, $opaque],
      Sow["unsupported factor inside " <> ToString[op] <> " composition"];
      Return[{}]];
    exprs = parsed[[All, 1]];
    named = DeleteDuplicates[Join @@ parsed[[All, 2]]];
    anon = Join @@ parsed[[All, 3]];
    allVars = Join[named, anon];
    eqn = (op @@ exprs) == d;
    If[allVars === {},
      Return[If[TrueQ[eqn], matchTerms[rest, drest, state],
        (Sow[ToString[op] <> " composition " <> ToString[op @@ exprs] <>
             " != tensor dimension " <> ToString[d]]; {})]]];
    sols = Quiet @ Solve[eqn && And @@ (# >= 1 & /@ allVars), allVars, Integers];
    Which[
      ! MatchQ[sols, {__List}],
        (Sow[ToString[op] <> " composition has no positive-integer solution for \
dimension " <> ToString[d]]; {}),
      Length[sols] > 1,
        (Sow["underdetermined " <> ToString[op] <> " composition (multiple \
positive-integer solutions; supply more bindings)"]; {}),
      True,
        (sol = First[sols];
         e2 = state;
         Do[e2 = unifyState[v, v /. sol, e2], {v, named}];
         If[e2 === $Failed, {}, matchTerms[rest, drest, e2]])]];

matchRepeated[spec_Association, rest_, dims_, state_] :=
  Module[{body = spec["Body"], inner, outer = spec["Outer"], out = {}, k, st0,
          states, j, nextStates, st, rules, fresh, renamed, matched, vals,
          cap, seqKeys, final, captureQ},
    If[unsupportedRepeatedBodyQ[body],
      Sow["nested Repeated/RepeatedNull or PatternSequence inside a named axis-sequence \
is not supported"];
      Return[{}]];
    inner = innerBinders[body];
    If[spec["Named"] && MemberQ[inner, outer],
      Sow["named axis-sequence outer capture " <> axisDisplayName[outer] <>
        " collides with an inner binder of the same name"];
      Return[{}]];
    captureQ = spec["Named"] || inner =!= {};
    Do[
      If[captureQ && ! stateRepeatedLengthOK[state, k],
        Sow["named axis-sequence captures have different lengths"];
        Continue[]];
      st0 = If[captureQ, stateWithRepeatedLength[state, k], state];
      states = {{st0, Table[{}, {Length[inner]}], {}}};
      Do[
        nextStates = {};
        Do[
          st = item[[1]];
          rules = Table[old -> Unique[SymbolName[old] <> "$rep$", {Temporary}],
            {old, inner}];
          fresh = Last /@ rules;
          renamed = renameRepeatedBody[body, rules];
          matched = matchTerms[{renamed}, {dims[[j]]}, st];
          Do[
            vals = Lookup[mstate["Env"], #] & /@ fresh;
            If[AllTrue[vals, IntegerQ],
              cap = capturedRepeatedTerm[body, rules, mstate["Env"], dims[[j]]];
              AppendTo[nextStates,
                {stateDropScalarKeys[mstate, fresh],
                 MapThread[Append, {item[[2]], vals}],
                 Append[item[[3]], cap]}]],
            {mstate, matched}],
          {item, states}];
        states = nextStates;
        If[states === {}, Break[]],
        {j, 1, k}];
      Do[
        final = item[[1]];
        seqKeys = inner;
        If[spec["Named"], seqKeys = Join[{outer}, seqKeys]];
        If[! DuplicateFreeQ[seqKeys],
          Sow["named axis-sequence binders must be distinct"];
          Continue[]];
        If[spec["Named"],
          final = addSequenceCapture[final, outer, item[[3]]]];
        If[final =!= $Failed,
          Do[
            final = addSequenceCapture[final, inner[[i]], item[[2, i]]];
            If[final === $Failed, Break[]],
            {i, Length[inner]}]];
        If[final =!= $Failed,
          out = Join[out, matchTerms[rest, Drop[dims, k], final]]],
        {item, states}],
      {k, spec["Min"], Length[dims]}];
    out];

(* ------------------------------------------------------------------ *)
(* Core backtracking matcher: a list of dimension terms against a list *)
(* of concrete integer dims, threading env. Returns a list of all      *)
(* consistent env associations ({} = no match).                        *)
(* ------------------------------------------------------------------ *)

matchTerms[terms_, dims_, state_] :=
  Module[{t, rest, d, drest, spec},
    If[terms === {}, Return[If[dims === {}, {state}, {}]]];
    t = First[terms]; rest = Rest[terms];
    (* {} is an in-shape unit-axis term, equivalent to the literal 1 (einx "2 () 3");
       it consumes one tensor dimension, which must be 1.  NB the operator/EinstoffShapes
       paths normalize {} -> 1 up front (descParts/parseDesc via normUnitTerms), so this
       case — and the mirroring {} cases in rearrangeAtoms/reduceAtoms/factorToExpr —
       exist for the *public* EinstoffMatch entry, which takes raw shape lists. *)
    If[t === {}, Return[matchTerms[Join[{1}, rest], dims, state]]];
    spec = repeatedSpec[t];
    If[AssociationQ[spec], Return[matchRepeated[spec, rest, dims, state]]];
    (* Target wrappers are transparent to shape matching: splice their contents into the
       stream and remember targetedness only in lowering. Slot["name"] is targeted string;
       Highlighted/Framed preserve the blank/bare spelling of their contents.
       Each string is validated before axisSymbol, so an illegal name yields a clean unsat
       reason, not a Symbol::symname crash. *)
    If[bracketWrapperQ[t],
      Module[{parts = List @@ t, bad},
        bad = Select[Cases[parts, _String], ! validAxisNameQ[#] &];
        Return[If[bad =!= {},
          (Sow["invalid axis name(s) " <> ToString[bad, InputForm] <> " in a target"]; {}),
          matchTerms[Join[Replace[parts, s_String :> axisSymbol[s], {1}], rest], dims, state]]]]];
    (* SlotSequence (##, the anonymous variadic target [...]) is an ellipsis of
       targeted axes — treat like ___ for shape matching. Lowering later expands
       the captured concrete axes into anonymous internal atoms. *)
    If[Head[t] === SlotSequence,
      Return[matchTerms[Join[{BlankNullSequence[]}, rest], dims, state]]];
    (* Variable-length anonymous sequences (may consume zero dims). *)
    If[MatchQ[t, Verbatim[BlankNullSequence[]]],
      Return[Join @@ Table[matchTerms[rest, Drop[dims, k], state],
                           {k, 0, Length[dims]}]]];
    If[MatchQ[t, Verbatim[BlankSequence[]]],
      Return[
        If[Length[dims] < 1, {},
          Join @@ Table[matchTerms[rest, Drop[dims, k], state],
                        {k, 1, Length[dims]}]]]];
    (* Everything below consumes exactly one dim. *)
    If[dims === {}, Return[{}]];
    d = First[dims]; drest = Rest[dims];
    Which[
      MatchQ[t, Verbatim[Blank[]]],
        matchTerms[rest, drest, state],
      MatchQ[t, Verbatim[Pattern][_Symbol, Verbatim[Blank][]]],
        With[{e2 = unifyState[t[[1]], d, state]},
          If[e2 === $Failed, {}, matchTerms[rest, drest, e2]]],
      IntegerQ[t],
        If[t === d, matchTerms[rest, drest, state],
          (Sow["immediate " <> ToString[t] <> " != tensor dimension " <>
               ToString[d]]; {})],
      Head[t] === CircleTimes,
        solveComposite[Times, List @@ t, d, state, rest, drest],
      Head[t] === CirclePlus,
        solveComposite[Plus, List @@ t, d, state, rest, drest],
      Head[t] === Symbol,
        With[{e2 = unifyState[t, d, state]},
          If[e2 === $Failed, {}, matchTerms[rest, drest, e2]]],
      (* A string term "a" is the string-tier axis named `a` (SPEC §5.6): unify it as
         the symbol `a`, exactly as a targeted string #a = Slot["a"] is spliced to
         Symbol["a"] above.  This makes the raw public EinstoffMatch accept string axes
         consistently with EinstoffShapes (whose desc parse canonicalizes them first).
         The name is validated first, so an illegal string is a clean unsat reason rather
         than a Symbol::symname crash. *)
      StringQ[t],
        If[! validAxisNameQ[t],
          (Sow["invalid axis name \"" <> t <> "\" (must be a valid identifier)"]; {}),
          With[{e2 = unifyState[axisSymbol[t], d, state]},
            If[e2 === $Failed, {}, matchTerms[rest, drest, e2]]]],
      True,
        (Sow["unrecognized dimension term: " <> ToString[t]]; {})]];

(* Fold the matcher across all tensors, threading env so shared axes
   unify across operands for free.

   Crucially this uses a *downvalue* step + Do loop, never an anonymous
   Function: a shape can contain Slot[...] (targets), and any Slot routed
   through a `&`/Function body is captured as that function's argument slot
   (SPEC 7.2) — which silently corrupts the match. *)
matchAll[lhss_, inps_, env_, seq_ : <||>] :=
  Fold[matchStep, {matchState[env, seq]}, Transpose[{lhss, inps}]];

matchStep[envs_, pair_] :=
  Module[{acc = {}, e},
    Do[acc = Join[acc, matchTerms[First[pair], Last[pair], e]], {e, envs}];
    acc];

(* ------------------------------------------------------------------ *)
(* Public: match.                                                      *)
(* ------------------------------------------------------------------ *)

(* Wrap the raw (no open scope) match so it sanitizes the reserved axis context once and
   gives the fallback memo a per-call scope; when called inside an operator's scope, that
   scope already did both, so pass through.  einAxisCatch turns an un-mintable fallback
   token (a compromised Einstoff`Fallback` context) into a clean ok->False. *)
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

inlineBindingRules[] :=
  If[ListQ[$inlineBindingFacts],
    Table[fact["Key"] -> fact["Size"], {fact, $inlineBindingFacts}],
    {}];

(* Merge external and inline binding facts by canonical axis identity.  Equal facts are
   idempotent; conflicting values are an error.  This runs before scalar/sequence
   partitioning so the same rule applies to every source. *)
mergeBindingFacts[bindings_List] :=
  Catch[
    Module[{groups, out = {}, vals, key},
      groups = GatherBy[bindings, First];
      Do[
        key = First[First[group]];
        vals = DeleteDuplicates[Last /@ group, SameQ];
        If[Length[vals] > 1,
          Throw["conflicting sizes for axis " <> axisDisplayName[key] <> ": " <>
            StringRiffle[ToString[#, InputForm] & /@ vals, " versus "],
            mergeBindingTag]];
        AppendTo[out, key -> First[vals]],
        {group, groups}];
      out],
    mergeBindingTag];

einstoffMatchCore[lhsShapes_, inputShapes_, bindingsIn_] :=
  Module[{bindings, scalarBindings, sequenceBindings, env0, seq0, res, sown,
          slotNames, badSlotKey},
    If[! MatchQ[lhsShapes, {___List}],
      Return[<|"ok" -> False, "reason" -> "LHS is not a list of shapes"|>]];
    If[! MatchQ[inputShapes, {___List}],
      Return[<|"ok" -> False,
        "reason" -> "input shapes must be a list of dimension lists"|>]];
    If[Length[lhsShapes] =!= Length[inputShapes],
      Return[<|"ok" -> False,
        "reason" -> "operand count: desc has " <> ToString[Length[lhsShapes]] <>
          " shape(s) but " <> ToString[Length[inputShapes]] <>
          " tensor shape(s) given"|>]];
    (* In raw EinstoffMatch there is no desc axis scope, but slot keys are still reserved:
       #q -> n only binds an axis that actually appears under Slot[...] on the raw LHS. *)
    badSlotKey = Missing["NotFound"];
    If[! AssociationQ[$axisFresh] && MatchQ[bindingsIn, {(_Rule | _RuleDelayed) ...}],
      slotNames = rawSlotAxisNames[lhsShapes];
      badSlotKey = SelectFirst[
        Cases[First /@ bindingsIn, Slot[k_String] /; validAxisNameQ[k] :> k],
        ! MemberQ[slotNames, #] &, Missing["NotFound"]]];
    If[! MissingQ[badSlotKey],
      Return[<|"ok" -> False,
        "reason" -> "axis " <> badSlotKey <>
          " is not a targeted Slot axis; bind a non-slot axis with " <> badSlotKey <>
          " -> ... or \"" <> badSlotKey <> "\" -> ..."|>]];
    (* Canonicalize + validate binding keys against the parsed desc's axis identities
       (only inside an open axis scope; standalone raw use passes through).  A hard
       reject (a Pattern key, binding an infer-only a_, a wrong-kind key) returns a
       reason string; a shadowed/junk key is warned and dropped inside canonBindingList. *)
    bindings = canonBindingList[bindingsIn,
      If[AssociationQ[$axisFresh], "Scoped", "Raw"]];
    If[StringQ[bindings],
      Return[<|"ok" -> False, "reason" -> bindings|>]];
    If[AssociationQ[$axisFresh],
      bindings = Join[bindings, inlineBindingRules[]]];
    (* Validate `bindings` at the entrance so a malformed spec fails locally here, rather
       than degrading into a deeper, less-obvious unsat message (or an unevaluated
       Association[...] leaking through matchTerms).  A binding is an axis-name -> size
       rule: a bare Symbol key and a positive-integer size.  Rule or RuleDelayed; the
       default {} is vacuously valid.  Values are read from the built Association so a
       RuleDelayed size is evaluated before the integer check. *)
    If[! MatchQ[bindings, {(_Rule | _RuleDelayed) ...}] ||
       ! AllTrue[bindings, MatchQ[First[#], _Symbol] &],
      Return[<|"ok" -> False,
        "reason" -> "bindings must be a list of axis-name -> size rules \
(e.g. {n -> 8}); got " <> ToString[bindings, InputForm]|>]];
    bindings = mergeBindingFacts[bindings];
    If[StringQ[bindings],
      Return[<|"ok" -> False, "reason" -> bindings|>]];
    sequenceBindings = Select[bindings,
      ! MissingQ[sequenceBindingValue[Last[#]]] &];
    scalarBindings = Select[bindings,
      MissingQ[sequenceBindingValue[Last[#]]] &];
    If[! AllTrue[sequenceBindings,
        validSequenceBindingQ[sequenceBindingValue[Last[#]],
          If[MatchQ[First[#], _Symbol], 0, 1]] &],
      Return[<|"ok" -> False,
        "reason" -> "each sequence binding must use Inactive[Sequence][...] with \
positive-integer dimensions; got " <> ToString[sequenceBindings, InputForm]|>]];
    env0 = Association[scalarBindings];
    If[! AllTrue[env0, IntegerQ[#] && # >= 1 &],
      Return[<|"ok" -> False,
        "reason" -> "each binding must give a positive-integer axis size; got " <>
          ToString[Normal[env0], InputForm]|>]];
    seq0 = Association[
      Table[First[bd] -> sequenceBindingValue[Last[bd]], {bd, sequenceBindings}]];
    {res, sown} = Reap[matchAll[lhsShapes, inputShapes, env0, seq0]];
    If[res === {},
      <|"ok" -> False,
        "reason" -> If[sown === {},
          "no consistent axis binding (shape/rank mismatch)",
          StringRiffle[DeleteDuplicates[Flatten[sown]], "; "]]|>,
      <|"ok" -> True, "env" -> First[res]["Env"], "seq" -> First[res]["Seq"]|>]];

(* ------------------------------------------------------------------ *)
(* Output-shape derivation: evaluate the held RHS under the bindings.  *)
(* CircleTimes -> product, CirclePlus -> sum, Slot unwrapped.          *)
(* ------------------------------------------------------------------ *)

(* Substitute scalar and sequence captures while the RHS is still held, then release it.
   This lets RHS helpers such as MapThread/Join observe `{grp}` as the captured run;
   substituting after RHS evaluation would collapse e.g. MapThread[..., {{a}, {b}}]
   into one symbolic element before the captured Sequences were listified. *)
evalOutShape[h_Hold, env_, seq_ : <||>] :=
  ReleaseHold[(normHeldShapes[h] /. seqRepeatRule[seq]) /. Join[Normal[env],
      Table[seqRule[k, seq[k]], {k, Keys[seq]}]]] /.
    {CircleTimes -> Times, CirclePlus -> Plus,
     Slot -> Sequence, Highlighted -> Sequence, Framed -> Sequence};

(* ------------------------------------------------------------------ *)
(* Public: full pipeline.                                             *)
(* ------------------------------------------------------------------ *)

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
