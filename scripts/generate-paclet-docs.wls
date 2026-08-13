#!/usr/bin/env wolframscript

(* Generate the native authoring notebooks for the public Einstoff paclet API.
   The source is deliberately deterministic so notebook updates remain reviewable
   by regenerating and comparing hashes, without using DocumentationTools dialogs. *)

scriptDir = DirectoryName[$InputFileName];
If[scriptDir === "", scriptDir = Directory[]];
root = ParentDirectory[scriptDir];
pacletDir = FileNameJoin[{root, "Gravifer__Einstoff"}];
symbolDir = FileNameJoin[{pacletDir, "Documentation", "English", "ReferencePages", "Symbols"}];
guideDir = FileNameJoin[{pacletDir, "Documentation", "English", "Guides"}];

Scan[
  If[! DirectoryQ[#], CreateDirectory[#, CreateIntermediateDirectories -> True]] &,
  {symbolDir, guideDir}
];

$cellID = 200000;
nextCellID[] := ++$cellID;
cell[content_, style_String, opts___Rule] :=
  Cell[content, style, opts, CellID -> nextCellID[]];
group[cells_List, state_: Open] := Cell[CellGroupData[cells, state]];

SetAttributes[heldBoxes, HoldAllComplete];
heldBoxes[expr_] := ToBoxes[Defer[expr], StandardForm];

usageLine[boxes_, description_String] := {
  Cell["   ", "ModInfo"],
  Cell[BoxData[boxes], "InlineFormula"],
  " \[LineSeparator]" <> description,
  "\n"
};

usageCell[lines_List] :=
  cell[TextData[Delete[Flatten[lines, 1], -1]], "Usage"];

SetAttributes[inputCell, HoldAllComplete];
inputCell[expr_] := cell[BoxData[heldBoxes[expr]], "Input"];

SetAttributes[outputCell, HoldAllComplete];
outputCell[expr_] := cell[BoxData[heldBoxes[expr]], "Output"];

docButton[label_String, uri_String] :=
  ButtonBox[label, BaseStyle -> "Link", ButtonData -> "paclet:" <> uri];

$systemLinkNames = {
  "Annotation", "ArrayReduce", "ArrayReshape", "Automatic", "Defer", "Dot",
  "False", "Framed", "Highlighted", "Hold", "Inner", "Join", "Labeled", "Map",
  "None", "Operate", "Rule", "RuleDelayed", "Slot", "Split", "TraceAction", "True"
};
$systemDocLinks =
  AssociationThread[$systemLinkNames, "ref/" <> # & /@ $systemLinkNames];
$guideDocLinks =
  Join[<|"Einstoff" -> "Gravifer/Einstoff/ref/Einstoff"|>, $systemDocLinks];

linkSymbolBoxes[boxes_, links_Association] :=
  boxes /. name_String /; KeyExistsQ[links, name] :>
    docButton[name, links[name]];

SetAttributes[systemLinkedHeldBoxes, HoldAllComplete];
systemLinkedHeldBoxes[expr_] := linkSymbolBoxes[heldBoxes[expr], $systemDocLinks];

SetAttributes[guideLinkedHeldBoxes, HoldAllComplete];
guideLinkedHeldBoxes[expr_] := linkSymbolBoxes[heldBoxes[expr], $guideDocLinks];

systemInlineRef[name_String] :=
  Cell[BoxData[docButton[name, "ref/" <> name]], "InlineFormula"];

systemTableRef[name_String] :=
  Cell[BoxData[docButton[name, "ref/" <> name]], "TableText"];

linkedCell[label_String, uri_String, style_String] :=
  cell[TextData[{Cell[BoxData[docButton[label, uri]], "InlineFormula"]}], style];

guideListing[boxes_, description_String] :=
  cell[
    TextData[{
      Cell[
        BoxData[boxes],
        "InlineGuideFunction"
      ],
      " \[LongDash] " <> description
    }],
    "GuideText"
  ];

guideConcept[boxes_, description_String] :=
  cell[
    TextData[{
      Cell[BoxData[boxes], "InlineFormula"],
      " \[LongDash] " <> description
    }],
    "GuideText"
  ];

metadata[entity_String, context_String, uri_String, keywords_String] := {
  group[{
    cell["Metadata", "MetadataSection"],
    cell[
      TextData[{
        "New in: ", Cell["0.2.0", "HistoryData", CellTags -> "New"],
        " | Modified in: ", Cell[" ", "HistoryData", CellTags -> "Modified"],
        " | Obsolete in: ", Cell[" ", "HistoryData", CellTags -> "Obsolete"]
      }],
      "History"
    ],
    group[{
      cell["Categorization", "CategorizationSection"],
      cell[entity, "Categorization", CellLabel -> "Entity Type"],
      cell["Gravifer/Einstoff", "Categorization", CellLabel -> "Paclet Name"],
      cell[context, "Categorization", CellLabel -> "Context"],
      cell[uri, "Categorization", CellLabel -> "URI"]
    }, Closed],
    group[{
      cell["Keywords", "KeywordsSection"],
      cell[keywords, "Keywords"]
    }, Closed]
  }, Open]
};

functionNotebook = Notebook[
  Join[
    {
      group[{
        cell["Einstoff", "ObjectName"],
        usageCell[{
          usageLine[
            systemLinkedHeldBoxes[Einstoff[ArrayReshape][desc, tensors]],
            "performs an element-count-preserving rearrangement of tensors according to desc."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff["Massage"][desc, tensors]],
            "uses the permissive single-tensor structural engine."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff["ArrayContract"][desc, tensors]],
            "performs within-tensor pairwise contraction together with reshaping."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff[ArrayReduce][f][desc, tensors]],
            "reduces selected axes of one tensor using f."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff[Operate][f][desc, tensors]],
            "applies a shape-preserving operation f to targeted blocks."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff[Map][f][desc, tensors]],
            "maps a possibly shape-changing operation f over targeted blocks."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff[Dot][desc, tensors]],
            "performs sum-of-products contraction over two or more tensors."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff[Inner][mul, add][desc, tensors]],
            "performs generalized contraction using mul and add."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff[Join][desc, tensors]],
            "concatenates structural direct sums."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff[Split][desc, tensors]],
            "splits structural direct sums."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff["einsum"][desc, tensors]],
            "dispatches the implemented einsum-style contraction subset."
          ],
          usageLine[
            systemLinkedHeldBoxes[Einstoff[op][desc, tensors, bindings]],
            "uses explicit axis-size bindings in addition to sizes inferred from desc."
          ]
        }],
        cell[
          TextData[{
            "The canonical description is a ", systemInlineRef["RuleDelayed"],
            " of the form {in1, in2, ...} :> {out1, out2, ...}. ",
            systemInlineRef["Rule"],
            " is warned best-effort compatibility because its right-hand side may evaluate before capture."
          }],
          "Notes"
        ],
        cell[
          "Axis terms include named blanks, bare or string names, literal and unit axes, products, direct sums, named or anonymous sequences, and repeated groups.",
          "Notes"
        ],
        cell[
          "The whole left-hand side is one binder scope: repeated a_ occurrences denote the same logical axis, while a bare a on the left remains an ambient expression. A bare a is localized only on the right from the completed binder environment or an explicit sized declaration.",
          "Notes"
        ],
        cell[
          TextData[{
            systemInlineRef["Annotation"], "[axis, n] and ",
            systemInlineRef["Labeled"], "[n, axis] add an inline positive-integer size. ",
            "They compose in either nesting order with valid ", systemInlineRef["Slot"], ", ",
            systemInlineRef["Highlighted"], ", and ", systemInlineRef["Framed"],
            " targeting wrappers."
          }],
          "Notes"
        ],
        cell[
          TextData[{
            "Targeted string axes use ", systemInlineRef["Slot"], "[\"name\"], ",
            systemInlineRef["Highlighted"], "[\"name\"], or ", systemInlineRef["Framed"],
            "[\"name\"]. Targeted symbol axes use ", systemInlineRef["Highlighted"],
            " or ", systemInlineRef["Framed"], "."
          }],
          "Notes"
        ],
        cell[
          BoxData @ GridBox[{
            {
              Cell["      ", "TableRowIcon"],
              systemTableRef["TraceAction"],
              systemTableRef["None"],
              Cell[TextData[{
                "Use ", systemInlineRef["Hold"], " or ", systemInlineRef["Defer"],
                " to inspect the lowered Wolfram expression."
              }], "TableText"]
            },
            {
              Cell["      ", "TableRowIcon"],
              "\"Targeting\"",
              systemTableRef["Automatic"],
              Cell[TextData[{
                "Use ", systemInlineRef["False"], ", ", systemInlineRef["Automatic"],
                ", or ", systemInlineRef["True"],
                " to control inference and validation of explicitly targeted axes."
              }], "TableText"]
            }
          }],
          "3ColumnTableMod",
          GridBoxOptions -> {
            GridBoxBackground -> {"Columns" -> {{None}}, "Rows" -> {None, {None}}},
            GridBoxDividers -> {"Rows" -> {{True, True, True}}}
          }
        ]
      }, Open],

      group[{
        cell["See Also", "SeeAlsoSection"],
        cell[
          TextData @ Riffle[
            (Cell[BoxData[docButton[#, "ref/" <> #]], "InlineFormula"] & /@
              {"ArrayReshape", "ArrayReduce", "Map", "Operate", "Dot", "Inner", "Join", "Split"}),
            " \[FilledVerySmallSquare] "
          ],
          "SeeAlso"
        ]
      }, Open],

      group[{
        cell["Related Guides", "MoreAboutSection"],
        linkedCell["Einstoff", "Gravifer/Einstoff/guide/Einstoff", "MoreAbout"]
      }, Open],

      group[{
        cell["Examples Initialization", "ExamplesInitializationSection"],
        inputCell[Needs["Gravifer`Einstoff`"]]
      }, Open],

      cell["Basic Examples", "PrimaryExamplesSection"],
      cell["Permute the dimensions of a rank-three array:", "ExampleText"],
      inputCell[x = ArrayReshape[Range[24], {2, 3, 4}]],
      inputCell[Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {x}]],
      outputCell[ArrayReshape[Range[24], {4, 2, 3}]],

      cell["", "ExampleDelimiter"],
      cell["Reduce a targeted axis:", "ExampleText"],
      inputCell[
        Einstoff[ArrayReduce][Total][
          {{a_, Slot["b"]}} :> {{a}},
          {ArrayReshape[Range[12], {3, 4}]}
        ]
      ],
      outputCell[{10, 26, 42}],

      cell["", "ExampleDelimiter"],
      cell["Contract two tensors over a shared axis:", "ExampleText"],
      inputCell[
        Einstoff[Dot][
          {{a_, b_}, {b_, c_}} :> {{a, c}},
          {
            ArrayReshape[Range[6], {2, 3}],
            ArrayReshape[Range[12], {3, 4}]
          }
        ]
      ],
      outputCell[{{38, 44, 50, 56}, {83, 98, 113, 128}}],

      group[{
        cell["Scope", "ExtendedExamplesSection", CellTags -> "ExtendedExamples"],
        cell["Split a product axis using an explicit hygienic string binding:", "ExampleText"],
        inputCell[
          Einstoff[ArrayReshape][
            {{CircleTimes["a", b_]}} :> {{"a", b}},
            {Range[6]},
            {"a" -> 2}
          ]
        ],
        outputCell[{{1, 2, 3}, {4, 5, 6}}]
      }, Open]
    },
    metadata[
      "Symbol",
      "Gravifer`Einstoff`",
      "Gravifer/Einstoff/ref/Einstoff",
      "tensor, array, reshape, reduction, contraction, direct sum, named axes"
    ]
  ],
  TaggingRules -> <|"Paclet" -> "Gravifer/Einstoff"|>,
  CellContext -> "Global`",
  StyleDefinitions -> FrontEnd`FileName[
    {"Wolfram"}, "FunctionPageStylesExt.nb", CharacterEncoding -> "UTF-8"]
];

$cellID = 300000;

guideNotebook = Notebook[
  Join[
    {
      group[{
        cell["Einstoff", "GuideTitle"],
        cell[
          "Einstoff is one public symbol with several operator forms. Choose an operator below, then describe input and output axes using Wolfram-native pattern and wrapper syntax. The description is compiled to a private staged representation before tensor execution.",
          "GuideAbstract"
        ]
      }, Open],

      group[{
        cell["Structural transformations", "GuideFunctionsSection"],
        guideListing[guideLinkedHeldBoxes[Einstoff[ArrayReshape]], "perform element-count-preserving rearrangement and reshape"],
        guideListing[guideLinkedHeldBoxes[Einstoff["Massage"]], "use the permissive single-tensor structural engine"],
        guideListing[guideLinkedHeldBoxes[Einstoff["ArrayContract"]], "reshape and perform within-tensor pairwise contraction without repetition"],
        guideListing[guideLinkedHeldBoxes[Einstoff[Join]], "concatenate structural direct sums"],
        guideListing[guideLinkedHeldBoxes[Einstoff[Split]], "split structural direct sums"]
      }, Open],

      group[{
        cell["Reduction and mapped operations", "GuideFunctionsSection"],
        guideListing[guideLinkedHeldBoxes[Einstoff[ArrayReduce][f]], "reduce selected axes using f"],
        guideListing[guideLinkedHeldBoxes[Einstoff[Operate][f]], "apply a shape-preserving operation to targeted blocks"],
        guideListing[guideLinkedHeldBoxes[Einstoff[Map][f]], "map a possibly shape-changing function over targeted blocks"]
      }, Open],

      group[{
        cell["Contractions", "GuideFunctionsSection"],
        guideListing[guideLinkedHeldBoxes[Einstoff[Dot]], "perform sum-of-products contraction over two or more tensors"],
        guideListing[guideLinkedHeldBoxes[Einstoff[Inner][mul, add]], "contract using custom multiplication and addition"],
        guideListing[guideLinkedHeldBoxes[Einstoff["einsum"]], "dispatch the implemented einsum-style contraction subset"]
      }, Open],

      group[{
        cell["Shape descriptions", "GuideFunctionsSection"],
        guideConcept["a_   a   \"a\"", "infer a named axis, refer to an established symbol axis, or use a hygienic string axis"],
        guideConcept["__   ___", "infer one-or-more or zero-or-more anonymous axes"],
        guideConcept["a \[CircleTimes] b   a \[CirclePlus] b", "compose a product axis or structural direct sum"],
        guideConcept[
          RowBox[{
            docButton["Slot", "ref/Slot"], "[", "\"a\"", "]", "\[ThickSpace]",
            docButton["Highlighted", "ref/Highlighted"], "[", "a", "]", "\[ThickSpace]",
            docButton["Framed", "ref/Framed"], "[", "a", "]"
          }],
          "mark an occurrence as targeted"
        ],
        guideConcept[
          RowBox[{
            docButton["Annotation", "ref/Annotation"], "[", RowBox[{"a", ",", "n"}], "]",
            "\[ThickSpace]", docButton["Labeled", "ref/Labeled"], "[",
            RowBox[{"n", ",", "a"}], "]"
          }],
          "declare an inline positive-integer axis size"
        ]
      }, Open],

      group[{
        cell["Related Guides", "GuideMoreAboutSection"],
        linkedCell["Tensors", "guide/Tensors", "GuideMoreAbout"],
        linkedCell["Rearranging & Restructuring Lists", "guide/RearrangingAndRestructuringLists", "GuideMoreAbout"]
      }, Open]
    },
    metadata[
      "Guide",
      "Gravifer`Einstoff`",
      "Gravifer/Einstoff/guide/Einstoff",
      "tensor, array, named axes, einops, einx"
    ]
  ],
  TaggingRules -> <|"Paclet" -> "Gravifer/Einstoff"|>,
  CellContext -> "Global`",
  StyleDefinitions -> FrontEnd`FileName[
    {"Wolfram"}, "GuidePageStylesExt.nb", CharacterEncoding -> "UTF-8"]
];

generatedFiles = {
  FileNameJoin[{symbolDir, "Einstoff.nb"}],
  FileNameJoin[{guideDir, "Einstoff.nb"}]
};

writeNotebook[nb_Notebook, file_String] := Module[{stream},
  stream = OpenWrite[file, PageWidth -> 100, CharacterEncoding -> "ASCII"];
  WriteString[stream,
    "(* Content-type: application/vnd.wolfram.mathematica *)\n\n",
    "(*** Wolfram Notebook File ***)\n",
    "(* http://www.wolfram.com/nb *)\n\n",
    "(* CreatedBy='Wolfram 15.0' *)\n\n",
    "(* Beginning of Notebook Content *)\n"
  ];
  Write[stream, nb];
  WriteString[stream, "\n(* End of Notebook Content *)\n"];
  Close[stream];
];

MapThread[writeNotebook, {{functionNotebook, guideNotebook}, generatedFiles}];

validNotebookQ[file_String] := Module[{nb, ids},
  nb = Quiet @ Check[Get[file], $Failed];
  If[! MatchQ[nb, _Notebook], Return[False]];
  ids = Cases[nb, Cell[___, CellID -> id_Integer, ___] :> id, Infinity];
  FreeQ[nb, "XXXX", Infinity] && DuplicateFreeQ[ids]
];

If[! AllTrue[generatedFiles, validNotebookQ],
  Print["Generated documentation failed structural validation."];
  Exit[1]
];

Scan[Print["Generated ", #] &, generatedFiles];
