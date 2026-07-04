(* ::Package:: *)

(* Einstoff parsing — shape-resolution / satisfiability layer.

   Given a `desc` (an einops/einx-style axis transformation written as
   `lhs :> rhs`, list-of-shapes both sides, see SPEC.md) and the *shapes*
   of input tensors plus an axis-size `bindings` list, decide whether the
   description is satisfiable and, if so, what the output shapes are.

   This is pure shape algebra over the pattern AST — no real arrays are
   touched and nothing is lowered to Transpose/ArrayReshape/etc.

   Scope (regular grammar subset): bare symbols (reference), `name_`
   (binding), integer immediates, `_`/`__`/`___`, `CircleTimes` (product),
   `CirclePlus` (direct sum), `Slot[...]` brackets, and multi-tensor shared
   axes. Named-ellipsis re-walk (`Repeated` inner/outer mvars) is out of
   scope for now.

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
\"OutputShapes\", \"Bindings\", \"Bracketed\" and \"Reason\". desc is held.";

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
   canonHeld are shared with the lowering hub (Lowering.wl).  parseDesc is the held-RHS
   twin of descParts: it keeps the RHS held so EinstoffParse returns a normalized desc
   whose (fresh-canonicalized) axis symbols are not released before their sizes are
   substituted (evalOutShape releases it later under env).  Same {} -> 1 + CirclePlus-
   flatten policy as descParts; the LHS is flattened so the matcher (solveComposite) sees
   a flat summand list.  canonHeld rewrites every established axis name — binder `a_`,
   bracket `#a`, string "a" — to a fresh Temporary identity shared across its
   occurrences, so a shadowed global symbol cannot leak its value into an axis (and
   brackets are context-safe). *)
parseDesc[h : Hold[_RuleDelayed]] :=
  Module[{hr = canonHeld[h]},
    If[hr === $Failed, <|"LHS" -> $Failed, "RHS" -> $Failed|>,
      <|"LHS" -> normShapes @ Extract[hr, {1, 1}],
        "RHS" -> normHeldShapes @ Extract[hr, {1, 2}, Hold]|>]];
parseDesc[h : Hold[_Rule]] :=
  Module[{hr = canonHeld[h]},
    If[hr === $Failed, <|"LHS" -> $Failed, "RHS" -> $Failed|>,
      <|"LHS" -> normShapes @ Extract[hr, {1, 1}],
        "RHS" -> normHeldShapes @ Extract[hr, {1, 2}, Hold],
        "Warning" -> "prefer :> (RuleDelayed) over -> for desc"|>]];
parseDesc[_] := <|"LHS" -> $Failed, "RHS" -> $Failed|>;

(* Names that appear inside a Slot[...] (bracket) anywhere in lhs.  By the time this
   runs the desc has been through canonHeld, so a #name bracket is Slot[freshSym] (a bare
   symbol); composites keep their pattern symbols.  Collect every non-System` symbol
   inside any Slot.  Used only for the informational "Bracketed" field (§5.2); the fresh
   symbols are mapped back to the user's names by deCanon on the public output. *)
bracketedNames[lhs_] :=
  DeleteDuplicates @ Flatten @
    Cases[lhs,
      s_Slot :> Cases[s, n_Symbol /; Context[n] =!= "System`" :> n, {0, Infinity}],
      {0, Infinity}];

