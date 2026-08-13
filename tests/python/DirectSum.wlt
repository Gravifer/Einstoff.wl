(* ::Package:: *)

(* Cross-validation tests for the direct-sum lowering: Einstoff["Massage"],
   Einstoff[Join] and Einstoff[Split] checked against the actual einx.id `+`
   (SPEC §10.1). Companion to the other tests/python/*.wlt; see Reshape.wlt for
   the full rationale.

   Opt-in only: `wolframscript -script scripts/run-tests.wls python`.
   Integer inputs -> exact equality, no tolerance.

   einx matches direct-sum summands positionally; the einx pattern <-> Wolfram desc
   equivalence is reasoned out of band. *)

ClearAll[a, b, c, d, e, m, n, p, x];

pyRoot =
  If[ValueQ[Gravifer`Einstoff`Tests`$Root], Gravifer`Einstoff`Tests`$Root,
    ParentDirectory[PacletObject["Gravifer/Einstoff"]["Location"]]];
pyExe = FileNameJoin[{pyRoot, ".venv", "Scripts", "python.exe"}];

(* Reuse the runner's shared session if it spawned one (one ZMQ session per kernel
   is stable, many are not); otherwise spawn our own so the file still runs under a
   bare TestReport, and own only that teardown. *)
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
BeginTestSection["Gravifer`Einstoff`CrossValidation`DirectSum", pythonReady];

(* concat 'm a, m b -> m (a + b)'  <->  {{m_,a_},{m_,b_}} :> {{m, a ⊕ b}} *)
VerificationTest[
  Einstoff["Massage"][{{m_, a_}, {m_, b_}} :> {{m, CirclePlus[a, b]}},
    {ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}]}],
  pyConcat["m a, m b -> m (a + b)", {{2, 3}, {2, 4}}],
  TestID -> "xval-concat-axis2"
];

(* concat axis 1 'a m, b m -> (a + b) m'  <->  {{a_,m_},{b_,m_}} :> {{a ⊕ b, m}} *)
VerificationTest[
  Einstoff["Massage"][{{a_, m_}, {b_, m_}} :> {{CirclePlus[a, b], m}},
    {ArrayReshape[Range[6], {3, 2}], ArrayReshape[Range[4], {2, 2}]}],
  pyConcat["a m, b m -> (a + b) m", {{3, 2}, {2, 2}}],
  TestID -> "xval-concat-axis1"
];

(* scalar append 'b c, -> b (c + 1)' with scalar 42  <->  {{b_,c_},{}} :> {{b, c ⊕ 1}} *)
VerificationTest[
  Einstoff["Massage"][{{b_, c_}, {}} :> {{b, CirclePlus[c, 1]}},
    {ArrayReshape[Range[15], {3, 5}], 42}],
  pyConcat["b c, -> b (c + 1)", {{3, 5}, {}}],
  TestID -> "xval-concat-scalar-append"
];

(* three-way 'm a, m b, m c -> m (a + b + c)' *)
VerificationTest[
  Einstoff["Massage"][{{m_, a_}, {m_, b_}, {m_, c_}} :> {{m, CirclePlus[a, b, c]}},
    {ArrayReshape[Range[2], {2, 1}], ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}]}],
  pyConcat["m a, m b, m c -> m (a + b + c)", {{2, 1}, {2, 2}, {2, 3}}],
  TestID -> "xval-concat-three-way"
];

(* composite summand 'm (a b), m c -> m ((a b) + c)', a=2
   <->  {{m_, a_ ⊗ b_}, {m_, c_}} :> {{m, (a ⊗ b) ⊕ c}} *)
VerificationTest[
  Einstoff["Massage"][{{m_, CircleTimes["a", b_]}, {m_, c_}} :> {{m, CirclePlus[CircleTimes["a", b], c]}},
    {ArrayReshape[Range[12], {2, 6}], ArrayReshape[Range[8], {2, 4}]}, {"a" -> 2}],
  pyConcat["m (a b), m c -> m ((a b) + c)", {{2, 6}, {2, 4}}, <|"a" -> 2|>],
  TestID -> "xval-concat-composite"
];

(* multiple direct-sum axes 'a b, a c, d b, d c -> (a + d) (b + c)' *)
VerificationTest[
  Einstoff["Massage"][
    {{a_, b_}, {a_, c_}, {d_, b_}, {d_, c_}} :>
      {{CirclePlus[a, d], CirclePlus[b, c]}},
    {ArrayReshape[Range[2], {1, 2}], ArrayReshape[Range[3], {1, 3}],
     ArrayReshape[Range[4], {2, 2}], ArrayReshape[Range[6], {2, 3}]}],
  pyConcat["a b, a c, d b, d c -> (a + d) (b + c)",
    {{1, 2}, {1, 3}, {2, 2}, {2, 3}}],
  TestID -> "xval-concat-multiple-direct-sum-axes"
];

(* non-adjacent direct-sum axes around a carried axis *)
VerificationTest[
  Einstoff["Massage"][
    {{a_, m_, b_}, {a_, m_, c_}, {d_, m_, b_}, {d_, m_, c_}} :>
      {{CirclePlus[a, d], m, CirclePlus[b, c]}},
    {ArrayReshape[Range[4], {1, 2, 2}], ArrayReshape[Range[6], {1, 2, 3}],
     ArrayReshape[Range[8], {2, 2, 2}], ArrayReshape[Range[12], {2, 2, 3}]}],
  pyConcat["a m b, a m c, d m b, d m c -> (a + d) m (b + c)",
    {{1, 2, 2}, {1, 2, 3}, {2, 2, 2}, {2, 2, 3}}],
  TestID -> "xval-concat-multiple-direct-sum-axes-nonadjacent"
];

(* rectangular 2-by-3 Cartesian grid; last direct-sum axis varies fastest *)
VerificationTest[
  Einstoff["Massage"][
    {{a_, b_}, {a_, c_}, {a_, e_}, {d_, b_}, {d_, c_}, {d_, e_}} :>
      {{CirclePlus[a, d], CirclePlus[b, c, e]}},
    {ArrayReshape[Range[2], {1, 2}], ArrayReshape[Range[3], {1, 3}],
     ArrayReshape[Range[4], {1, 4}], ArrayReshape[Range[4], {2, 2}],
     ArrayReshape[Range[6], {2, 3}], ArrayReshape[Range[8], {2, 4}]}],
  pyConcat["a b, a c, a e, d b, d c, d e -> (a + d) (b + c + e)",
    {{1, 2}, {1, 3}, {1, 4}, {2, 2}, {2, 3}, {2, 4}}],
  TestID -> "xval-concat-multiple-direct-sum-axes-rectangular-grid"
];

(* integer/unit summands broadcast inside a multi-axis Cartesian grid *)
VerificationTest[
  Einstoff["Massage"][
    {{a_, b_}, {a_}, {d_, b_}, {}} :> {{CirclePlus[a, d], CirclePlus[b, 1]}},
    {ArrayReshape[Range[2], {1, 2}], ArrayReshape[Range[1], {1}],
     ArrayReshape[Range[4], {2, 2}], 42}],
  pyConcat["a b, a, d b, -> (a + d) (b + 1)",
    {{1, 2}, {1}, {2, 2}, {}}],
  TestID -> "xval-concat-multiple-direct-sum-axes-integer-summand"
];

(* composite summand sizing composes with a second direct-sum axis *)
VerificationTest[
  Einstoff["Massage"][
    {{p_, CircleTimes["a", b_], x_}, {p_, c_, x_},
     {n_, CircleTimes["a", b_], x_}, {n_, c_, x_}} :>
      {{CirclePlus[p, n], CirclePlus[CircleTimes["a", b], c], x}},
    {ArrayReshape[Range[12], {1, 6, 2}], ArrayReshape[Range[8], {1, 4, 2}],
     ArrayReshape[Range[24], {2, 6, 2}], ArrayReshape[Range[16], {2, 4, 2}]},
    {"a" -> 2}],
  pyConcat["p (a b) x, p c x, n (a b) x, n c x -> (p + n) ((a b) + c) x",
    {{1, 6, 2}, {1, 4, 2}, {2, 6, 2}, {2, 4, 2}}, <|"a" -> 2|>],
  TestID -> "xval-concat-multiple-direct-sum-axes-composite-summand"
];

(* --- splitting (einx `+` on LHS, returns a tuple of outputs) --- *)

(* split 'm (a + b) -> m a, m b', a=3  <->  {{m_, a_ ⊕ b_}} :> {{m, a}, {m, b}} *)
VerificationTest[
  Einstoff["Massage"][{{m_, CirclePlus["a", b_]}} :> {{m, "a"}, {m, b}},
    {ArrayReshape[Range[20], {2, 10}]}, {"a" -> 3}],
  pySplit["m (a + b) -> m a, m b", {2, 10}, <|"a" -> 3|>],
  TestID -> "xval-split-two-way"
];

(* split along axis 1 '(a + b) m -> a m, b m', a=2 *)
VerificationTest[
  Einstoff["Massage"][{{CirclePlus["a", b_], m_}} :> {{"a", m}, {b, m}},
    {ArrayReshape[Range[20], {5, 4}]}, {"a" -> 2}],
  pySplit["(a + b) m -> a m, b m", {5, 4}, <|"a" -> 2|>],
  TestID -> "xval-split-axis1"
];

(* three-way split 'm (a + b + c) -> m a, m b, m c', a=2, b=3 *)
VerificationTest[
  Einstoff["Massage"][{{m_, CirclePlus["a", "b", c_]}} :> {{m, "a"}, {m, "b"}, {m, c}},
    {ArrayReshape[Range[20], {2, 10}]}, {"a" -> 2, "b" -> 3}],
  pySplit["m (a + b + c) -> m a, m b, m c", {2, 10}, <|"a" -> 2, "b" -> 3|>],
  TestID -> "xval-split-three-way"
];

(* composite-block split 'm ((a b) + c) -> m (a b), m c', a=2, b=3 (determined)
   <->  {{m_, (a_ ⊗ b_) ⊕ c_}} :> {{m, a ⊗ b}, {m, c}} *)
VerificationTest[
  Einstoff["Massage"][{{m_, CirclePlus[CircleTimes["a", "b"], c_]}} :> {{m, CircleTimes["a", "b"]}, {m, c}},
    {ArrayReshape[Range[20], {2, 10}]}, {"a" -> 2, "b" -> 3}],
  pySplit["m ((a b) + c) -> m (a b), m c", {2, 10}, <|"a" -> 2, "b" -> 3|>],
  TestID -> "xval-split-composite"
];

(* multiple direct-sum axes '(a + d) (b + c) -> a b, a c, d b, d c' *)
VerificationTest[
  Einstoff["Massage"][
    {{CirclePlus["a", d_], CirclePlus["b", c_]}} :>
      {{"a", "b"}, {"a", c}, {d, "b"}, {d, c}},
    {ArrayReshape[Range[15], {3, 5}]}, {"a" -> 1, "b" -> 2}],
  pySplit["(a + d) (b + c) -> a b, a c, d b, d c",
    {3, 5}, <|"a" -> 1, "b" -> 2|>],
  TestID -> "xval-split-multiple-direct-sum-axes"
];

(* non-adjacent direct-sum axes around a carried axis *)
VerificationTest[
  Einstoff["Massage"][
    {{CirclePlus["a", d_], m_, CirclePlus["b", c_]}} :>
      {{"a", m, "b"}, {"a", m, c}, {d, m, "b"}, {d, m, c}},
    {ArrayReshape[Range[30], {3, 2, 5}]}, {"a" -> 1, "b" -> 2}],
  pySplit["(a + d) m (b + c) -> a m b, a m c, d m b, d m c",
    {3, 2, 5}, <|"a" -> 1, "b" -> 2|>],
  TestID -> "xval-split-multiple-direct-sum-axes-nonadjacent"
];

(* each Cartesian slice may then be permuted independently *)
VerificationTest[
  Einstoff["Massage"][
    {{CirclePlus["a", d_], m_, CirclePlus["b", c_]}} :>
      {{"b", m, "a"}, {"a", c, m}, {d, "b", m}, {c, d, m}},
    {ArrayReshape[Range[30], {3, 2, 5}]}, {"a" -> 1, "b" -> 2}],
  pySplit["(a + d) m (b + c) -> b m a, a c m, d b m, c d m",
    {3, 2, 5}, <|"a" -> 1, "b" -> 2|>],
  TestID -> "xval-split-multiple-direct-sum-axes-permute-blocks"
];

(* rectangular 2-by-3 split grid; last direct-sum axis varies fastest *)
VerificationTest[
  Einstoff["Massage"][
    {{CirclePlus["a", d_], CirclePlus["b", "c", e_]}} :>
      {{"a", "b"}, {"a", "c"}, {"a", e}, {d, "b"}, {d, "c"}, {d, e}},
    {ArrayReshape[Range[27], {3, 9}]}, {"a" -> 1, "b" -> 2, "c" -> 3}],
  pySplit["(a + d) (b + c + e) -> a b, a c, a e, d b, d c, d e",
    {3, 9}, <|"a" -> 1, "b" -> 2, "c" -> 3|>],
  TestID -> "xval-split-multiple-direct-sum-axes-rectangular-grid"
];

(* integer/unit summand blocks keep singleton outputs when requested *)
VerificationTest[
  Einstoff["Massage"][
    {{CirclePlus["a", d_], CirclePlus["b", 1]}} :>
      {{"a", "b"}, {"a", 1}, {d, "b"}, {d, 1}},
    {ArrayReshape[Range[9], {3, 3}]}, {"a" -> 1, "b" -> 2}],
  pySplit["(a + d) (b + 1) -> a b, a 1, d b, d 1",
    {3, 3}, <|"a" -> 1, "b" -> 2|>],
  TestID -> "xval-split-multiple-direct-sum-axes-integer-summand"
];

(* composite summand sizing composes with a second direct-sum axis *)
VerificationTest[
  Einstoff["Massage"][
    {{CirclePlus["p", n_], CirclePlus[CircleTimes["a", "b"], c_], x_}} :>
      {{"p", CircleTimes["a", "b"], x}, {"p", c, x},
       {n, CircleTimes["a", "b"], x}, {n, c, x}},
    {ArrayReshape[Range[60], {3, 10, 2}]}, {"p" -> 1, "a" -> 2, "b" -> 3}],
  pySplit["(p + n) ((a b) + c) x -> p (a b) x, p c x, n (a b) x, n c x",
    {3, 10, 2}, <|"p" -> 1, "a" -> 2, "b" -> 3|>],
  TestID -> "xval-split-multiple-direct-sum-axes-composite-summand"
];

EndTestSection[];
(* ======================================================================== *)

If[pyOwned && Head[pySession] === ExternalSessionObject, Quiet @ DeleteObject[pySession]];
