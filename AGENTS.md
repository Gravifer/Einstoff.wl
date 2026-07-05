# Instructions for coding agents

A uv backed `pyproject.toml` exists in this directory,
which includes dependencies for the ein* notation and interops with Mathematica.

Our planned endgoal is a ResourceFunction named `Einstoff`.
Some elementary APIs being

- `Einstoff[ArrayReshape]` corresponding to `einx.id`/`einops.rearrange`
- `Einstoff[ArrayReduce]` corresponding to `einx` reduction ops / `einops.reduce`
  - `Einstoff[Dot]` corresponding to `einx.dot` is a special case
- Repetition (`einx.repeat` / `einops.repeat`) is **not** a separate operator.
  Following einx, an output-only axis is broadcast uniformly by *any* operator
  above (SPEC §5.5); there is no `Einstoff[ArrayRepeat]` (not a WL builtin).

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

- **Parentheses vs brackets are different things** (don't conflate `(...)` with `[...]`).
  In the einx surface notation, *parentheses* group composition — `(a b)` is a
  product (``CircleTimes``, `⊗`) and `(a + b)` is a direct sum (``CirclePlus``, `⊕`);
  *brackets* `[...]` are the elementary-op axis marker (``Slot``, used by reduce /
  dot / gather). So ``CircleTimes``/``CirclePlus`` (parens) and ``Slot`` (brackets)
  are orthogonal — e.g. ``Slot[CirclePlus[...]]`` is a *bracketed direct sum*
  (reducing/contracting over a concatenated axis).

- **Axis-name hygiene tiers** (SPEC §5.6–5.7, `feat/desc-hygiene`). A named axis has
  three spellings, and they are hygiene tiers, not just syntax: `a_` (binder — "solve
  for this"), bare `a` (reference to an *established* axis, else env-capture — a bound
  `a` reads as its literal size), `#a` = ``Slot["a"]`` (bracket), and `"a"` (a `String` —
  the fully-hygienic tier, immune to any ``Block``). At the desc boundary every
  *established* name (binder / bracket / string) is canonicalized to a fresh
  ``Unique[…,{Temporary}]`` symbol (``canonHeld`` in Lowering.wl), so ``Block[{c=3},…]``
  cannot leak `3` into axis `c`. A name may not mix the symbol/slot tier with the string
  tier (mishmash → reject). Binding keys mirror the tiers (`#a ->`/`a ->`/`"a" ->`); a
  ``Pattern`` key `a_ -> n` is rejected, a whole-axis binder is inference-only (not
  bindable), and an evaluated/junk key warns-and-continues.
  For bracketed axes specifically, ``Slot["a"]``/`#a` denotes a string-tier bracketed
  axis and should remain bracketed on a kept RHS (`{{a, #b}}`). ``Highlighted[a_]`` and
  ``Framed[a_]`` denote bind-only bracketed axes that are referenced bare on the RHS;
  ``Squiggled`` is intentionally unused because it is visually confusing.

- We will *NOT* implement the sugar layer of the syntax in the forseeable future.

- `human-explore.nb` may be too crammed with exploration code by the human,
  and would cost too much tokens to call for the agent.
  To explore on the agent's self, and persist the findings,
  create a `agent-explore.nb` notebook, or just use a plain `.wl` file.

- For wolfram language, use [the structured package format](https://reference.wolfram.com/language/tutorial/UsingTheStructuredPackageFormat.en.md)

- Wolfram language namespaces (called 'contexts' in mathematica terms) use backticks as seperators,
  so when writing inline code in markdown, use double backticks to fence it,
  e.g. ``Einstoff`Private`` or ``BeginTestSection["Einstoff`Lowering`Reduce"]``.

- On windows, the shell we're using is most likely `pwsh` (powershell v7) or `powershell`;
  there are aliases matching common `bash` utilities, but the syntax for stuff like parameters can be different.
  You don't need to generate terminal commands with full powershell verbosity,
  just keep in mind this is a possible cause of issue.

- The Python cross-validation tests (`wolframscript -script scripts/run-tests.wls python -q`)
  use Wolfram `ExternalEvaluate`/pyzmq and may fail to start the Python portion under
  Windows sandbox restrictions even when the same command works in the user's normal shell.
  If the Python portion fails to run for five consecutive attempts, stop retrying and report it clearly. It may not point to regression in the code,
  but the user would have to run the suite manually for feeding back the results.
