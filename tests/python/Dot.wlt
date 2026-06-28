(* ::Package:: *)

(* Cross-validation tests for the dot lowering: Einstoff[Dot] checked against the
   actual einx.dot contraction (SPEC §10.1). Companion to the other
   tests/python/*.wlt; see Reshape.wlt for the full rationale.

   Opt-in only: `wolframscript -script scripts/run-tests.wls python`.
   Integer inputs -> exact equality, no tolerance.

   The session setup / pyDims helpers are intentionally duplicated from the other
   python suites to keep each .wlt self-contained; factor into a shared harness
   if this duplication grows. *)

ClearAll[a, b, c, d, r];

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
  ExternalEvaluate[pySession, "import numpy, einx; True"] === True,
  False];

pyDims[l_List] := "[" <> StringRiffle[ToString /@ l, ", "] <> "]";
pyKwargs[kw_Association] := StringRiffle[KeyValueMap[#1 <> "=" <> ToString[#2] &, kw], ", "];

(* pyDot[pattern, dims1, dims2, kwargs]: build both operands from their dims
   recipes inside Python, apply einx.dot, return WL int lists. kwargs supply any
   out-of-band axis sizes (e.g. a repetition axis). The einx pattern <-> the
   Wolfram desc equivalence is reasoned out of band. *)
pyDot[pattern_, dims1_List, dims2_List, kwargs_ : <||>] :=
  Module[{kw = pyKwargs[kwargs]},
    ExternalEvaluate[pySession,
      "import numpy as np, einx\n" <>
      "x = (1 + np.arange(" <> ToString[Times @@ dims1] <> ")).reshape(" <> pyDims[dims1] <> ")\n" <>
      "y = (1 + np.arange(" <> ToString[Times @@ dims2] <> ")).reshape(" <> pyDims[dims2] <> ")\n" <>
      "np.asarray(einx.dot(" <> ToString[pattern, InputForm] <> ", x, y" <>
        If[kw === "", "", ", " <> kw] <> ")).tolist()"]];

(* ======================================================================== *)
BeginTestSection["Einstoff`CrossValidation`Dot", pythonReady];

(* matmul 'a b, b c -> a c'  <->  {{a_,b_},{b,c_}} :> {{a,c}} *)
VerificationTest[
  Einstoff[Dot][{{a_, b_}, {b, c_}} :> {{a, c}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  pyDot["a b, b c -> a c", {2, 3}, {3, 4}],
  TestID -> "xval-dot-matmul"
];

(* bracketed matmul 'a [b], [b] c -> a c'  <->  {{a_,[b_]},{[b],c_}} :> {{a,c}} *)
VerificationTest[
  Einstoff[Dot][{{a_, Slot[b_]}, {Slot[b], c_}} :> {{a, c}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  pyDot["a [b], [b] c -> a c", {2, 3}, {3, 4}],
  TestID -> "xval-dot-matmul-bracket"
];

(* batched matmul 'a b c, a c d -> a b d'  <->  {{a_,b_,c_},{a,c,d_}} :> {{a,b,d}} *)
VerificationTest[
  Einstoff[Dot][{{a_, b_, c_}, {a, c, d_}} :> {{a, b, d}},
    {ArrayReshape[Range[24], {2, 3, 4}], ArrayReshape[Range[40], {2, 4, 5}]}],
  pyDot["a b c, a c d -> a b d", {2, 3, 4}, {2, 4, 5}],
  TestID -> "xval-dot-batched"
];

(* outer product 'a, b -> a b'  <->  {{a_},{b_}} :> {{a,b}} *)
VerificationTest[
  Einstoff[Dot][{{a_}, {b_}} :> {{a, b}}, {Range[2], Range[3]}],
  pyDot["a, b -> a b", {2}, {3}],
  TestID -> "xval-dot-outer"
];

(* contract then merge 'a b, b c -> (a c)'  <->  {{a_,[b_]},{[b],c_}} :> {{a \[CircleTimes] c}} *)
VerificationTest[
  Einstoff[Dot][{{a_, Slot[b_]}, {Slot[b], c_}} :> {{CircleTimes[a, c]}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  pyDot["a b, b c -> (a c)", {2, 3}, {3, 4}],
  TestID -> "xval-dot-contract-merge"
];

(* --- contract then repeat (SPEC 5.5) --- *)

(* einx.dot then repeat 'a [b], [b] c -> a c r', r=2
   <->  {{a_,[b_]},{[b],c_}} :> {{a, c, r}}, {r -> 2} *)
VerificationTest[
  Einstoff[Dot][{{a_, Slot[b_]}, {Slot[b], c_}} :> {{a, c, r}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}, {r -> 2}],
  pyDot["a [b], [b] c -> a c r", {2, 3}, {3, 4}, <|"r" -> 2|>],
  TestID -> "xval-dot-repeat"
];

EndTestSection[];
(* ======================================================================== *)

If[Head[pySession] === ExternalSessionObject, Quiet @ DeleteObject[pySession]];