(* Axis-name identities used by one shape term, for the within-shape uniqueness
   check.  A binding (name_), a bare reference, and a #name bracket (Slot["name"])
   are all the axis `name`; integer immediates and the anonymous ellipses
   (_/__/___/##) are not names.  Composites/brackets recurse into their parts. *)
termAxisNames[Verbatim[Pattern][s_Symbol, Verbatim[Blank[]]]] := {s};
termAxisNames[s_Symbol] := {s};
(* A string axis "a" is the axis `a`.  Route through axisSymbol (valueless when the name
   is shadowed) and validate first, so a raw shape that reaches the uniqueness check
   neither crashes on Symbol::symname nor mis-tallies a shadowed global's value.  An
   invalid string is not an axis name, so it contributes nothing. *)
termAxisNames[s_String] := If[validAxisNameQ[s], {axisSymbol[s]}, {}];
termAxisNames[(CircleTimes | CirclePlus | Slot)[xs___]] := Join @@ (termAxisNames /@ {xs});
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
(* Composite (CircleTimes / CirclePlus) resolution against one dim.    *)
(* ------------------------------------------------------------------ *)

(* Map one composite factor to {expr, namedVars, anonVars}: a symbolic size with
   knowns substituted from env, each unbound axis left as its own symbol (named) or
   a fresh positive-integer placeholder (anon, for `_`). A CircleTimes factor
   recurses, distributing into a product — this is what lets a direct-sum summand
   itself be a product block, e.g. (a b) ⊕ c. An unsupported head yields $opaque. *)
factorToExpr[f_, env_] :=
  Which[
    IntegerQ[f], {f, {}, {}},
    f === {}, {1, {}, {}},   (* in-shape unit-axis term {} == literal 1 *)
    MatchQ[f, Verbatim[Pattern][_Symbol, Verbatim[Blank][]]],
      With[{n = f[[1]]}, If[KeyExistsQ[env, n], {env[n], {}, {}}, {n, {n}, {}}]],
    MatchQ[f, Verbatim[Blank[]]], With[{u = Unique["anon$"]}, {u, {}, {u}}],
    StringQ[f],            (* a string / #name axis inside a composite, e.g. (g #c) or ("a" "b") *)
      If[! validAxisNameQ[f], $opaque,   (* illegal name -> unsupported factor (rejected) *)
        With[{n = axisSymbol[f]},   (* valueless when shadowed — no leaked global into Solve *)
          If[KeyExistsQ[env, n], {env[n], {}, {}}, {n, {n}, {}}]]],
    Head[f] === Slot && Length[f] === 1, factorToExpr[First[f], env],
    Head[f] === Symbol, If[KeyExistsQ[env, f], {env[f], {}, {}}, {f, {f}, {}}],
    Head[f] === CircleTimes,
      Module[{subs = Table[factorToExpr[g, env], {g, List @@ f}]},
        If[MemberQ[subs, $opaque], $opaque,
          {Times @@ subs[[All, 1]], Join @@ subs[[All, 2]], Join @@ subs[[All, 3]]}]],
    True, $opaque];

(* Resolve a CircleTimes (product) or CirclePlus (direct sum) term against one
   tensor dimension `d`. The factor sizes form an equation `op[…] == d`; the
   Mathematica CAS solves it over positive integers (Solve/Integers). A unique
   solution binds the named axes; multiple solutions are underdetermined; none is a
   mismatch. This subsumes the former single-unknown analytic logic and also
   handles product summands and any system the integers pin down uniquely. *)
solveComposite[op_, factors_, d_, env_, rest_, drest_] :=
  Module[{parsed, exprs, named, anon, allVars, eqn, sols, sol, e2},
    (* Table, not `&/@`: a factor can be Slot[...], which an anonymous Function
       would capture as its own argument slot (SPEC 7.2). *)
    parsed = Table[factorToExpr[f, env], {f, factors}];
    If[MemberQ[parsed, $opaque],
      Sow["unsupported factor inside " <> ToString[op] <> " composition"];
      Return[{}]];
    exprs = parsed[[All, 1]];
    named = DeleteDuplicates[Join @@ parsed[[All, 2]]];
    anon = Join @@ parsed[[All, 3]];
    allVars = Join[named, anon];
    eqn = (op @@ exprs) == d;
    If[allVars === {},
      Return[If[TrueQ[eqn], matchTerms[rest, drest, env],
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
         e2 = env;
         Do[e2 = unify[v, v /. sol, e2], {v, named}];
         If[e2 === $Failed, {}, matchTerms[rest, drest, e2]])]];

(* ------------------------------------------------------------------ *)
(* Core backtracking matcher: a list of dimension terms against a list *)
(* of concrete integer dims, threading env. Returns a list of all      *)
(* consistent env associations ({} = no match).                        *)
(* ------------------------------------------------------------------ *)

matchTerms[terms_, dims_, env_] :=
  Module[{t, rest, d, drest},
    If[terms === {}, Return[If[dims === {}, {env}, {}]]];
    t = First[terms]; rest = Rest[terms];
    (* {} is an in-shape unit-axis term, equivalent to the literal 1 (einx "2 () 3");
       it consumes one tensor dimension, which must be 1.  NB the operator/EinstoffShapes
       paths normalize {} -> 1 up front (descParts/parseDesc via normUnitTerms), so this
       case — and the mirroring {} cases in rearrangeAtoms/reduceAtoms/factorToExpr —
       exist for the *public* EinstoffMatch entry, which takes raw shape lists. *)
    If[t === {}, Return[matchTerms[Join[{1}, rest], dims, env]]];
    (* Slot is a transparent bracket: splice its contents into the stream.  A string slot
       #name == Slot["name"] denotes axis `name`, so its content string is mapped to that
       symbol on the way in (then handled by the Symbol case), exactly as Slot[name_]/
       Slot[name] splice to a pattern/symbol — bracketing is irrelevant to shape matching.
       Each string is validated as an axis identifier before Symbol[…] (SPEC §5.6), so an
       illegal name yields a clean unsat reason, not a Symbol::symname crash. *)
    If[Head[t] === Slot,
      Module[{parts = List @@ t, bad},
        bad = Select[Cases[parts, _String], ! validAxisNameQ[#] &];
        Return[If[bad =!= {},
          (Sow["invalid axis name(s) " <> ToString[bad, InputForm] <> " in a bracket"]; {}),
          matchTerms[Join[Replace[parts, s_String :> axisSymbol[s], {1}], rest], dims, env]]]]];
    (* SlotSequence (##, the anonymous variadic bracket [...]) is an ellipsis of
       bracketed axes — treat like ___ for shape matching (lowering is deferred,
       like Slot[___]). *)
    If[Head[t] === SlotSequence,
      Return[matchTerms[Join[{BlankNullSequence[]}, rest], dims, env]]];
    (* Variable-length anonymous sequences (may consume zero dims). *)
    If[MatchQ[t, Verbatim[BlankNullSequence[]]],
      Return[Join @@ Table[matchTerms[rest, Drop[dims, k], env],
                           {k, 0, Length[dims]}]]];
    If[MatchQ[t, Verbatim[BlankSequence[]]],
      Return[
        If[Length[dims] < 1, {},
          Join @@ Table[matchTerms[rest, Drop[dims, k], env],
                        {k, 1, Length[dims]}]]]];
    (* Everything below consumes exactly one dim. *)
    If[dims === {}, Return[{}]];
    d = First[dims]; drest = Rest[dims];
    Which[
      MatchQ[t, Verbatim[Blank[]]],
        matchTerms[rest, drest, env],
      MatchQ[t, Verbatim[Pattern][_Symbol, Verbatim[Blank][]]],
        With[{e2 = unify[t[[1]], d, env]},
          If[e2 === $Failed, {}, matchTerms[rest, drest, e2]]],
      IntegerQ[t],
        If[t === d, matchTerms[rest, drest, env],
          (Sow["immediate " <> ToString[t] <> " != tensor dimension " <>
               ToString[d]]; {})],
      Head[t] === CircleTimes,
        solveComposite[Times, List @@ t, d, env, rest, drest],
      Head[t] === CirclePlus,
        solveComposite[Plus, List @@ t, d, env, rest, drest],
      Head[t] === Symbol,
        With[{e2 = unify[t, d, env]},
          If[e2 === $Failed, {}, matchTerms[rest, drest, e2]]],
      (* A string term "a" is the string-tier axis named `a` (SPEC §5.6): unify it as
         the symbol `a`, exactly as a bracket string #a = Slot["a"] is spliced to
         Symbol["a"] above.  This makes the raw public EinstoffMatch accept string axes
         consistently with EinstoffShapes (whose desc parse canonicalizes them first).
         The name is validated first, so an illegal string is a clean unsat reason rather
         than a Symbol::symname crash. *)
      StringQ[t],
        If[! validAxisNameQ[t],
          (Sow["invalid axis name \"" <> t <> "\" (must be a valid identifier)"]; {}),
          With[{e2 = unify[axisSymbol[t], d, env]},
            If[e2 === $Failed, {}, matchTerms[rest, drest, e2]]]],
      True,
        (Sow["unrecognized dimension term: " <> ToString[t]]; {})]];

(* Fold the matcher across all tensors, threading env so shared axes
   unify across operands for free.

   Crucially this uses a *downvalue* step + Do loop, never an anonymous
   Function: a shape can contain Slot[...] (brackets), and any Slot routed
   through a `&`/Function body is captured as that function's argument slot
   (SPEC 7.2) — which silently corrupts the match. *)
matchAll[lhss_, inps_, env_] :=
  Fold[matchStep, {env}, Transpose[{lhss, inps}]];

matchStep[envs_, pair_] :=
  Module[{acc = {}, e},
    Do[acc = Join[acc, matchTerms[First[pair], Last[pair], e]], {e, envs}];
    acc];

(* ------------------------------------------------------------------ *)
(* Public: match.                                                      *)
(* ------------------------------------------------------------------ *)

EinstoffMatch[lhsShapes_, inputShapes_, bindingsIn_ : {}] :=
  Module[{bindings, env0, res, sown},
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
    (* Canonicalize + validate binding keys against the parsed desc's axis identities
       (only inside an open axis scope; standalone raw use passes through).  A hard
       reject (a Pattern key, binding an inference-only a_, a wrong-tier key) returns a
       reason string; a shadowed/junk key is warned and dropped inside canonBindingList. *)
    bindings = canonBindingList[bindingsIn,
      If[AssociationQ[$axisFresh], "Scoped", "Raw"]];
    If[StringQ[bindings],
      Return[<|"ok" -> False, "reason" -> bindings|>]];
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
    (* An axis may be bound at most once.  Association silently keeps the LAST value, so
       {c -> 2, c -> 99} and {c -> 99, c -> 2} would mean different things with no
       diagnostic — reject a duplicate key outright rather than pick order-dependently. *)
    If[! DuplicateFreeQ[First /@ bindings],
      Return[<|"ok" -> False,
        "reason" -> "duplicate binding key(s) " <>
          ToString[Keys @ Select[Counts[First /@ bindings], # > 1 &], InputForm] <>
          "; each axis may be bound at most once"|>]];
    env0 = Association[bindings];
    If[! AllTrue[env0, IntegerQ[#] && # >= 1 &],
      Return[<|"ok" -> False,
        "reason" -> "each binding must give a positive-integer axis size; got " <>
          ToString[Normal[env0], InputForm]|>]];
    {res, sown} = Reap[matchAll[lhsShapes, inputShapes, env0]];
    If[res === {},
      <|"ok" -> False,
        "reason" -> If[sown === {},
          "no consistent axis binding (shape/rank mismatch)",
          StringRiffle[DeleteDuplicates[Flatten[sown]], "; "]]|>,
      <|"ok" -> True, "env" -> First[res]|>]];

(* ------------------------------------------------------------------ *)
(* Output-shape derivation: evaluate the held RHS under the bindings.  *)
(* CircleTimes -> product, CirclePlus -> sum, Slot unwrapped.          *)
(* ------------------------------------------------------------------ *)

(* Normalize an in-shape {} unit term to 1 *before* CircleTimes -> Times etc., so a {}
   inside a composite (e.g. (a () )) evaluates correctly; a whole-shape {} stays scalar. *)
evalOutShape[Hold[rhs_], env_] :=
  normUnitTerms[rhs] /. Join[Normal[env],
    {CircleTimes -> Times, CirclePlus -> Plus, Slot -> Sequence}];

(* ------------------------------------------------------------------ *)
(* Public: full pipeline.                                             *)
(* ------------------------------------------------------------------ *)

SetAttributes[EinstoffShapes, HoldFirst];
EinstoffShapes[desc_, inputShapes_, bindings_ : {}] := withAxisScopeDeCanon @
  Module[{p, lhs, heldRhs, bracketed, relRhs, dup, m, env, out},
    p = parseDesc[Hold[desc]];
    If[p["LHS"] === $Failed,
      (* descFailReason surfaces the accurate canonHeld reject reason (invalid axis name /
         tier mishmash) when there is one, else the generic desc-shape reason. *)
      Return[<|"Satisfiable" -> False,
        "Reason" -> descFailReason[],
        "OutputShapes" -> Missing[], "Bindings" -> <||>, "Bracketed" -> {}|>]];
    lhs = p["LHS"]; heldRhs = p["RHS"];
    bracketed = bracketedNames[lhs];
    (* Universal shape invariant: an axis name must be distinct within the OUTPUT shape
       (einx: "the output expression must not contain multiple vectorized axes with the
       same name") — a duplicate output axis has no well-defined layout.  Only the RHS is
       checked: a name repeated within an INPUT shape is within-tensor contraction, which
       the resolver handles by unification (bind once, enforce equality) and is a valid,
       supported case for Massage/Contract/einsum.  Admissibility of a repeated INPUT axis
       is therefore operator policy, enforced by each operator (the non-contracting
       reduce/map/dot/direct-sum paths reject it via distinctAxesQ), not here.  A globally
       bound RHS symbol releases to its literal (excluded from names), matching the
       desc-not-held convention. *)
    relRhs = Quiet @ Check[ReleaseHold[heldRhs], $Failed];
    dup = firstDuplicateAxis[If[MatchQ[relRhs, {___List}], relRhs, {}]];
    If[! MissingQ[dup],
      Return[<|"Satisfiable" -> False,
        "Reason" -> "axis " <> axisDisplayName[dup] <> " appears more than once within \
the output shape; output axis names must be distinct (einx forbids multiple vectorized \
axes with the same name)",
        "OutputShapes" -> Missing[], "Bindings" -> <||>, "Bracketed" -> bracketed|>]];
    m = EinstoffMatch[lhs, inputShapes, bindings];
    If[! TrueQ[m["ok"]],
      Return[<|"Satisfiable" -> False, "Reason" -> m["reason"],
        "OutputShapes" -> Missing[], "Bindings" -> <||>,
        "Bracketed" -> bracketed|>]];
    env = m["env"];
    out = evalOutShape[heldRhs, env];
    If[! MatchQ[out, {___List}] ||
       ! AllTrue[Flatten[out], IntegerQ[#] && # >= 1 &],
      Return[<|"Satisfiable" -> False,
        "Reason" -> "output shape did not resolve to positive integers \
(unbound RHS symbol or non-integer dim): " <> ToString[out],
        "OutputShapes" -> Missing[], "Bindings" -> env,
        "Bracketed" -> bracketed|>]];
    <|"Satisfiable" -> True, "OutputShapes" -> out, "Bindings" -> env,
      "Bracketed" -> bracketed, "Reason" -> ""|>];
