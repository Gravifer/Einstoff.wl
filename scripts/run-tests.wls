#!/usr/bin/env wolframscript
(* Runner for the Einstoff parsing-layer test suite.
   Usage:  wolframscript -file scripts/run-tests.wls   *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];

(* Load the Einstoff paclet from the project tree (structured package format). *)
PacletDirectoryLoad[root];
Needs["Einstoff`"];

(* Discover and run every tests/*.test.wl file. *)
testFiles = FileNames["*.test.wl", FileNameJoin[{root, "tests"}]];

reports = AssociationMap[TestReport, testFiles];

allOK = True;
KeyValueMap[
  Function[{file, report},
    Print[FileNameTake[file], ":  ",
      report["TestsSucceededCount"], " succeeded, ",
      report["TestsFailedCount"], " failed"];
    failed = Join[
      Values @ report["TestsFailedWrongResults"],
      Values @ report["TestsFailedWithMessages"],
      Values @ report["TestsFailedWithErrors"]
    ];
    If[failed =!= {},
      allOK = False;
      Scan[
        Print["  ", #["TestID"], ":  got ", #["ActualOutput"],
              "  expected ", #["ExpectedOutput"]] &,
        failed]]],
  reports];

Exit[If[allOK, 0, 1]];
