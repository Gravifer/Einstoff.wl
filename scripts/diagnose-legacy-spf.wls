#!/usr/bin/env wolframscript

(* A Wolfram 13-safe, throwaway diagnostic for legacy structured-package
   fragment discovery and declaration spelling. It deliberately exercises
   independent contexts so one variant cannot satisfy another variant's load. *)

arguments = Rest[$ScriptCommandLine];
If[Length[arguments] =!= 1,
  Print["usage: diagnose-legacy-spf.wls REPORT"];
  Exit[64]
];
reportPath = First[arguments];

reportDirectory = DirectoryName[reportPath];
If[! DirectoryQ[reportDirectory],
  CreateDirectory[reportDirectory, CreateIntermediateDirectories -> True]
];
fixtureRoot = FileNameJoin[{reportDirectory, "legacy-spf-fixtures"}];
If[DirectoryQ[fixtureRoot], DeleteDirectory[fixtureRoot, DeleteContents -> True]];
CreateDirectory[fixtureRoot];

variants = {
  <|
    "Name" -> "current-nested-wl-symbol",
    "EntryExtension" -> "wl",
    "FragmentExtension" -> "wl",
    "Nested" -> True,
    "QuotedDeclarations" -> False
  |>,
  <|
    "Name" -> "flat-wl-string",
    "EntryExtension" -> "wl",
    "FragmentExtension" -> "wl",
    "Nested" -> False,
    "QuotedDeclarations" -> True
  |>,
  <|
    "Name" -> "flat-m-symbol",
    "EntryExtension" -> "m",
    "FragmentExtension" -> "m",
    "Nested" -> False,
    "QuotedDeclarations" -> False
  |>,
  <|
    "Name" -> "flat-m-string",
    "EntryExtension" -> "m",
    "FragmentExtension" -> "m",
    "Nested" -> False,
    "QuotedDeclarations" -> True
  |>,
  <|
    "Name" -> "nested-m-string",
    "EntryExtension" -> "m",
    "FragmentExtension" -> "m",
    "Nested" -> True,
    "QuotedDeclarations" -> True
  |>,
  <|
    "Name" -> "wl-entry-flat-m-string",
    "EntryExtension" -> "wl",
    "FragmentExtension" -> "m",
    "Nested" -> False,
    "QuotedDeclarations" -> True
  |>,
  <|
    "Name" -> "wl-entry-nested-m-string",
    "EntryExtension" -> "wl",
    "FragmentExtension" -> "m",
    "Nested" -> True,
    "QuotedDeclarations" -> True
  |>
};

writeText[path_, text_] := Export[path, text, "Text"];

runVariant[variant_, index_] := Module[
  {
    name, context, directory, fragmentDirectory, entryPath, publicPath,
    sharedPath, publicName, sharedName, quoted, exportDeclaration,
    scopeDeclaration, getSucceeded,
    publicSymbols, packageSymbols, value
  },
  name = variant["Name"];
  context = "EinstoffSPFDiagnostic" <> ToString[index] <> "`";
  publicName = "PublicValue" <> ToString[index];
  sharedName = "SharedValue" <> ToString[index];
  directory = FileNameJoin[{fixtureRoot, name}];
  CreateDirectory[directory];
  fragmentDirectory = If[
    TrueQ[variant["Nested"]],
    FileNameJoin[{directory, "Fragments"}],
    directory
  ];
  If[! DirectoryQ[fragmentDirectory], CreateDirectory[fragmentDirectory]];

  entryPath = FileNameJoin[{
    directory,
    "Main." <> variant["EntryExtension"]
  }];
  publicPath = FileNameJoin[{
    fragmentDirectory,
    "Public." <> variant["FragmentExtension"]
  }];
  sharedPath = FileNameJoin[{
    fragmentDirectory,
    "Shared." <> variant["FragmentExtension"]
  }];

  quoted = TrueQ[variant["QuotedDeclarations"]];
  exportDeclaration = If[
    quoted,
    "PackageExport[\"" <> publicName <> "\"]",
    "PackageExport[" <> publicName <> "]"
  ];
  scopeDeclaration = If[
    quoted,
    "PackageScope[\"" <> sharedName <> "\"]",
    "PackageScope[" <> sharedName <> "]"
  ];

  writeText[entryPath, "Package[\"" <> context <> "\"]\n"];
  writeText[
    publicPath,
    "Package[\"" <> context <> "\"]\n" <>
      exportDeclaration <> "\n" <>
      publicName <> "[] := " <> sharedName <> "[]\n"
  ];
  writeText[
    sharedPath,
    "Package[\"" <> context <> "\"]\n" <>
      scopeDeclaration <> "\n" <>
      sharedName <> "[] := \"" <> name <> "\"\n"
  ];

  getSucceeded = Quiet @ Check[Get[entryPath]; True, False];
  publicSymbols = Sort @ Names[context <> "*"];
  packageSymbols = Sort @ Names[context <> "PackageScope`*"];
  value = If[
    MemberQ[publicSymbols, publicName],
    Quiet @ Check[ToExpression[context <> publicName <> "[]"], $Failed],
    Missing["NotExported"]
  ];

  <|
    "Name" -> name,
    "Context" -> context,
    "EntryExtension" -> variant["EntryExtension"],
    "FragmentExtension" -> variant["FragmentExtension"],
    "Nested" -> TrueQ[variant["Nested"]],
    "QuotedDeclarations" -> quoted,
    "ExpectedPublicSymbol" -> publicName,
    "GetSucceeded" -> TrueQ[getSucceeded],
    "PublicSymbols" -> publicSymbols,
    "PackageSymbols" -> packageSymbols,
    "PublicValue" -> ToString[value, InputForm]
  |>
];

results = MapIndexed[runVariant[#1, First[#2]] &, variants];
report = <|
  "ActualVersion" -> $Version,
  "ActualVersionNumber" -> $VersionNumber,
  "Variants" -> results
|>;

If[Quiet @ Check[Export[reportPath, report, "JSON"], $Failed] === $Failed,
  Print["Could not write legacy-SPF diagnostic report: ", reportPath];
  Exit[70]
];

Scan[
  Function[result,
    Print[
      result["Name"], ": public=", result["PublicSymbols"],
      ", package=", result["PackageSymbols"],
      ", value=", result["PublicValue"]
    ]
  ],
  results
];
Exit[0];
