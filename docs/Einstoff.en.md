---
title: "Einstoff"
language: "en"
type: "Symbol"
summary: "Einstoff[op] gives a shape-description interface for array rearrangement, reduction, mapping, contraction and direct-sum operations. Einstoff[op][desc, tensors, bindings] applies the operation op to tensors using axis sizes inferred from desc and any explicit bindings."
keywords:
- array
- tensor
- reshape
- rearrange
- reduction
- contraction
- direct sum
- named axes
source: "Einstoff Documentation"
related_guides:
  -
    title: "Rearranging & Restructuring Lists"
    link: "https://reference.wolfram.com/language/guide/RearrangingAndRestructuringLists.en.md"
  -
    title: "Tensors"
    link: "https://reference.wolfram.com/language/guide/Tensors.en.md"
  -
    title: "Matrix Operations"
    link: "https://reference.wolfram.com/language/guide/MatrixOperations.en.md"
related_functions:
  -
    title: "ArrayReshape"
    link: "https://reference.wolfram.com/language/ref/ArrayReshape.en.md"
  -
    title: "Transpose"
    link: "https://reference.wolfram.com/language/ref/Transpose.en.md"
  -
    title: "ArrayReduce"
    link: "https://reference.wolfram.com/language/ref/ArrayReduce.en.md"
  -
    title: "Tr"
    link: "https://reference.wolfram.com/language/ref/Tr.en.md"
---

# Einstoff

`Einstoff[ArrayReshape][desc, tensors]` performs an element-count-preserving rearrangement of the tensors according to the shape description `desc`.

`Einstoff["Massage"][desc, tensors]` uses the permissive single-tensor structural engine.

`Einstoff["ArrayContract"][desc, tensors]` performs within-tensor pairwise contractions together with reshaping.

`Einstoff[ArrayReduce][f][desc, tensors]` reduces axes of a single tensor using `f`.

`Einstoff[Map][f][desc, tensors]` maps a shape-preserving operation `f` over targeted axes of a single tensor.

`Einstoff[Dot][desc, tensors]` performs a sum-of-products contraction over two or more tensors.

`Einstoff[Inner][mul, add][desc, tensors]` performs a generalized contraction using `mul` and `add`.

`Einstoff[Join][desc, tensors]` concatenates structural direct sums.

`Einstoff[Split][desc, tensors]` splits structural direct sums.

`Einstoff[op][desc, tensors, bindings]` uses the axis-size bindings in `bindings`.

## Details and Options

- `desc` is normally a `RuleDelayed` expression of the form `{in1, in2, ...} :> {out1, out2, ...}`.
- Each input or output shape is a list of dimension terms.
- `tensors` is a list of tensors.
- `bindings` is a list of rules such as `{"channels" -> 3}` or `{c -> 3}`.
- The public operators do not hold `desc`.
- `TraceAction -> Hold` and `TraceAction -> Defer` return the lowered Wolfram expression in held or deferred form.

Dimension terms include:

| Term | Meaning |
| --- | --- |
| `a_` | infer a named axis size |
| `a` | refer to an established axis or to a bound symbol value |
| `"a"` | hygienic string-named axis |
| `__` | infer a sequence of one or more axes sizes |
| `___` | infer a sequence of zero or more axes sizes |
| `2` | literal size |
| `{}` or `1` | unit axis |
| `a ⊗ b` | product axis |
| `a ⊕ b` | direct-sum axis |
| `#a`(`Slot["a"]`), `Highlighted["a"]`, `Framed["a"]` | targeted string axis |
| `Highlighted[a_]`, `Framed[a_]` | targeted blank axis |
| `Highlighted[a]`, `Framed[a]` | targeted bare axis |
| `#2`(`Slot[2]`), `Highlighted[2]`, `Framed[2]` | targeted literal axis |
| `##` | targeted anonymous axis sequence |

The following options can be given:

| Option | Default | Description |
| --- | --- | --- |
| `TraceAction` | `None` | Use `Hold` or `Defer` to inspect the lowered Wolfram expression. |

## Examples

### Basic Examples

Permute axes:

```wl
In[1]:= x = ArrayReshape[Range[24], {2, 3, 4}];
Einstoff[ArrayReshape][{{a_, b_, c_}} :> {{c, a, b}}, {x}]

Out[1]= {{{1, 5, 9}, {13, 17, 21}}, {{2, 6, 10}, {14, 18, 22}}, {{3, 7, 11}, {15, 19, 23}}, {{4, 8, 12}, {16, 20, 24}}}
```

