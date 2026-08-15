#!/usr/bin/env wolframscript

(* Run the Paclet Repository definition-notebook checks or build locally.
   The submission-check command applies repository submission validation but
   never authenticates or submits anything. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
configuredRoot = Quiet @ Check[Environment["EINSTOFF_SOURCE_ROOT"], ""];
root = If[StringQ[configuredRoot] && configuredRoot =!= "",
  ExpandFileName[configuredRoot],
  ParentDirectory[scriptDir]
];
definition = FileNameJoin[{
  root,
  "Gravifer__Einstoff",
  "ResourceDefinition.nb"
}];
buildDir = FileNameJoin[{root, "build"}];
arguments = Rest[$ScriptCommandLine];
command = ToLowerCase[First[arguments, "check"]];
config = Get[FileNameJoin[{scriptDir, "paclet-cicd-config.wl"}]];

repositoryDirectory = FileNameJoin[{
  $UserBaseDirectory,
  "Paclets",
  "Repository",
  StringReplace[config["Name"], "/" -> "__"] <> "-" <> config["Version"]
}];
If[DirectoryQ[repositoryDirectory], PacletDirectoryLoad[repositoryDirectory]];
pacletCICD = SelectFirst[
  PacletFind[config["Name"]],
  Quiet @ Check[#["Version"] === config["Version"], False] &,
  Missing["NotInstalled"]
];
If[MissingQ[pacletCICD],
  Print[
    config["Name"], " ", config["Version"],
    " is required. Run scripts/install-paclet-cicd.wls first."
  ];
  Exit[1]
];
PacletDirectoryLoad[pacletCICD["Location"]];
loadResult = Quiet @ Check[Needs["Wolfram`PacletCICD`"], $Failed];
loadedFile = Quiet @ Check[FindFile["Wolfram`PacletCICD`"], $Failed];
If[
  loadResult === $Failed ||
    ! StringQ[loadedFile] ||
    ! StringStartsQ[
      ExpandFileName[loadedFile],
      ExpandFileName[pacletCICD["Location"]]
    ],
  Print[
    "Could not load the pinned ", config["Name"], " ", config["Version"],
    " installation."
  ];
  Exit[1]
];

If[! FileExistsQ[definition],
  Print["Definition notebook not found: ", definition];
  Exit[1]
];

(* PacletCICD 0.36.2 drops CheckPaclet's SetWorkflowValue option before its
   internal call. A workflow scope of None keeps that bug from writing to the
   user's ApplicationData directory, including in read-only containers. *)
result = Block[{Wolfram`PacletCICD`$WorkflowValueScope = None},
  Switch[
    command,
    "check",
      Wolfram`PacletCICD`CheckPaclet[
        File[definition],
        None,
        "Target" -> "Build",
        "FailureCondition" -> "Error"
      ],
    "submission-check",
      Wolfram`PacletCICD`CheckPaclet[
        File[definition],
        "Dataset",
        "Target" -> "Submit",
        "FailureCondition" -> "Error"
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
    "ci",
      Wolfram`PacletCICD`BuildPaclet[
        File[definition],
        "Check" -> True,
        "Target" -> "Build",
        "FailureCondition" -> "Error",
        "ExitOnFail" -> False,
        "SetWorkflowValue" -> False
      ],
    _,
      Print[
        "Usage: wolframscript -script scripts/paclet-cicd.wls ",
        "[check|submission-check|build|ci]"
      ];
      Exit[2]
  ]
];

If[result === $Failed || FailureQ[result],
  Print["PacletCICD ", command, " failed: ", result // InputForm];
  Exit[1]
];

If[MemberQ[{"build", "ci"}, command],
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
  Print[
    "PacletCICD ",
    If[command === "submission-check", "submission-target", "build-target"],
    " checks passed."
  ]
];
