(* scratch: debug the Slot-splice path *)
dir = DirectoryName[$InputFileName];
Get[FileNameJoin[{dir, "Einstoff", "Parsing.wl"}]];

Print["=== ex5 full result ==="];
r = Gravifer`Einstoff`Parsing`EinstoffShapes[{{a_, Slot[b_]}} :> {{a}}, {{5, 9}}];
Print[r];

Print["=== EinstoffMatch directly on ex5 lhs ==="];
Print[Gravifer`Einstoff`Parsing`EinstoffMatch[{{a_, Slot[b_]}}, {{5, 9}}]];

Print["=== inspect the parsed lhs / heads ==="];
lhs = {{a_, Slot[b_]}};
Print["lhs = ", lhs //InputForm];
Print["Head of second term = ", Head[lhs[[1, 2]]]];
Print["List @@ second term = ", (List @@ lhs[[1, 2]]) // InputForm];