Merge axes:

```wl
In[1]:= m = ArrayReshape[Range[6], {2, 3}];
Einstoff[ArrayReshape][{{a_, b_}} :> {{a ⊗ b}}, {m}]

Out[1]= {1, 2, 3, 4, 5, 6}
```

Reduce an axis:

```wl
In[1]:= x = ArrayReshape[Range[12], {3, 4}];
Einstoff[ArrayReduce][Total][{{a_, Slot["b"]}} :> {{a}}, {x}]

Out[1]= {10, 26, 42}
```

Contract two tensors:

```wl
In[1]:= x = ArrayReshape[Range[6], {2, 3}];
y = ArrayReshape[Range[12], {3, 4}];
Einstoff[Dot][{{a_, b_}, {b_, c_}} :> {{a, c}}, {x, y}]

Out[1]= {{38, 44, 50, 56}, {83, 98, 113, 128}}
```

### Scope

Split a composed axis with an explicit binding:

```wl
In[1]:= Einstoff[ArrayReshape][{{"a" ⊗ b_}} :> {{"a", b}}, {Range[6]}, {"a" -> 2}]

Out[1]= {{1, 2, 3}, {4, 5, 6}}
```

Broadcast an output-only axis:

```wl
In[1]:= Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}]

Out[1]= {{1, 1, 1}, {2, 2, 2}, {3, 3, 3}, {4, 4, 4}}
```

Use strings for hygienic names:

```wl
In[1]:= Einstoff[ArrayReshape][{{"row", "col"}} :> {{"col", "row"}}, {ArrayReshape[Range[6], {2, 3}]}]

Out[1]= {{1, 4}, {2, 5}, {3, 6}}
```

Use a targeted literal:

```wl
In[1]:= y = ArrayReshape[Range[6], {3, 2}];
Einstoff[ArrayReduce][Total][{{a_, Highlighted[2]}} :> {{a}}, {y}]

Out[1]= {3, 7, 11}
```

### Generalizations & Extensions

Use named reducers:

```wl
In[1]:= Einstoff[ArrayReduce]["max"][{{a_, b_}} :> {{a}}, {ArrayReshape[Range[12], {3, 4}]}]

Out[1]= {4, 8, 12}
```

Apply a shape-preserving operation to targeted blocks:

```wl
In[1]:= x = ArrayReshape[Range[8], {2, 4}];
Einstoff[Map]["flip"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {x}]

Out[1]= {{4, 3, 2, 1}, {8, 7, 6, 5}}
```

Use a Wolfram function as the map operation:

```wl
In[1]:= Einstoff[Map][Reverse][{{a_, Highlighted[b_]}} :> {{a, Highlighted[b]}}, {ArrayReshape[Range[6], {2, 3}]}]

Out[1]= {{3, 2, 1}, {6, 5, 4}}
```

Generalize a tensor contraction:

```wl
In[1]:= Einstoff[Inner][Plus, Min][{{a_}, {b_}} :> {{a, b}}, {Range[2], Range[3]}]

Out[1]= {{2, 3, 4}, {3, 4, 5}}
```

Use a within-tensor pairwise contraction:

```wl
In[1]:= t = ArrayReshape[Range[16], {2, 2, 2, 2}];
Einstoff["ArrayContract"][{{a_, b_, a_, d_}} :> {{b, d}}, {t}]

Out[1]= {{12, 14}, {20, 22}}
```

Concatenate along a direct-sum axis:

```wl
In[1]:= x = ArrayReshape[Range[6], {2, 3}];
y = ArrayReshape[Range[8], {2, 4}];
Einstoff[Join][{{m_, a_}, {m_, b_}} :> {{m, a ⊕ b}}, {x, y}]

Out[1]= {{1, 2, 3, 1, 2, 3, 4}, {4, 5, 6, 5, 6, 7, 8}}
```

Split a direct-sum axis:

```wl
In[1]:= x = ArrayReshape[Range[20], {2, 10}];
Einstoff[Split][{{b_, "q" ⊕ k_}} :> {{b, "q"}, {b, k}}, {x}, {"q" -> 3}]

Out[1]= {{{1, 2, 3}, {11, 12, 13}}, {{4, 5, 6, 7, 8, 9, 10}, {14, 15, 16, 17, 18, 19, 20}}}
```

### Applications

Space-to-depth-style rearrangement:

