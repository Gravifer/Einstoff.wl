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
  *brackets* `[...]` are einx surface syntax for targeted axes/literals, used by
  reduce / dot / indexing-style operations. In WL, targeted forms are spelled with
  ``Slot`` for string-tier axes, or with ``Highlighted``/``Framed`` where those tiers
  apply. So ``CircleTimes``/``CirclePlus`` (parens) and targeted wrappers are
  orthogonal — e.g. ``Highlighted[CirclePlus[...]]`` is a *targeted direct sum*
  (reducing over a concatenated axis).

- **Axis-name hygiene matrix** (SPEC §5.6–5.7, `feat/desc-hygiene`). A named axis has
  a spelling kind and an orthogonal targeted bit: `a_` (blank — infer-only, "solve
  for this"), bare `a` (reference to an *established* axis, else env-capture — a bound
  `a` reads as its literal size), and `"a"` (a `String` — the fully-hygienic kind,
  immune to any ``Block``). Targeted string axes may be written `#a` = ``Slot["a"]``,
  ``Highlighted["a"]``, or ``Framed["a"]``; targeted blank/bare symbol axes use
  ``Highlighted[a_]``/``Framed[a_]`` or ``Highlighted[a]``/``Framed[a]``. At the desc
  boundary every *established* name (blank / targeted / string) is canonicalized to a fresh
  ``Unique[…,{Temporary}]`` symbol (``canonHeld`` in Lowering.wl), so ``Block[{c=3},…]``
  cannot leak `3` into axis `c`. A name may not mix symbol spelling with string spelling
  (mishmash → reject). Binding keys mirror the spelling kind: string axes accept
  `"a" -> n` and, when targeted, the same target head used in the desc; bare axes accept
  `a -> n`; blanks are inference-only. A different target head in bindings than
  in the desc is rejected, and ``Slot`` must not target non-string axes. ``Squiggled`` is
  intentionally unused because it is visually confusing.

- We will *NOT* implement the sugar layer of the syntax in the forseeable future.

- `human-explore.nb` may be too crammed with exploration code by the human,
  and would cost too much tokens to call for the agent.
  To explore on the agent's self, and persist the findings,
  create a `agent-explore.nb` notebook, or just use a plain `.wl` file.
  - The agent should exclude notebooks when running diffs; they will be too noisy,
    and the user will keep any code they need the agent to see out of those.
    This applies primarily to `.nb` wolfram notebooks, but also to `.ipynb` jupyter notebooks if they are present.

- For wolfram language, use [the structured package format](https://reference.wolfram.com/language/tutorial/UsingTheStructuredPackageFormat.en.md)

- Wolfram language namespaces (called 'contexts' in mathematica terms) use backticks as seperators,
  so when writing inline code in markdown, use double backticks to fence it,
  e.g. ``Einstoff`Private`` or ``BeginTestSection["Einstoff`Lowering`Reduce"]``.

- ``wolframscript -script`` does not accept the script from stdin, so don't use a heredoc;
  instead, write the script to a temporary file and pass that filename to `-script`.

- On windows, the shell we're using is most likely `pwsh` (powershell v7) or `powershell`;
  there are aliases matching common `bash` utilities, but the syntax for stuff like parameters can be different.
  You don't need to generate terminal commands with full powershell verbosity,
  just keep in mind this is a possible cause of issue.
  Profile startup can be noisy and slow, so switch to no-login invocations when desirable. (`-nol` + `-noni` + `-nop`)

- The Python cross-validation tests (`wolframscript -script scripts/run-tests.wls python -q`)
  use Wolfram `ExternalEvaluate`/pyzmq and may fail to start the Python portion under
  Windows sandbox restrictions even when the same command works in the user's normal shell.
  If the Python portion fails to run for five consecutive attempts, stop retrying and report it clearly. It may not point to regression in the code,
  but the user would have to run the suite manually for feeding back the results.
