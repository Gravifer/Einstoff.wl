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
expectedTag = If[Length[arguments] >= 2, arguments[[2]], ""];
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

ClearAll[failPublication];
failPublication[message_String] := (
  Print["Paclet Repository publication refused: ", message];
  Exit[1]
);

ClearAll[stableVersionParts, versionAtLeastQ];
stableVersionParts[version_String] :=
  If[
    StringMatchQ[version, RegularExpression["^[0-9]+\\.[0-9]+\\.[0-9]+$"]],
    FromDigits /@ StringSplit[version, "."],
    $Failed
  ];
versionAtLeastQ[current_String, candidate_String] := Module[
  {currentParts = stableVersionParts[current], candidateParts = stableVersionParts[candidate]},
  Which[
    currentParts === $Failed || candidateParts === $Failed, $Failed,
    currentParts[[1]] != candidateParts[[1]], currentParts[[1]] > candidateParts[[1]],
    currentParts[[2]] != candidateParts[[2]], currentParts[[2]] > candidateParts[[2]],
    True, currentParts[[3]] >= candidateParts[[3]]
  ]
];

ClearAll[submitStablePaclet];
submitStablePaclet[tag_String] := Module[
  {
    version, pacletInfoPath, pacletInfo, sourceVersion, tokenString,
    remotePaclets, remoteVersions, versionComparisons,
    sourceCommit, archiveDigest, definitionDigest,
    submission, submissionData, submissionName, record
  },
  If[Environment["EINSTOFF_RELEASE_PUBLISH"] =!= "true",
    failPublication["EINSTOFF_RELEASE_PUBLISH is not true"]
  ];
  If[! StringMatchQ[tag, RegularExpression["^v[0-9]+\\.[0-9]+\\.[0-9]+$"]],
    failPublication["expected tag must be a stable vX.Y.Z version"]
  ];
  version = StringDrop[tag, 1];

  pacletInfoPath = FileNameJoin[{root, "Gravifer__Einstoff", "PacletInfo.wl"}];
  pacletInfo = Quiet @ Check[Get[pacletInfoPath], $Failed];
  sourceVersion = Quiet @ Check[pacletInfo["Version"], $Failed];
  If[! StringQ[sourceVersion] || sourceVersion =!= version,
    failPublication["expected tag does not match PacletInfo.wl"]
  ];

  sourceCommit = Quiet @ Check[Environment["EINSTOFF_RELEASE_SOURCE_SHA"], ""];
  If[! StringQ[sourceCommit], sourceCommit = ""];
  archiveDigest = Quiet @ Check[
    Environment["EINSTOFF_RELEASE_ARCHIVE_SHA256"],
    ""
  ];
  If[! StringQ[archiveDigest], archiveDigest = ""];
  archiveDigest = ToLowerCase[archiveDigest];
  If[! StringMatchQ[sourceCommit, RegularExpression["^[0-9a-fA-F]{40}$"]],
    failPublication["release source commit is missing or malformed"]
  ];
  If[! StringMatchQ[archiveDigest, RegularExpression["^[0-9a-f]{64}$"]],
    failPublication["GitHub archive SHA-256 is missing or malformed"]
  ];

  tokenString = Quiet @ Check[Environment["RESOURCE_PUBLISHER_TOKEN"], ""];
  If[! StringQ[tokenString] || tokenString === "",
    failPublication["RESOURCE_PUBLISHER_TOKEN is not configured"]
  ];

  remotePaclets = Quiet @ Check[PacletFindRemote["Gravifer/Einstoff"], $Failed];
  If[remotePaclets === $Failed || ! ListQ[remotePaclets],
    failPublication["current public paclet version could not be determined"]
  ];
  remoteVersions = DeleteCases[
    Quiet @ Check[#1["Version"], Nothing] & /@ remotePaclets,
    Except[_String]
  ];
  versionComparisons = versionAtLeastQ[#1, version] & /@ remoteVersions;
  If[MemberQ[versionComparisons, $Failed],
    failPublication["a public paclet version is not a supported X.Y.Z version"]
  ];
  If[MemberQ[versionComparisons, True],
    failPublication["an equal or newer stable paclet version is already public"]
  ];

  definitionDigest = ToLowerCase @ IntegerString[
    FileHash[definition, "SHA256"],
    16,
    64
  ];
  submission = Quiet @ Check[
    Wolfram`PacletCICD`SubmitPaclet[
      File[definition],
      PublisherID -> "Gravifer",
      PublisherToken -> tokenString,
      "ExitOnFail" -> False,
      "SetWorkflowValue" -> False
    ],
    $Failed
  ];
  If[submission === $Failed || FailureQ[submission] || Head[submission] =!= Success,
    failPublication[
      "SubmitPaclet did not acknowledge success; inspect the public resource before retrying"
    ]
  ];

  submissionData = Quiet @ Check[submission[[2]], <||>];
  submissionName = If[
    AssociationQ[submissionData],
    Lookup[submissionData, "Name", "Gravifer/Einstoff"],
    "Gravifer/Einstoff"
  ];
  If[submissionName =!= "Gravifer/Einstoff",
    failPublication["submission acknowledgement named an unexpected resource"]
  ];
  record = <|
    "Name" -> submissionName,
    "Version" -> version,
    "Status" -> "Submitted",
    "Timestamp" -> DateString[Now, "ISODateTime"],
    "SourceCommit" -> ToLowerCase[sourceCommit],
    "DefinitionNotebookSHA256" -> definitionDigest,
    "GitHubArchiveSHA256" -> archiveDigest
  |>;
  Print[
    "PACLET_SUBMISSION_RECORD=",
    ExportString[record, "RawJSON", "Compact" -> True]
  ];
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
    "submit",
      submitStablePaclet[expectedTag],
    _,
      Print[
        "Usage: wolframscript -script scripts/paclet-cicd.wls ",
        "[check|submission-check|build|ci|submit] [expected-tag]"
      ];
      Exit[2]
  ]
];

If[command === "submit", Exit[0]];

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