```wl
In[1]:= x = ArrayReshape[Range[2*4*6], {2, 4, 6}];
Einstoff[ArrayReshape][
  {{b_, h_ ⊗ "h1", w_ ⊗ "w1"}} :>
    {{b, h, w, "h1" ⊗ "w1"}},
  {x}, {"h1" -> 2, "w1" -> 3}]

Out[1]= {{{{1, 2, 3, 7, 8, 9}, {4, 5, 6, 10, 11, 12}}, {{13, 14, 15, 19, 20, 21}, {16, 17, 18, 22, 23, 24}}}, {{{25, 26, 27, 31, 32, 33}, {28, 29, 30, 34, 35, 36}}, {{37, 38, 39, 43, 44, 45}, {40, 41, 42, 46, 47, 48}}}}
```

Global pooling:

```wl
In[1]:= x = ArrayReshape[Range[2*3*4], {2, 3, 4}];
Einstoff[ArrayReduce][Mean][{{batch_, height_, width_}} :> {{batch}}, {x}]

Out[1]= {13/2, 37/2}
```

Batched matrix multiplication:

```wl
In[1]:= x = ArrayReshape[Range[24], {2, 3, 4}];
y = ArrayReshape[Range[40], {2, 4, 5}];
Einstoff[Dot][{{n_, a_, b_}, {n_, b_, c_}} :> {{n, a, c}}, {x, y}]

Out[1]= {{{110, 120, 130, 140, 150}, {246, 272, 298, 324, 350}, {382, 424, 466, 508, 550}}, {{1678, 1736, 1794, 1852, 1910}, {2134, 2208, 2282, 2356, 2430}, {2590, 2680, 2770, 2860, 2950}}}
```

Direct-sum block assembly:

```wl
In[1]:= x11 = {{0, 1}};
x12 = {{10, 11, 12}};
x21 = {{20, 21}, {22, 23}};
x22 = {{30, 31, 32}, {33, 34, 35}};

Einstoff["Massage"][
  {{a_, b_}, {a_, c_}, {d_, b_}, {d_, c_}} :>
    {{a ⊕ d, b ⊕ c}},
  {x11, x12, x21, x22}]

Out[1]= {{0, 1, 10, 11, 12}, {20, 21, 30, 31, 32}, {22, 23, 33, 34, 35}}
```

### Properties & Relations

- `Einstoff[ArrayReshape]` lowers bijective descriptions to combinations of `Transpose`, `ArrayReshape` and unit-axis handling.
- `Einstoff[ArrayReduce][f]` uses `ArrayReduce` after moving the reduced axes into position.
- `Einstoff[Dot]` is the `Times`/`Plus` case of `Einstoff[Inner][mul, add]`.
- `Einstoff[Join]` and `Einstoff[Split]` are structural direct-sum operations over `CirclePlus`.
- `Einstoff["einsum"]` dispatches single-tensor pairwise contractions and multi-tensor cross contractions.

### Possible Issues

A globally assigned bare axis symbol is evaluated before `Einstoff` sees the description:

```wl
In[1]:= Block[{c = 3}, Einstoff[ArrayReshape][{{"c"}} :> {{"c"}}, {Range[5]}]]

Out[1]= {1, 2, 3, 4, 5}
```

Keep `bindings` as a list of rules:

```wl
In[1]:= Einstoff["Massage"][{{a_}} :> {{a, c}}, {Range[4]}, {c -> 3}]

Out[1]= {{1, 1, 1}, {2, 2, 2}, {3, 3, 3}, {4, 4, 4}}
```

Target heads are part of targeted binding keys:

```wl
In[1]:= Einstoff[Map]["id"][{{a_, Slot["b"]}} :> {{a, Slot["b"]}}, {ArrayReshape[Range[6], {2, 3}]}]

Out[1]= {{1, 2, 3}, {4, 5, 6}}
```

Structural direct sums use bare `CirclePlus`:

```wl
In[1]:= Einstoff[Join][{{a_}, {b_}} :> {{a ⊕ b}}, {Range[2], Range[3]}]

Out[1]= {1, 2, 1, 2, 3}
```

## See Also

`ArrayReshape` | `Transpose` | `ArrayReduce` | `Tr` | `Inner` | `Dot` | `TensorContract` | `TensorTranspose` | `ResourceFunction["ArrayContract"]` | `ResourceFunction["EinsteinSummation"]`

External references: einops `rearrange`, einops `reduce`, einops `einsum`, and the einx operation family.

## Related Guides

- Rearranging & Restructuring Lists
- Tensors
- Matrix Operations
- Handling Arrays of Data

## History

Introduced in 2026.
