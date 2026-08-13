#!/usr/bin/env wolframscript

(* Lightweight release-preparation checks. This validates the source paclet and
   its public surface without building documentation or launching a front end. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];
pacletDir = FileNameJoin[{root, "Gravifer__Einstoff"}];

failures = {};
check[name_String, condition_, detail_] :=
  If[TrueQ[condition],
    Print["[PASS] ", name],
    AppendTo[failures, name];
    Print["[FAIL] ", name, ": ", detail]
  ];

PacletDirectoryLoad[root];
paclets = PacletFind["Gravifer/Einstoff"];

check[
  "publisher paclet discovery",
  Length[paclets] == 1,
  paclets
];

If[Length[paclets] == 1,
  paclet = First[paclets];
  check["version", paclet["Version"] === "0.2.0", paclet["Version"]];
  check["minimum Wolfram version", paclet["WolframVersion"] === "15.0+", paclet["WolframVersion"]];
  check["publisher ID", paclet["PublisherID"] === "Gravifer", paclet["PublisherID"]];
  check["primary context", paclet["PrimaryContext"] === "Gravifer`Einstoff`", paclet["PrimaryContext"]];
  check["license", paclet["License"] === "GPL-3.0-or-later", paclet["License"]];
];

loadResult = Quiet @ Check[Needs["Gravifer`Einstoff`"], $Failed];
check["package load", loadResult =!= $Failed, loadResult];
check["public symbol context", Context[Einstoff] === "Gravifer`Einstoff`", Context[Einstoff]];
check["single public symbol", Names["Gravifer`Einstoff`*"] === {"Einstoff"}, Names["Gravifer`Einstoff`*"]];
check["no legacy context", Names["Einstoff`*"] === {}, Names["Einstoff`*"]];

docs = {
  FileNameJoin[{pacletDir, "Documentation", "English", "ReferencePages", "Symbols", "Einstoff.nb"}],
  FileNameJoin[{pacletDir, "Documentation", "English", "Guides", "Einstoff.nb"}]
};

Scan[
  Function[file,
    nb = Quiet @ Check[Get[file], $Failed];
    check["documentation expression: " <> FileNameTake[file], MatchQ[nb, _Notebook], file];
    check["documentation has no placeholders: " <> FileNameTake[file], FreeQ[nb, "XXXX", Infinity], file]
  ],
  docs
];

If[failures === {},
  Print["All source paclet checks passed."];
  Exit[0],
  Print[Length[failures], " source paclet check(s) failed."];
  Exit[1]
];
