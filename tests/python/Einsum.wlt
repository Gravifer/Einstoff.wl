(* ::Package:: *)

(* Cross-validation for Einstoff["einsum"] against einops.einsum (which wraps the
   backend np.einsum).  Covers within-tensor contraction (partial trace, full trace)
   and cross-tensor contraction (matmul) — the pairwise-contraction subset.  einops
   uses space-separated axis names: "a b a d -> b d".

   Opt-in only: `wolframscript -script scripts/run-tests.wls python`.
   Session setup duplicated from the other python suites (self-contained). *)

ClearAll[a, b, c, d];

pyRoot =
  If[ValueQ[Einstoff`Tests`$Root], Einstoff`Tests`$Root,
    ParentDirectory[PacletObject["Einstoff"]["Location"]]];
pyExe = FileNameJoin[{pyRoot, ".venv", "Scripts", "python.exe"}];

pyOwned = Head[Einstoff`Tests`$PySession] =!= ExternalSessionObject;
pySession = If[pyOwned,
  Quiet @ Check[
    If[FileExistsQ[pyExe],
      StartExternalSession[<|"System" -> "Python", "Executable" -> pyExe|>], $Failed], $Failed],
  Einstoff`Tests`$PySession];
pythonReady = TrueQ @ Quiet @ Check[
  Head[pySession] === ExternalSessionObject &&
  ExternalEvaluate[pySession, "import numpy, einops; True"] === True,
  False];

pyDims[l_List] := "[" <> StringRiffle[ToString /@ l, ", "] <> "]";

(* einops.einsum with tensors then the pattern; inputs 1+arange reshaped, like WL Range. *)
pyEinsum[pattern_, dimsList_List] :=
  Module[{setup, args},
    setup = StringJoin @ MapIndexed[
      With[{nm = "x" <> ToString[First[#2] - 1], d = #1},
        nm <> " = (1 + np.arange(" <> ToString[Times @@ d] <> ")).reshape(" <>
          pyDims[d] <> ")\n"] &, dimsList];
    args = StringRiffle[Table["x" <> ToString[i], {i, 0, Length[dimsList] - 1}], ", "];
    ExternalEvaluate[pySession,
      "import numpy as np, einops\n" <> setup <>
      "np.asarray(einops.einsum(" <> args <> ", " <>
        ToString[pattern, InputForm] <> ")).tolist()"]];

(* ======================================================================== *)
BeginTestSection["Einstoff`CrossValidation`Einsum", pythonReady];

(* within-tensor partial trace *)
VerificationTest[
  Einstoff["einsum"][{{a_, b_, a_, d_}} :> {{b, d}}, {ArrayReshape[Range[16], {2, 2, 2, 2}]}],
  pyEinsum["a b a d -> b d", {{2, 2, 2, 2}}],
  TestID -> "xval-einsum-partial-trace"
];

(* within-tensor full trace (scalar) *)
VerificationTest[
  Einstoff["einsum"][{{a_, a_}} :> {{}}, {ArrayReshape[Range[9], {3, 3}]}],
  pyEinsum["a a ->", {{3, 3}}],
  TestID -> "xval-einsum-full-trace"
];

(* cross-tensor matmul *)
VerificationTest[
  Einstoff["einsum"][{{a_, b_}, {b_, c_}} :> {{a, c}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  pyEinsum["a b, b c -> a c", {{2, 3}, {3, 4}}],
  TestID -> "xval-einsum-matmul"
];

EndTestSection[];
(* ======================================================================== *)

If[pyOwned && Head[pySession] === ExternalSessionObject, Quiet @ DeleteObject[pySession]];
