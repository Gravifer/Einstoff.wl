(* ::Package:: *)

(* Einstoff`Parsing` — shape-resolution / satisfiability layer.

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
   scope for now. *)

BeginPackage["Einstoff`Parsing`"];

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

Begin["`Private`"];

(* ------------------------------------------------------------------ *)
(* Parse / normalize the description.                                  *)
(* desc reaches us held; we keep the RHS held so that `:>` and `->`    *)
(* behave identically and unbound pattern symbols are not evaluated.   *)
(* ------------------------------------------------------------------ *)

SetAttributes[EinstoffParse, HoldFirst];
EinstoffParse[desc_] := parseDesc[Hold[desc]];

parseDesc[h : Hold[_RuleDelayed]] :=
  <|"LHS" -> Extract[h, {1, 1}], "RHS" -> Extract[h, {1, 2}, Hold]|>;
parseDesc[h : Hold[_Rule]] :=
  <|"LHS" -> Extract[h, {1, 1}], "RHS" -> Extract[h, {1, 2}, Hold],
    "Warning" -> "prefer :> (RuleDelayed) over -> for desc"|>;
parseDesc[_] := <|"LHS" -> $Failed, "RHS" -> $Failed|>;

(* Names that appear bound inside a Slot[...] (bracket) anywhere in lhs.
   Used only for the informational "Bracketed" field (cf. SPEC 5.2). *)
bracketedNames[lhs_] :=
  DeleteDuplicates @ Flatten @
    Cases[lhs,
      s_Slot :> Cases[s, Verbatim[Pattern][n_Symbol, _] :> n, {0, Infinity}],
      {0, Infinity}];

(* ------------------------------------------------------------------ *)
(* Unification of an axis name to a concrete size.                     *)
(* ------------------------------------------------------------------ *)

unify[n_, d_, env_] :=
  If[KeyExistsQ[env, n],
    If[env[n] === d, env,
      (Sow["axis " <> ToString[n] <> ": expected " <> ToString[env[n]] <>
           " but tensor dimension is " <> ToString[d]]; $Failed)],
    Append[env, n -> d]];

(* ------------------------------------------------------------------ *)
(* Composite (CircleTimes / CirclePlus) resolution against one dim.    *)
(* ------------------------------------------------------------------ *)

(* Classify a single factor against the current env. *)
resolveFactor[f_, env_] :=
  Which[
    IntegerQ[f], {"known", f},
    MatchQ[f, Verbatim[Pattern][_Symbol, Verbatim[Blank][]]],
      With[{n = f[[1]]}, If[KeyExistsQ[env, n], {"known", env[n]}, {"unknown", n}]],
    MatchQ[f, Verbatim[Blank[]]], {"anon"},
    Head[f] === Slot && Length[f] === 1, resolveFactor[First[f], env],
    Head[f] === Symbol, If[KeyExistsQ[env, f], {"known", env[f]}, {"unknown", f}],
    True, {"opaque"}];

solveOne[Times, knowns_, d_] :=
  With[{p = Times @@ knowns},
    If[p =!= 0 && IntegerQ[d/p] && d/p >= 1, d/p,
      (Sow["product " <> ToString[d] <> " is not divisible by the known \
factor product " <> ToString[p]]; $Failed)]];

solveOne[Plus, knowns_, d_] :=
  With[{r = d - (Plus @@ knowns)},
    If[IntegerQ[r] && r >= 1, r,
      (Sow["direct-sum remainder " <> ToString[r] <>
           " must be a positive integer"]; $Failed)]];

solveComposite[op_, factors_, d_, env_, rest_, drest_] :=
  Module[{res, knowns, unknowns, anon, opaque, solved, e2},
    res = resolveFactor[#, env] & /@ factors;
    knowns = Cases[res, {"known", v_} :> v];
    unknowns = Cases[res, {"unknown", n_} :> n];
    anon = Count[res, {"anon"}];
    opaque = Count[res, {"opaque"}];
    Which[
      opaque > 0,
        (Sow["unsupported factor inside " <> ToString[op] <>
             " composition"]; {}),
      Length[unknowns] + anon === 0,
        If[(op @@ knowns) === d, matchTerms[rest, drest, env],
          (Sow[ToString[op] <> " composition " <> ToString[op @@ knowns] <>
               " != tensor dimension " <> ToString[d]]; {})],
      Length[unknowns] + anon === 1,
        (solved = solveOne[op, knowns, d];
         If[solved === $Failed, {},
           If[anon === 1,
             matchTerms[rest, drest, env],            (* anonymous: no bind *)
             (e2 = unify[First[unknowns], solved, env];
              If[e2 === $Failed, {}, matchTerms[rest, drest, e2]])]]),
      True,
        (Sow["underdetermined " <> ToString[op] <> " composition: " <>
             ToString[Length[unknowns] + anon] <>
             " unknown factors (supply more bindings)"]; {})]];

(* ------------------------------------------------------------------ *)
(* Core backtracking matcher: a list of dimension terms against a list *)
(* of concrete integer dims, threading env. Returns a list of all      *)
(* consistent env associations ({} = no match).                        *)
(* ------------------------------------------------------------------ *)

matchTerms[terms_, dims_, env_] :=
  Module[{t, rest, d, drest},
    If[terms === {}, Return[If[dims === {}, {env}, {}]]];
    t = First[terms]; rest = Rest[terms];
    (* Slot is a transparent bracket: splice its contents into the stream. *)
    If[Head[t] === Slot,
      Return[matchTerms[Join[List @@ t, rest], dims, env]]];
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
      True,
        (Sow["unrecognized dimension term: " <> ToString[t]]; {})]];

(* Fold the matcher across all tensors, threading env so shared axes
   unify across operands for free. *)
matchAll[lhss_, inps_, env_] :=
  Fold[
    Function[{envs, pair},
      Join @@ (matchTerms[First[pair], Last[pair], #] & /@ envs)],
    {env},
    Transpose[{lhss, inps}]];

(* ------------------------------------------------------------------ *)
(* Public: match.                                                      *)
(* ------------------------------------------------------------------ *)

EinstoffMatch[lhsShapes_, inputShapes_, bindings_ : {}] :=
  Module[{env0, res, sown},
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
    env0 = Association[bindings];
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

evalOutShape[Hold[rhs_], env_] :=
  rhs /. Join[Normal[env],
    {CircleTimes -> Times, CirclePlus -> Plus, Slot -> Sequence}];

(* ------------------------------------------------------------------ *)
(* Public: full pipeline.                                             *)
(* ------------------------------------------------------------------ *)

SetAttributes[EinstoffShapes, HoldFirst];
EinstoffShapes[desc_, inputShapes_, bindings_ : {}] :=
  Module[{p, lhs, heldRhs, bracketed, m, env, out},
    p = parseDesc[Hold[desc]];
    If[p["LHS"] === $Failed,
      Return[<|"Satisfiable" -> False,
        "Reason" -> "desc must be of the form lhs :> rhs (or lhs -> rhs)",
        "OutputShapes" -> Missing[], "Bindings" -> <||>, "Bracketed" -> {}|>]];
    lhs = p["LHS"]; heldRhs = p["RHS"];
    bracketed = bracketedNames[lhs];
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

End[];
EndPackage[];
