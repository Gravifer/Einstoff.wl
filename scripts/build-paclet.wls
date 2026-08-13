#!/usr/bin/env wolframscript

(* Build the publisher-qualified paclet into the repository's ignored build/
   directory. Native documentation is built by PacletBuild as part of this step. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];
pacletDir = FileNameJoin[{root, "Gravifer__Einstoff"}];
buildDir = FileNameJoin[{root, "build"}];

Needs["PacletTools`"];

If[! DirectoryQ[buildDir], CreateDirectory[buildDir]];

result = Quiet @ Check[PacletBuild[pacletDir, buildDir], $Failed];
If[result === $Failed || FailureQ[result],
  Print["PacletBuild failed: ", result // InputForm];
  Exit[1]
];

archive = Replace[result["PacletArchive"], File[path_String] :> path];
If[! StringQ[archive] || ! FileExistsQ[archive],
  Print["PacletBuild did not return an existing archive: ", result // InputForm];
  Exit[1]
];

Print["PACLET_ARCHIVE=", ExpandFileName[archive]];
