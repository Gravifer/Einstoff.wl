PacletDirectoryLoad[Directory[]];
Needs["Einstoff`"];

Print["shapes reduce-like"];
Print[InputForm[EinstoffShapes[{{a_, Highlighted[___], c_}} :> {{a, c}}, {{2, 3, 4, 5}}]]];

Print["shapes map-like"];
Print[InputForm[EinstoffShapes[{{a_, Highlighted[___], c_}} :> {{a, Highlighted[___], c}}, {{2, 3, 4, 5}}]]];

Print["map current"];
Print[InputForm[
  Quiet @ Einstoff[Map][Reverse][
    {{a_, Highlighted[___], c_}} :> {{a, Highlighted[___], c}},
    {ArrayReshape[Range[120], {2, 3, 4, 5}]}]]];
