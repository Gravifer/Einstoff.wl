(* ::Package:: *)

(* Cross-validation for the generalized contraction: only Einstoff[Inner][Times,
   Plus] has an einx equivalent (it IS einx.dot), so that is what we check against
   the external oracle — confirming Inner's base case reduces to einx.dot. Other
   combiners (tropical, max-product, …) have no einx counterpart and are validated
   against native WL Inner in tests/Inner.wlt.

   Opt-in only: `wolframscript -script scripts/run-tests.wls python`.
   Session setup duplicated from the other python suites (self-contained). *)

ClearAll[a, b, c, d];

pyRoot =
  If[ValueQ[Gravifer`Einstoff`Tests`$Root], Gravifer`Einstoff`Tests`$Root,
    ParentDirectory[PacletObject["Gravifer/Einstoff"]["Location"]]];
pyExe = FileNameJoin[{pyRoot, ".venv", "Scripts", "python.exe"}];

pyOwned = Head[Gravifer`Einstoff`Tests`$PySession] =!= ExternalSessionObject;
pySession = If[pyOwned,
  Quiet @ Check[
    If[FileExistsQ[pyExe],
      StartExternalSession[<|"System" -> "Python", "Executable" -> pyExe|>], $Failed], $Failed],
  Gravifer`Einstoff`Tests`$PySession];
pythonReady = TrueQ @ Quiet @ Check[
  Head[pySession] === ExternalSessionObject &&
  ExternalEvaluate[pySession, "import numpy, einx; True"] === True,
  False];

pyDims[l_List] := "[" <> StringRiffle[ToString /@ l, ", "] <> "]";

pyDotN[pattern_, dimsList_List] :=
  Module[{setup, args},
    setup = StringJoin @ MapIndexed[
      With[{nm = "x" <> ToString[First[#2] - 1], d = #1},
        nm <> " = (1 + np.arange(" <> ToString[Times @@ d] <> ")).reshape(" <>
          pyDims[d] <> ")\n"] &, dimsList];
    args = StringRiffle[Table["x" <> ToString[i], {i, 0, Length[dimsList] - 1}], ", "];
    ExternalEvaluate[pySession,
      "import numpy as np, einx\n" <> setup <>
      "np.asarray(einx.dot(" <> ToString[pattern, InputForm] <> ", " <> args <> ")).tolist()"]];

(* ======================================================================== *)
BeginTestSection["Gravifer`Einstoff`CrossValidation`Inner", pythonReady];

(* Inner[Times, Plus] matmul === einx.dot *)
VerificationTest[
  Einstoff[Inner][Times, Plus][{{a_, b_}, {b_, c_}} :> {{a, c}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}]}],
  pyDotN["a b, b c -> a c", {{2, 3}, {3, 4}}],
  TestID -> "xval-inner-times-plus-matmul"
];

(* Inner[Times, Plus] three-operand chain === einx.dot *)
VerificationTest[
  Einstoff[Inner][Times, Plus][{{a_, b_}, {b_, c_}, {c_, d_}} :> {{a, d}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[12], {3, 4}], ArrayReshape[Range[20], {4, 5}]}],
  pyDotN["a b, b c, c d -> a d", {{2, 3}, {3, 4}, {4, 5}}],
  TestID -> "xval-inner-times-plus-chain"
];

EndTestSection[];
(* ======================================================================== *)

If[pyOwned && Head[pySession] === ExternalSessionObject, Quiet @ DeleteObject[pySession]];
