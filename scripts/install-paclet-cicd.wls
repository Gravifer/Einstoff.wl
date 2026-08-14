#!/usr/bin/env wolframscript

(* Install the exact PacletCICD archive used by CI after verifying its digest. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
config = Get[FileNameJoin[{scriptDir, "paclet-cicd-config.wl"}]];
arguments = Rest[$ScriptCommandLine];

If[! AssociationQ[config],
  Print["Invalid PacletCICD configuration."];
  Exit[1]
];

temporaryDirectory = CreateDirectory[
  FileNameJoin[{$TemporaryDirectory, "einstoff-paclet-cicd-" <> CreateUUID[]}]
];
archive = FileNameJoin[{temporaryDirectory, config["FileName"]}];
localArchive = First[arguments, Automatic];
download = If[StringQ[localArchive],
  Quiet @ Check[CopyFile[localArchive, archive], $Failed],
  Quiet @ Check[URLDownload[config["URL"], archive], $Failed]
];
If[! FileExistsQ[archive], download = $Failed];
If[
  download === $Failed && ! StringQ[localArchive] &&
    StringQ[FindExecutable["gh"]],
  githubDownload = RunProcess[{
    FindExecutable["gh"],
    "release", "download", config["Tag"],
    "--repo", config["Repository"],
    "--pattern", config["FileName"],
    "--dir", temporaryDirectory,
    "--clobber"
  }];
  If[githubDownload["ExitCode"] === 0 && FileExistsQ[archive], download = archive]
];
If[download === $Failed || ! FileExistsQ[archive],
  Print[
    "Failed to obtain ", config["URL"],
    ". You may download it separately and pass its path as the first argument."
  ];
  DeleteDirectory[temporaryDirectory, DeleteContents -> True];
  Exit[1]
];

actualSHA256 = ToUpperCase @ IntegerString[FileHash[archive, "SHA256"], 16, 64];
If[actualSHA256 =!= config["SHA256"],
  Print[
    "PacletCICD archive digest mismatch. Expected ", config["SHA256"],
    ", got ", actualSHA256, "."
  ];
  DeleteDirectory[temporaryDirectory, DeleteContents -> True];
  Exit[1]
];

(* ForceVersionInstall permits downgrades but does not guarantee replacing an
   already installed identical version. Remove exact-version copies only after
   the replacement archive has passed checksum verification. *)
repositoryDirectory = FileNameJoin[{
  $UserBaseDirectory,
  "Paclets",
  "Repository",
  StringReplace[config["Name"], "/" -> "__"] <> "-" <> config["Version"]
}];
If[DirectoryQ[repositoryDirectory], PacletDirectoryLoad[repositoryDirectory]];
installedExact = Select[
  PacletFind[config["Name"]],
  Quiet @ Check[#["Version"] === config["Version"], False] &
];
uninstalled = And @@ (
  Quiet @ Check[PacletUninstall[#]; True, False] & /@ installedExact
);
If[! TrueQ[uninstalled],
  Print[
    "Could not replace the existing ", config["Name"], " ",
    config["Version"], " installation."
  ];
  DeleteDirectory[temporaryDirectory, DeleteContents -> True];
  Exit[1]
];

installation = Quiet @ Check[
  PacletInstall[archive, ForceVersionInstall -> True],
  $Failed
];
If[
  ! PacletObjectQ[installation] ||
    Quiet @ Check[installation["Version"] =!= config["Version"], True],
  Print["Failed to install ", config["Name"], " ", config["Version"], "."];
  DeleteDirectory[temporaryDirectory, DeleteContents -> True];
  Exit[1]
];
DeleteDirectory[temporaryDirectory, DeleteContents -> True];

Print[
  "Installed verified ", config["Name"], " ", config["Version"], "."
];
