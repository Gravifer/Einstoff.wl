#!/usr/bin/env wolframscript

(* Run the Paclet Repository definition-notebook checks or build locally.
   Submission is deliberately out of scope for this script. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];
definition = FileNameJoin[{
  root,
  "Gravifer__Einstoff",
  "ResourceDefinition.nb"
}];
buildDir = FileNameJoin[{root, "build"}];
arguments = Rest[$ScriptCommandLine];
command = ToLowerCase[First[arguments, "check"]];

loadResult = Quiet @ Check[Needs["Wolfram`PacletCICD`"], $Failed];
If[loadResult === $Failed,
  Print[
    "Wolfram/PacletCICD is not installed. Install it with ",
    "PacletInstall[\"Wolfram/PacletCICD\"]."
  ];
  Exit[1]
];

If[! FileExistsQ[definition],
  Print["Definition notebook not found: ", definition];
  Exit[1]
];

result = Switch[
  command,
  "check",
    Wolfram`PacletCICD`CheckPaclet[
      File[definition],
      None,
      "Target" -> "Build",
      "FailureCondition" -> "Error",
      "SetWorkflowValue" -> False
    ],
  "build",
    Wolfram`PacletCICD`BuildPaclet[
      File[definition],
      "Check" -> False,
      "Target" -> "Build",
      "FailureCondition" -> "Error",
      "ExitOnFail" -> False,
      "SetWorkflowValue" -> False
    ],
  _,
    Print["Usage: wolframscript -script scripts/paclet-cicd.wls [check|build]"];
    Exit[2]
];

If[result === $Failed || FailureQ[result],
  Print["PacletCICD ", command, " failed: ", result // InputForm];
  Exit[1]
];

If[command === "build",
  archive = Replace[
    result,
    Success[_, data_Association] :> Lookup[data, "PacletArchive", Missing["NotAvailable"]]
  ];
  archive = Replace[archive, File[path_String] :> path];
  If[! StringQ[archive] || ! FileExistsQ[archive],
    Print["PacletCICD did not return an existing archive: ", result // InputForm];
    Exit[1]
  ];
  If[! DirectoryQ[buildDir], CreateDirectory[buildDir]];
  publishedArchive = FileNameJoin[{buildDir, FileNameTake[archive]}];
  If[ExpandFileName[archive] =!= ExpandFileName[publishedArchive],
    publishedArchive = CopyFile[
      archive,
      publishedArchive,
      OverwriteTarget -> True
    ];
    If[
      publishedArchive === $Failed ||
        ! StringQ[publishedArchive] ||
        ! FileExistsQ[publishedArchive],
      Print["Failed to publish the paclet archive to ", buildDir, "."];
      Exit[1]
    ];
    DeleteFile[archive]
  ];
  Print["PACLET_ARCHIVE=", ExpandFileName[publishedArchive]],
  Print["PacletCICD build-target checks passed."]
];
