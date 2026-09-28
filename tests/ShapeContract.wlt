(* Input arrays and user-function results must have complete rectangular shapes.
   Dimensions alone reports only the rectangular prefix of a ragged List. *)

BeginTestSection["Gravifer`Einstoff`ShapeContract"];

ClearAll[a, b, c];

VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a}}, {{{1, 2}, {3}}}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-ragged-reshape-input"
];

VerificationTest[
  Einstoff[ArrayReshape][{{a_}} :> {{a}}, {{{1, 2}, {3}}},
    TraceAction -> Hold],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-ragged-input-in-trace"
];

VerificationTest[
  Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}},
    {{{{1, 2}, {3, 4}}, {{5, 6}, {7}}}}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-nested-ragged-input"
];

VerificationTest[
  Einstoff[ArrayReduce][Total][{{a_, Highlighted[b_]}} :> {{a}},
    {{{1, 2}, {3}}}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-ragged-reduction-input"
];

VerificationTest[
  Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}},
    {{{1, 2}, {3, 4}}, {{1, 2}, {3}}}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-ragged-second-input"
];

VerificationTest[
  Einstoff["Massage"][{{a_}, {b_}} :> {{CirclePlus[a, b]}},
    {{{1, 2}, {3}}, {4, 5}}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-ragged-direct-sum-input"
];

VerificationTest[
  Einstoff[ArrayReduce][Identity][{{a_, Highlighted[b_]}} :> {{a}},
    {{{1, 2}, {3, 4}}}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-nonscalar-reducer-result"
];

VerificationTest[
  Module[{u, v},
    Einstoff[ArrayReduce][Total][{{Highlighted[a_]}} :> {{}},
      {{u, v}}] === u + v],
  True,
  TestID -> "shape-accept-symbolic-scalar-reducer-result"
];

VerificationTest[
  Einstoff[ArrayReduce][Total][{{Highlighted[a_]}} :> {{}},
    {{Quantity[2, "Meters"], Quantity[3, "Meters"]}}],
  Quantity[5, "Meters"],
  TestID -> "shape-accept-quantity-scalar-reducer-result"
];

VerificationTest[
  Einstoff[ArrayReduce][If[First[#] === 1, 1, {2}] &][
    {{a_, Highlighted[b_]}} :> {{a}}, {{{1, 2}, {3, 4}}}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-ragged-reducer-result"
];

VerificationTest[
  Einstoff[Inner][List, Total][{{a_}, {a_}} :> {{}},
    {{1, 2}, {3, 4}}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-nonscalar-inner-result"
];

VerificationTest[
  Module[{calls = 0, result},
    result = Einstoff[Map][(calls++; If[# === 1, {1}, {2, 3}]) &][
      {{a_}} :> {{a}}, {{1, 2}}];
    {result, calls}],
  {$Failed, 2}, {Einstoff::unsat},
  TestID -> "shape-reject-ragged-map-result-without-recalling-function"
];

VerificationTest[
  Einstoff[Operate][If[First[#] === 1, {{1}, {2, 3}}, #] &][
    {{a_, Highlighted[b_]}} :> {{a, b}},
    {ArrayReshape[Range[4], {2, 2}]}],
  $Failed, {Einstoff::unsat},
  TestID -> "shape-reject-ragged-operated-block"
];

VerificationTest[
  Module[{u, v, w, z, x = {{u, v}, {w, z}}},
    Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}] === Transpose[x]],
  True,
  TestID -> "shape-preserve-symbolic-scalar-elements"
];

VerificationTest[
  Module[{x, y},
    Einstoff[ArrayReshape][{{}} :> {{}}, {x + y}] === x + y],
  True,
  TestID -> "shape-accept-compound-scalar-input"
];

VerificationTest[
  Einstoff[ArrayReshape][{{}} :> {{}}, {Quantity[2, "Meters"]}],
  Quantity[2, "Meters"],
  TestID -> "shape-accept-quantity-scalar-input"
];

VerificationTest[
  Module[{f},
    Einstoff[ArrayReshape][{{}} :> {{}}, {f[1, 2]}] === f[1, 2]],
  True,
  TestID -> "shape-accept-general-compound-scalar-input"
];

VerificationTest[
  With[{x = SparseArray[{{1, 2} -> 4}, {2, 2}]},
    Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}] === Transpose[x]],
  True,
  TestID -> "shape-preserve-sparse-array"
];

VerificationTest[
  With[{x = NumericArray[{{1, 2}, {3, 4}}]},
    Normal @ Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}]],
  {{1, 3}, {2, 4}},
  TestID -> "shape-preserve-numeric-array"
];

EndTestSection[];
