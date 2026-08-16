# Einstoff Function Repository submission

`Einstoff.nb` is the submission notebook for a thin Wolfram Function Repository
facade over the published `Gravifer/Einstoff` paclet. Its implementation is
deliberately limited to operator selection through:

```wl
Einstoff[operator_] :=
  PacletSymbol["Gravifer/Einstoff", "Einstoff"][operator]
```

Tensor-axis parsing, validation, planning, execution, and their tests remain in
the paclet. The function resource must not duplicate or fork those semantics.

## Free local validation

From the repository root, run:

```powershell
wolframscript -script publishing/FunctionRepository/validate.wls
```

The validator checks the notebook structure and placeholders, evaluates the
definition extracted from the notebook, and exercises representative operations
through the public `PacletSymbol` interface. It requires Wolfram Language 15.0 or
later and may retrieve the published paclet if it is not already cached.

## Human submission gate

1. Open `Einstoff.nb` in a Wolfram Language 15.0+ desktop session.
2. Confirm the selected categories: **Data Manipulation & Analysis**,
   **Core Language & Structure**, and **Programming Utilities**.
3. Confirm the existing compatibility selections, especially cloud support.
4. Use the notebook's **Check** and **Preview** actions and inspect the rendered
   usage, examples, links, and metadata.
5. Inject the maintainer's locally stored publisher token into that session and
   submit through the notebook UI.

Submission is intentionally not automated from this directory. A future unified
publication workflow should use a separate expiring publisher token scoped for CI;
the maintainer's workstation token remains local.
