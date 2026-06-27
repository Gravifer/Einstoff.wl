#!/usr/bin/env wolframscript
(* Runner for the Einstoff parsing-layer test suite.
   Usage:  wolframscript -file scripts/run-tests.wls   *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];

Get[FileNameJoin[{root, "Einstoff", "Parsing.wl"}]];

report = TestReport[FileNameJoin[{root, "tests", "Parsing.test.wl"}]];

Print["Tests succeeded: ", report["TestsSucceededCount"]];
Print["Tests failed:    ", report["TestsFailedCount"]];

failed = Join[
  Values @ report["TestsFailedWrongResults"],
  Values @ report["TestsFailedWithMessages"],
  Values @ report["TestsFailedWithErrors"]
];

If[failed =!= {},
  Print["----- Failures -----"];
  Scan[
    Print["  ", #["TestID"], ":  got ", #["ActualOutput"],
          "  expected ", #["ExpectedOutput"]] &,
    failed]];

Exit[If[report["AllTestsSucceeded"], 0, 1]];
