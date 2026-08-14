# Contributing

Thanks for taking an interest in Einstoff. The project is still pre-release, so the
best contributions are small, well-scoped changes that preserve the current design
boundaries.

## Audiences

- Users should start with `README.md` and `docs/Einstoff.en.md`.
- Human contributors should use this file for workflow and testing conventions.
- Coding agents should read `.agents/agents.md` and `.agents/SPEC.md`; those files are
  intentionally more implementation-heavy than the public documentation.

## Development Workflow

- Work on a feature branch, not directly on `main`.
- Use semantic commit subjects such as `feat(lowering): ...`, `fix(docs): ...`, or
  `docs(agents): ...`.
- Keep changes focused. Move unrelated cleanups into separate commits.
- When changing behavior, add or update `.wlt` tests in the relevant test file.
- When changing user-visible behavior, update `docs/Einstoff.en.md` or the README as
  appropriate.
- When changing design boundaries or deferred items, update `.agents/SPEC.md`.

Coding agents may be credited with a commit trailer.

## Notebooks

Notebooks are welcome for exploration, but ordinary contributors should not commit
notebook edits unless a maintainer explicitly asks for them.

`tests/EinstoffTestSuite.nb` is generated from the `.wlt` unit tests by:

```powershell
wolframscript -script scripts/wlt-suite-notebook.wls
```

The maintainer updates that generated notebook when new tests arrive on `main`.

## Tests

Before submitting a pull request or merge request, make sure the default
Wolfram-only suite passes at your branch HEAD:

```powershell
wolframscript -script scripts/run-tests.wls -q
```

The optional Python suite cross-validates against `einx`, `einops`, and NumPy:

```powershell
uv sync
wolframscript -script scripts/run-tests.wls python -q
```

The Python suite is useful but not required for every contribution. It depends on a
Python environment and may fail to start under some Windows sandbox restrictions even
when the Wolfram-only suite passes.

Additional tests are appreciated when they clarify behavior, cover a regression, or
pin down a design boundary.

## Paclet Repository Checks

The committed `Gravifer__Einstoff/ResourceDefinition.nb` is the source definition
notebook for Paclet Repository checks. Install the repository-pinned, checksum-
verified PacletCICD release, then run:

```powershell
wolframscript -script scripts/install-paclet-cicd.wls
wolframscript -script scripts/paclet-cicd.wls check
```

After a successful check, use the `build` argument to produce the PacletCICD archive
under the ignored `build/` directory. The build command does not repeat the check.
These commands target `"Build"`; they do not submit anything.
The GitHub workflow performs the same check and build in one job. It requires the
`WOLFRAMSCRIPT_ENTITLEMENTID` Actions secret, but not a publisher token. To avoid
running untrusted code with that secret, fork and Dependabot pull requests skip the
licensed job; a maintainer can run it after bringing trusted changes onto a branch in
this repository.

## Release Workflow

Maintainers create signed annotated `v*` tags whose version matches
`Gravifer__Einstoff/PacletInfo.wl` and whose commit is contained in `main`. The
workflow structurally requires an annotated tag; signature creation remains a
maintainer responsibility and is not cryptographically reverified in CI. The release
workflow is intentionally non-submitting: it does not use a Paclet Repository
publisher token.

For a release candidate:

1. Update `PacletInfo.wl` and move the matching notes out of the changelog's
   `Unreleased` section.
2. Run `scripts/validate-release.ps1 -Python -ExpectedTag vX.Y.Z`, then merge the
   release changes to `main`.
3. Dispatch `release.yml` on `main` with `ref=main` and the expected tag. Trusted
   release tooling from the workflow commit validates that separately checked-out
   candidate. Confirm the dry-run archive and checksum artifacts; this event has only
   read permission and cannot instantiate the publication job.
4. Create a signed annotated tag at the validated `main` commit and push it to
   GitHub. The tag event rebuilds and tests under read-only permissions, then passes
   the validated bundle to a serialized publication job.
5. Verify build provenance with `gh attestation verify` and the immutable release
   attestation with `gh release verify`; the workflow performs both checks.
6. Synchronize the updated `main` and tag to Codeberg manually.

Python/ZMQ startup is probed before MUnit starts. Release validation makes one initial
attempt plus at most three startup-only retries. Invalid interpreter/dependency setup
and real test failures are never retried. Stable publication is globally serialized;
an older stable version is never allowed to replace a newer release as `Latest`.

## Generated and Local Files

Keep local scratch work out of commits unless it is part of the requested change. In
particular, do not commit exploratory notebook churn, virtual environments, caches, or
temporary Wolfram/Python artifacts.
