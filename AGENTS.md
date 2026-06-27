# Instructions for coding agents

A uv backed `pyproject.toml` exists in this directory,
which includes dependencies for the ein* notation and interops with Mathematica.

Our planned endgoal is a ResourceFunction named `Einstoff`.
Some elementary APIs being

- `Einstoff[ArrayReshape]` corresponding to `einx.id`/`einops.rearrange`
- `Einstoff[ArrayReduce]` corresponding to `einx` reduction ops / `einops.reduce`
  - `Einstoff[Dot]` corresponding to `einx.dot` is a special case
- `Einstoff[ArrayRepeat]` corresponding to `einx.repeat` / `einops.repeat`

Most APIs will have expect the arguments to be like

```mathematica
someAPI[desc, tensors, bindings, options]
```

where

- `desc` is a `Rule` (something like `{...} -> {...}` or using `:>` in place of `->`), describing the transformation of the axes.
- `tensors` is a `List` of tensors to be transformed.
- `bindings` is a `List` of `Rule`(or `RuleDelayed`)s, describing the axes of the tensors. Requiring it to be a `List` makes it easier to distinguish from `options`.
- `options` is the standard `OptionsPattern[]` for the function; may not be existent.

For more details on the design, see `SPEC.md`

## Notes

- We will *NOT* implement the sugar layer of the syntax in the forseeable future.
