# Einstoff Function Repository publication

`Einstoff.nb` is the published definition notebook for a thin Wolfram Function
Repository facade over the
[`Gravifer/Einstoff` paclet](https://resources.wolframcloud.com/PacletRepository/resources/Gravifer/Einstoff/).
Its implementation is
deliberately limited to operator selection through:

```wl
Einstoff[operator_] :=
  PacletSymbol["Gravifer/Einstoff", "Einstoff"][operator]
```

Tensor-axis parsing, validation, planning, execution, and their tests remain in
the paclet. The function resource must not duplicate or fork those semantics.

The accepted resource is published at
[resources.wolframcloud.com/FunctionRepository/resources/Einstoff](https://resources.wolframcloud.com/FunctionRepository/resources/Einstoff).
`Einstoff.nb` is the definition notebook downloaded from that public resource
page and is the canonical tracked artifact. Reviewer-returned notebooks can
contain reviewer identity and private submission-system metadata; keep those
copies local and do not publish their Git history.

The public 1.0.0 download currently reports `13.0+` in its scraped compatibility
metadata even though its documentation and the paclet require 15.0 or later. It
also retains only **Data Manipulation & Analysis** from the three submitted
categories. The validator reports both site-export differences as warnings.

## Free local validation

From the repository root, run:

```powershell
wolframscript -script publishing/FunctionRepository/validate.wls
```

The validator checks the notebook structure and placeholders, evaluates the
definition extracted from the notebook, and exercises representative operations
through the public `PacletSymbol` interface. It requires Wolfram Language 15.0 or
later and may retrieve the published paclet if it is not already cached.

## Human update gate

1. Open `Einstoff.nb` in a Wolfram Language 15.0+ desktop session.
2. Confirm the selected categories: **Data Manipulation & Analysis**,
   **Core Language & Structure**, and **Programming Utilities**.
3. Confirm the existing compatibility selections, especially cloud support.
4. Use the notebook's **Check** and **Preview** actions and inspect the rendered
   usage, examples, links, and metadata.
5. Inject the maintainer's locally stored publisher token into that session and
   submit the update through the notebook UI.

Submission is intentionally not automated from this directory. A future unified
publication workflow should use a separate expiring publisher token scoped for CI;
the maintainer's workstation token remains local.
