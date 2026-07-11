#!/usr/bin/env wolframscript
(* Representative staged-compiler acceptance benchmarks. The script reports elapsed
   seconds and fails only on semantic failure or compiler-created axis-symbol growth;
   timing comparisons are recorded for review rather than encoded as machine-specific
   absolute thresholds. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];
PacletDirectoryLoad[root];
Needs["Einstoff`"];

compile = Symbol["Einstoff`PackageScope`compileDescIR"];

SetAttributes[runCase, HoldRest];
runCase[name_String, repeats_Integer, expr_] :=
  Module[{value, elapsed},
    elapsed = First @ AbsoluteTiming[
      Do[value = expr, {repeats}]];
    If[value === $Failed || Head[value] === Einstoff`Internal`IR`FailureRecord,
      Print["FAIL ", name, ": ", InputForm[value]];
      Exit[1]];
    <|"Case" -> name, "Repeats" -> repeats,
      "Seconds" -> elapsed, "SecondsPerRun" -> elapsed/repeats|>
  ];

x = ArrayReshape[Range[120], {10, 12}];
y = ArrayReshape[Range[84], {12, 7}];
z = ArrayReshape[Range[35], {7, 5}];

beforeNames = Sort @ Join[
  Names["Einstoff`Axis`*"], Names["Einstoff`Internal`DisplayAxis`*"]];

results = {
  runCase["simple-reshape", 20,
    Einstoff[ArrayReshape][{{a_, b_}} :> {{b, a}}, {x}]],
  runCase["composite-split-merge", 20,
    Einstoff[ArrayReshape][
      {{CircleTimes["h", w_]}} :> {{"h", w}}, {Range[120]}, {"h" -> 10}]],
  runCase["long-ellipsis-solve", 20,
    Einstoff`EinstoffShapes[{{a__}} :> {{a..}},
      {{2, 3, 4, 5, 6, 7, 8}}]],
  runCase["multi-operand-dot", 10,
    Einstoff[Dot][{{a_, b_}, {b_, c_}, {c_, d_}} :> {{a, d}}, {x, y, z}]],
  runCase["direct-sum", 20,
    Einstoff[Join][{{a_, b_}, {a_, c_}} :> {{a, CirclePlus[b, c]}},
      {ArrayReshape[Range[30], {10, 3}], ArrayReshape[Range[40], {10, 4}]}]],
  runCase["repeated-compilation", 200,
    compile[{{a_, CircleTimes["h", w_]}} :> {{w, a, "h"}}, {"h" -> 3}]]
};

afterNames = Sort @ Join[
  Names["Einstoff`Axis`*"], Names["Einstoff`Internal`DisplayAxis`*"]];
growth = Complement[afterNames, beforeNames];

Scan[Print[# ["Case"], ": ",
    ToString[N[Round[# ["SecondsPerRun"], 10^-6]], InputForm],
    " s/run (", # ["Repeats"], " runs)"] &, results];
Print["compiler axis-symbol growth: ", ToString[growth, InputForm]];

If[growth =!= {}, Exit[1]];
Exit[0];
