(* ::Package:: *)

(* Cross-validation tests for the reduce lowering: Einstoff[ArrayReduce] checked
   against the actual einx / einops reductions (SPEC §10.1). Companion to
   tests/python/Reshape.wlt; see that file for the full rationale.

   Opt-in only: `wolframscript -script scripts/run-tests.wls python`.

   Scope note: cross-validation here uses sum and max only — both integer-exact,
   so comparison is by exact equality. einops.reduce 'mean' rejects integer
   tensors and einx 'mean' returns floats (vs WL's exact rationals), so the mean
   reducer is validated in the WL suite (tests/Reduce.wlt) against native Mean
   instead.

   The session setup / pyDims / pyKwargs helpers are intentionally duplicated
   from tests/python/Reshape.wlt to keep each .wlt self-contained; factor into a
   shared harness if a third python suite appears. *)

ClearAll[a, b, c, d];

pyRoot =
  If[ValueQ[Einstoff`Tests`$Root], Einstoff`Tests`$Root,
    ParentDirectory[PacletObject["Einstoff"]["Location"]]];
pyExe = FileNameJoin[{pyRoot, ".venv", "Scripts", "python.exe"}];

pySession = $Failed;
pythonReady = TrueQ @ Quiet @ Check[
  FileExistsQ[pyExe] &&
  (pySession =
     StartExternalSession[<|"System" -> "Python", "Executable" -> pyExe|>]) =!= $Failed &&
  Head[pySession] === ExternalSessionObject &&
  ExternalEvaluate[pySession, "import numpy, einops, einx; True"] === True,
  False];

pyDims[l_List] := "[" <> StringRiffle[ToString /@ l, ", "] <> "]";
pyKwargs[kw_Association] := StringRiffle[KeyValueMap[#1 <> "=" <> ToString[#2] &, kw], ", "];

(* pyReduce[backend, reduction, pattern, dims, kwargs]: build the input from
   `dims` inside Python, apply the einops/einx reduction, return WL int lists.
   einops uses bare patterns ('a b -> a'); einx uses bracket patterns
   ('a [b] -> a'); the pairing with the Wolfram desc is reasoned out of band. *)
pyReduce[backend_, reduction_, pattern_, dims_List, kwargs_ : <||>] :=
  Module[{prod = Times @@ dims, kw = pyKwargs[kwargs], call},
    call = Switch[backend,
      "einops", "einops.reduce(x, " <> ToString[pattern, InputForm] <> ", " <>
                  ToString[reduction, InputForm] <> If[kw === "", "", ", " <> kw] <> ")",
      "einx",   "einx." <> reduction <> "(" <> ToString[pattern, InputForm] <> ", x" <>
                  If[kw === "", "", ", " <> kw] <> ")"];
    ExternalEvaluate[pySession,
      "import numpy as np, einops, einx\n" <>
      "x = (1 + np.arange(" <> ToString[prod] <> ")).reshape(" <> pyDims[dims] <> ")\n" <>
      "(" <> call <> ").tolist()"]];

(* ======================================================================== *)
BeginTestSection["Einstoff`CrossValidation`Reduce", pythonReady];

(* einops sum 'a b -> a'  <->  {{a_,b_}} :> {{a}}  (bare drop = reduce) *)
VerificationTest[
  Einstoff[ArrayReduce][{{a_, b_}} :> {{a}}, {ArrayReshape[Range[12], {3, 4}]}],
  pyReduce["einops", "sum", "a b -> a", {3, 4}],
  TestID -> "xval-einops-sum"
];

(* einx sum 'a [b] -> a'  <->  {{a_, [b_]}} :> {{a}}  (bracket reduce) *)
VerificationTest[
  Einstoff[ArrayReduce][{{a_, Slot[b_]}} :> {{a}}, {ArrayReshape[Range[12], {3, 4}]}],
  pyReduce["einx", "sum", "a [b] -> a", {3, 4}],
  TestID -> "xval-einx-sum"
];

(* einops max 'a b -> a'  <->  {{a_,b_}} :> {{a}}, Reducer -> Max *)
VerificationTest[
  Einstoff[ArrayReduce][{{a_, b_}} :> {{a}}, {ArrayReshape[Range[12], {3, 4}]}, Max],
  pyReduce["einops", "max", "a b -> a", {3, 4}],
  TestID -> "xval-einops-max"
];

(* einx max 'a [b] -> a'  <->  {{a_, [b_]}} :> {{a}}, Max reducer *)
VerificationTest[
  Einstoff[ArrayReduce][{{a_, Slot[b_]}} :> {{a}}, {ArrayReshape[Range[12], {3, 4}]}, Max],
  pyReduce["einx", "max", "a [b] -> a", {3, 4}],
  TestID -> "xval-einx-max"
];

(* einops sum 'a b c -> c a' (reduce b, permute survivors)
   <->  {{a_, [b_], c_}} :> {{c, a}} *)
VerificationTest[
  Einstoff[ArrayReduce][{{a_, Slot[b_], c_}} :> {{c, a}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  pyReduce["einops", "sum", "a b c -> c a", {2, 3, 4}],
  TestID -> "xval-einops-sum-permute"
];

(* einx sum 'a [b] c -> (a c)' (reduce b, merge survivors)
   <->  {{a_, [b_], c_}} :> {{a \[CircleTimes] c}} *)
VerificationTest[
  Einstoff[ArrayReduce][{{a_, Slot[b_], c_}} :> {{CircleTimes[a, c]}}, {ArrayReshape[Range[24], {2, 3, 4}]}],
  pyReduce["einx", "sum", "a [b] c -> (a c)", {2, 3, 4}],
  TestID -> "xval-einx-sum-merge"
];

EndTestSection[];
(* ======================================================================== *)

If[Head[pySession] === ExternalSessionObject, Quiet @ DeleteObject[pySession]];
