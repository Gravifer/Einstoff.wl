(* ::Package:: *)

(* Cross-validation for Einstoff[Operate] against einx's miscellaneous ops
   (https://einx.readthedocs.io/en/stable/api/operations/misc.html): flip, sort,
   roll and softmax along a bracketed axis ("a [b]").  Integer ops are compared
   exactly; softmax is float, compared within a tolerance.  NB einx.roll(shift=k)
   shifts toward higher indices, i.e. it is RotateRight[#, k] (verified vs numpy).

   Opt-in only: `wolframscript -script scripts/run-tests.wls python`.
   Session setup duplicated from the other python suites (self-contained). *)

ClearAll[a, b];

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
  ExternalEvaluate[pySession, "import numpy, einx; True"] === True,
  False];

(* Run einx `call` (a Python expression in x) on the array built by `pyInput`
   (a Python expression), returning the result as a nested list. *)
pyMap[call_String, pyInput_String] :=
  ExternalEvaluate[pySession,
    "import numpy as np, einx\nx = " <> pyInput <> "\nnp.asarray(" <> call <> ").tolist()"];

approxEqual[u_, v_] := Max @ Abs @ Flatten[N[u] - v] < 1.*^-9;

(* ======================================================================== *)
BeginTestSection["Einstoff`CrossValidation`Operate", pythonReady];

(* flip (einx.flip) — reverse along the bracket; integer, exact. *)
VerificationTest[
  Einstoff[Operate]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}},
    {ArrayReshape[Range[8], {2, 4}]}],
  pyMap["einx.flip('a [b]', x)", "(1 + np.arange(8)).reshape(2, 4)"],
  TestID -> "xval-operate-flip"
];

(* sort (einx.sort) — ascending along the bracket; descending input, exact. *)
VerificationTest[
  Einstoff[Operate]["sort"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}},
    {ArrayReshape[Reverse[Range[8]], {2, 4}]}],
  pyMap["einx.sort('a [b]', x)", "(8 - np.arange(8)).reshape(2, 4)"],
  TestID -> "xval-operate-sort"
];

(* roll (einx.roll, shift=1) === RotateRight[#, 1]&; integer, exact. *)
VerificationTest[
  Einstoff[Operate][RotateRight[#, 1] &][{{a_, Slot["b"]}} :> {{a, Slot["b"]}},
    {ArrayReshape[Range[8], {2, 4}]}],
  pyMap["einx.roll('a [b]', x, shift=1)", "(1 + np.arange(8)).reshape(2, 4)"],
  TestID -> "xval-operate-roll"
];

(* softmax (einx.softmax) along the bracket; float, within tolerance. *)
VerificationTest[
  approxEqual[
    Einstoff[Operate]["softmax"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}},
      {ArrayReshape[Range[8], {2, 4}]}],
    pyMap["einx.softmax('a [b]', x)", "(1.0 + np.arange(8)).reshape(2, 4)"]],
  True,
  TestID -> "xval-operate-softmax"
];

EndTestSection[];
(* ======================================================================== *)

If[pyOwned && Head[pySession] === ExternalSessionObject, Quiet @ DeleteObject[pySession]];
