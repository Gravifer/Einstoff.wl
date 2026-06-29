(* ::Package:: *)

(* Cross-validation tests for the direct-sum concat lowering: Einstoff[ArrayReshape]
   / Einstoff[Join] checked against the actual einx.id `+` (SPEC §10.1). Companion
   to the other tests/python/*.wlt; see Reshape.wlt for the full rationale.

   Opt-in only: `wolframscript -script scripts/run-tests.wls python`.
   Integer inputs -> exact equality, no tolerance.

   einx concatenates along a direct-sum axis positionally (summand i <- operand i);
   the einx pattern <-> Wolfram desc equivalence is reasoned out of band. *)

ClearAll[a, b, c, m];

pyRoot =
  If[ValueQ[Einstoff`Tests`$Root], Einstoff`Tests`$Root,
    ParentDirectory[PacletObject["Einstoff"]["Location"]]];
pyExe = FileNameJoin[{pyRoot, ".venv", "Scripts", "python.exe"}];

(* Reuse the runner's shared session if it spawned one (one ZMQ session per kernel
   is stable, many are not); otherwise spawn our own so the file still runs under a
   bare TestReport, and own only that teardown. *)
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

pyDims[l_List] := "[" <> StringRiffle[ToString /@ l, ", "] <> "]";

(* pyConcat[pattern, {dimsList...}, kwargs]: build each operand from its dims recipe
   inside Python (x0, x1, …), apply einx.id with any out-of-band axis sizes, return
   WL int lists. A dims of {} builds a 0-d scalar operand. *)
pyConcat[pattern_, dimsList_List, kwargs_ : <||>] :=
  Module[{setup, args, kw},
    setup = StringJoin @ MapIndexed[
      With[{nm = "x" <> ToString[First[#2] - 1], d = #1},
        If[d === {},
          nm <> " = np.asarray(42)\n",
          nm <> " = (1 + np.arange(" <> ToString[Times @@ d] <> ")).reshape(" <>
            pyDims[d] <> ")\n"]] &,
      dimsList];
    args = StringRiffle[Table["x" <> ToString[i], {i, 0, Length[dimsList] - 1}], ", "];
    kw = StringRiffle[KeyValueMap[#1 <> "=" <> ToString[#2] &, kwargs], ", "];
    ExternalEvaluate[pySession,
      "import numpy as np, einx\n" <> setup <>
      "np.asarray(einx.id(" <> ToString[pattern, InputForm] <> ", " <> args <>
        If[kw === "", "", ", " <> kw] <> ")).tolist()"]];

(* pySplit[pattern, dims, kwargs]: build one operand from `dims`, apply the einx.id
   split, and return the tuple of output arrays as a WL list of int lists. *)
pySplit[pattern_, dims_List, kwargs_Association] :=
  Module[{kw = StringRiffle[KeyValueMap[#1 <> "=" <> ToString[#2] &, kwargs], ", "]},
    ExternalEvaluate[pySession,
      "import numpy as np, einx\n" <>
      "x = (1 + np.arange(" <> ToString[Times @@ dims] <> ")).reshape(" <> pyDims[dims] <> ")\n" <>
      "[np.asarray(o).tolist() for o in einx.id(" <> ToString[pattern, InputForm] <>
        ", x" <> If[kw === "", "", ", " <> kw] <> ")]"]];

(* ======================================================================== *)
BeginTestSection["Einstoff`CrossValidation`DirectSum", pythonReady];

(* concat 'm a, m b -> m (a + b)'  <->  {{m_,a_},{m_,b_}} :> {{m, a ⊕ b}} *)
VerificationTest[
  Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}]}],
  pyConcat["m a, m b -> m (a + b)", {{2, 3}, {2, 4}}],
  TestID -> "xval-concat-axis2"
];

(* concat axis 1 'a m, b m -> (a + b) m'  <->  {{a_,m_},{b_,m_}} :> {{a ⊕ b, m}} *)
VerificationTest[
  Einstoff[ArrayReshape][{{a_, m_}, {b_, m_}} :> {{CirclePlus[a, b], m}},
    {ArrayReshape[Range[6], {3, 2}], ArrayReshape[Range[4], {2, 2}]}],
  pyConcat["a m, b m -> (a + b) m", {{3, 2}, {2, 2}}],
  TestID -> "xval-concat-axis1"
];

(* scalar append 'b c, -> b (c + 1)' with scalar 42  <->  {{b_,c_},{}} :> {{b, c ⊕ 1}} *)
VerificationTest[
  Einstoff[ArrayReshape][{{b_, c_}, {}} :> {{b, CirclePlus[c, 1]}},
    {ArrayReshape[Range[15], {3, 5}], 42}],
  pyConcat["b c, -> b (c + 1)", {{3, 5}, {}}],
  TestID -> "xval-concat-scalar-append"
];

(* three-way 'm a, m b, m c -> m (a + b + c)' *)
VerificationTest[
  Einstoff[ArrayReshape][{{m_, a_}, {m_, b_}, {m_, c_}} :> {{m, CirclePlus[a, b, c]}},
    {ArrayReshape[Range[2], {2, 1}], ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}]}],
  pyConcat["m a, m b, m c -> m (a + b + c)", {{2, 1}, {2, 2}, {2, 3}}],
  TestID -> "xval-concat-three-way"
];

(* composite summand 'm (a b), m c -> m ((a b) + c)', a=2
   <->  {{m_, a_ ⊗ b_}, {m_, c_}} :> {{m, (a ⊗ b) ⊕ c}} *)
VerificationTest[
  Einstoff[ArrayReshape][{{m_, CircleTimes[a_, b_]}, {m_, c_}} :> {{m, CirclePlus[CircleTimes[a, b], c]}},
    {ArrayReshape[Range[12], {2, 6}], ArrayReshape[Range[8], {2, 4}]}, {a -> 2}],
  pyConcat["m (a b), m c -> m ((a b) + c)", {{2, 6}, {2, 4}}, <|"a" -> 2|>],
  TestID -> "xval-concat-composite"
];

(* --- splitting (einx `+` on LHS, returns a tuple of outputs) --- *)

(* split 'm (a + b) -> m a, m b', a=3  <->  {{m_, a_ ⊕ b_}} :> {{m, a}, {m, b}} *)
VerificationTest[
  Einstoff[ArrayReshape][{{m_, CirclePlus[a_, b_]}} :> {{m, a}, {m, b}},
    {ArrayReshape[Range[20], {2, 10}]}, {a -> 3}],
  pySplit["m (a + b) -> m a, m b", {2, 10}, <|"a" -> 3|>],
  TestID -> "xval-split-two-way"
];

(* split along axis 1 '(a + b) m -> a m, b m', a=2 *)
VerificationTest[
  Einstoff[ArrayReshape][{{CirclePlus[a_, b_], m_}} :> {{a, m}, {b, m}},
    {ArrayReshape[Range[20], {5, 4}]}, {a -> 2}],
  pySplit["(a + b) m -> a m, b m", {5, 4}, <|"a" -> 2|>],
  TestID -> "xval-split-axis1"
];

(* three-way split 'm (a + b + c) -> m a, m b, m c', a=2, b=3 *)
VerificationTest[
  Einstoff[ArrayReshape][{{m_, CirclePlus[a_, b_, c_]}} :> {{m, a}, {m, b}, {m, c}},
    {ArrayReshape[Range[20], {2, 10}]}, {a -> 2, b -> 3}],
  pySplit["m (a + b + c) -> m a, m b, m c", {2, 10}, <|"a" -> 2, "b" -> 3|>],
  TestID -> "xval-split-three-way"
];

EndTestSection[];
(* ======================================================================== *)

If[pyOwned && Head[pySession] === ExternalSessionObject, Quiet @ DeleteObject[pySession]];
