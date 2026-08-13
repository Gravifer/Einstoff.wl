#!/usr/bin/env wolframscript

(* Build the publisher-qualified paclet into the repository's ignored build/
   directory. Native documentation is built by PacletBuild as part of this step. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];
pacletDir = FileNameJoin[{root, "Gravifer__Einstoff"}];
buildDir = FileNameJoin[{root, "build"}];
stagingDir = FileNameJoin[{
  buildDir,
  "staging-" <> StringReplace[CreateUUID[], "-" -> ""]
}];

Needs["PacletTools`"];

If[! DirectoryQ[buildDir], CreateDirectory[buildDir]];
CreateDirectory[stagingDir];
cleanupStaging[] := If[
  DirectoryQ[stagingDir],
  Quiet[DeleteDirectory[stagingDir, DeleteContents -> True]]
];

(* Check[expr, $Failed] treats every emitted build warning as a fatal error, even
   when PacletBuild returns a usable archive. Keep warnings visible and validate
   the returned object instead. A fresh staging directory also prevents prior
   generated documentation from influencing this build. *)
result = PacletBuild[pacletDir, stagingDir];
If[result === $Failed || FailureQ[result],
  cleanupStaging[];
  Print["PacletBuild failed: ", result // InputForm];
  Exit[1]
];

archive = Replace[result["PacletArchive"], File[path_String] :> path];
If[! StringQ[archive] || ! FileExistsQ[archive],
  cleanupStaging[];
  Print["PacletBuild did not return an existing archive: ", result // InputForm];
  Exit[1]
];

publishedArchive = FileNameJoin[{buildDir, FileNameTake[archive]}];
copyResult = Quiet @ Check[
  CopyFile[archive, publishedArchive, OverwriteTarget -> True],
  $Failed
];
cleanupStaging[];
If[copyResult === $Failed || ! FileExistsQ[publishedArchive],
  Print["Could not publish the built archive to: ", publishedArchive];
  Exit[1]
];

Print["PACLET_ARCHIVE=", ExpandFileName[publishedArchive]];
