# Contributing

Thanks for taking an interest in Einstoff. The project is still pre-release, so the
best contributions are small, well-scoped changes that preserve the current design
boundaries.

## Audiences

- Users should start with `README.md`, the published
  [`ResourceFunction["Einstoff"]` reference](https://resources.wolframcloud.com/FunctionRepository/resources/Einstoff/),
  and the [`Gravifer/Einstoff` paclet page](https://resources.wolframcloud.com/PacletRepository/resources/Gravifer/Einstoff/).
- Human contributors should use this file for workflow and testing conventions.
- Coding agents should read `.agents/agents.md` and `.agents/SPEC.md`; those files are
  intentionally more implementation-heavy than the public documentation.

## Development Workflow

- Work on a feature branch, not directly on `main`.
- Use semantic commit subjects such as `feat(lowering): ...`, `fix(docs): ...`, or
  `docs(agents): ...`.
- Keep changes focused. Move unrelated cleanups into separate commits.
- When changing behavior, add or update `.wlt` tests in the relevant test file.
- When changing user-visible behavior, update the native paclet documentation,
  `docs/Einstoff.en.md`, the Function Repository source notebook, or the README as
  appropriate for the affected public surface.
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

When your change affects Wolfram source or behavior, run the default suite at your
branch HEAD:

```powershell
wolframscript -script scripts/run-tests.wls -q
```

The optional Python suite cross-validates against `einx`, `einops`, and NumPy. Run it
when changing cross-validation cases, Python dependencies, or behavior compared with
those libraries:

```powershell
uv sync
wolframscript -script scripts/run-tests.wls python -q
```

The Python suite is useful but is not required for every contribution. It still starts
a Wolfram kernel through `ExternalEvaluate`, and may fail to establish its Python/ZMQ
session under some Windows sandbox restrictions even when the Wolfram-only suite
passes. Record every command you ran in the pull request. If a relevant check was not
available locally, say so; do not obtain or share a maintainer credential.

Additional tests are appreciated when they clarify behavior, cover a regression, or
pin down a design boundary.

## Hosted Validation

Ordinary GitHub CI separates free checks from work that consumes Wolfram on-demand
credits:

- Every pull request and `main` push runs the unlicensed workflow-contract and
  changed-file classifier checks.
- Python dependency or cross-validation changes run an unlicensed locked-environment
  smoke check that imports NumPy, einx, einops, and pyzmq. This does **not** execute the
  Python cross-validation suite.
- A trusted pull request runs PacletCICD only when paclet source or build machinery
  changes, and runs the default Wolfram suite only when Wolfram source, tests, or
  shared test machinery changes.
- Pushes to `main` do not repeat licensed validation already performed during review.
- Manual Paclet CI dispatches run the complete ordinary PacletCICD and Wolfram path.
- Release validation remains the comprehensive hosted path: it builds the archive and
  runs both the Wolfram and Python suites against that artifact.

Jobs are skipped individually rather than filtering out the workflow. A skipped
licensed job on a documentation-only change or fork pull request is expected, not a
missing validation result. Unknown executable or build-related paths fail closed by
selecting every ordinary check on trusted events.

### Fork pull requests and entitlements

GitHub does not pass either the upstream repository's secrets or a fork's repository
secrets into an upstream `pull_request` workflow. Approving a fork workflow run does
not change that boundary. Consequently, upstream fork pull requests receive the free
checks but skip licensed validation.

A contributor who has their own Wolfram entitlement may validate in their fork:

1. Enable GitHub Actions in the fork.
2. Add `WOLFRAMSCRIPT_ENTITLEMENTID` as a repository Actions secret in that fork.
3. Manually dispatch `paclet-ci.yml` on the contribution branch, either in the GitHub
   UI or with:

   ```powershell
   gh workflow run paclet-ci.yml --repo OWNER/Einstoff.wl --ref contribution-branch
   ```

That run uses the fork owner's secret and credits; it does not make the secret
available to the upstream pull request. Link the resulting run in the pull request if
it is useful evidence.

If an upstream maintainer needs an upstream-trusted licensed result, they must first
review the exact executable commit—including workflows, actions, scripts, dependency
files, and Wolfram code—then place the trusted commit on a branch in this repository
and manually dispatch Paclet CI there. Any alteration after that review requires a new
trust decision and result. Never paste entitlement IDs into pull requests, issues,
logs, or workflow inputs.

## Paclet Repository Checks

The committed `Gravifer__Einstoff/ResourceDefinition.nb` is the source definition
notebook for Paclet Repository checks. Install the repository-pinned, checksum-
verified PacletCICD release, then run:

```powershell
wolframscript -script scripts/install-paclet-cicd.wls
wolframscript -script scripts/paclet-cicd.wls check
wolframscript -script scripts/paclet-cicd.wls submission-check
```

After a successful check, use the `build` argument to produce the PacletCICD archive
under the ignored `build/` directory. The build command does not repeat the check.
`check` and `build` target `"Build"`. `submission-check` runs the stricter
submission-target validation, but it never authenticates or calls `SubmitPaclet` and
does not require `RESOURCE_PUBLISHER_TOKEN`.
The licensed GitHub Paclet phase performs the same check and build in one job. It
requires `WOLFRAMSCRIPT_ENTITLEMENTID`, but not a publisher token. The changed-file
classifier avoids this phase when paclet artifacts cannot be affected; a manual
dispatch intentionally runs it in full.

PacletCICD currently emits two reviewed code-inspection hint families during these
checks:

- `CodeInspectionFileIssue/UnscopedObjectError` points at held `Slot` and
  `SlotSequence` forms. They are parsed as Einstoff surface syntax and pattern data;
  they are not evaluated as anonymous-function slots.
- `CodeInspectionFileIssue/OptionsPattern` suggests removing optional defaults from
  `bindings_List : {}` arguments. The distinction is intentional: option rules cannot
  match `List`, and the test suite covers calls that omit the bindings list across the
  operator families.

Treat new error classes or new instances outside these reviewed constructs as real
findings rather than adding them to this list.

## Wolfram Repository Publication

The implementation is published as the
[`Gravifer/Einstoff` paclet](https://resources.wolframcloud.com/PacletRepository/resources/Gravifer/Einstoff/).
The separately versioned
[`ResourceFunction["Einstoff"]`](https://resources.wolframcloud.com/FunctionRepository/resources/Einstoff/)
is a thin facade over that paclet. Their publication source notebooks live in
`Gravifer__Einstoff/ResourceDefinition.nb` and
`publishing/FunctionRepository/Einstoff.nb`, respectively.

Stable tagged releases use one staged GitHub workflow for both GitHub and the Paclet
Repository. The GitHub Release is built, tested, attested, published, and verified
first. A separate read-only job then verifies that immutable release and its manifest.
Only after those jobs pass does the protected `wolfram-paclet-repository` environment
ask a maintainer to approve the Wolfram deployment. Prerelease tags remain GitHub-only,
and manual workflow dispatches remain non-publishing dry runs.

PacletCICD's public
[`SubmitPaclet`](https://resources.wolframcloud.com/PacletRepository/resources/Wolfram/PacletCICD/ref/SubmitPaclet.html)
interface rebuilds from a definition notebook or source directory; it cannot submit
the already attested GitHub archive. The release manifest therefore relates both
channels by exact source commit, version, definition-notebook SHA-256, GitHub archive
SHA-256, pinned PacletCICD version, workflow identity, and target resource. The two
archives are not assumed to be byte-identical.

Function Repository updates are still manual. Update
`publishing/FunctionRepository/Einstoff.nb` when the facade, documentation, examples,
compatibility statement, or linked paclet version changes, then use its **Check**,
**Preview**, and submission controls in an authenticated Wolfram session. Never put a
Function Repository publisher credential into the release workflow.

Before a repository update, review Wolfram's current
[`Creating Paclets`](https://resources.wolframcloud.com/PacletRepository/creating-paclets/)
instructions and [Paclet Repository guidelines](https://resources.wolframcloud.com/PacletRepository/guidelines).

## Release Workflow

Maintainers create signed annotated `v*` tags whose version matches
`Gravifer__Einstoff/PacletInfo.wl` and whose commit is contained in `main`. The
workflow structurally requires an annotated tag; signature creation remains a
maintainer responsibility and is not cryptographically reverified in CI.

### One-time GitHub environment setup

Create a protected environment named `wolfram-paclet-repository` in the GitHub
repository settings. Configure `Gravifer` as the required reviewer, permit
self-approval for this single-maintainer repository, and restrict deployments to tags
matching `v*`. Store `RESOURCE_PUBLISHER_TOKEN` as an **environment secret**, not a
repository secret. Keep `WOLFRAMSCRIPT_ENTITLEMENTID` as the separately scoped Actions
secret used by licensed validation.

Create the CI publisher token from an authenticated Wolfram session with the pinned
PacletCICD release loaded, using its documented
[`CreatePublisherToken`](https://resources.wolframcloud.com/PacletRepository/resources/Wolfram/PacletCICD/ref/CreatePublisherToken.html)
interface:

```wl
ciPublisherToken = CreatePublisherToken[
  "Einstoff GitHub CD",
  PublisherID -> "Gravifer",
  ExpirationDate -> DatePlus[Now, {1, "Year"}],
  "AllowedEndpoints" -> Automatic
]
```

Before copying `ciPublisherToken["TokenString"]` into GitHub, inspect only its
metadata:

```wl
AssociationMap[
  ciPublisherToken[#] &,
  {"Name", "PublisherID", "ExpirationDate", "AllowedEndpoints"}
]
```

Require publisher `Gravifer`, a finite approximately one-year expiration, and a
resolved endpoint list. Do not save a token whose endpoints resolve to `All` or
`None`, whose publisher is wrong, or whose expiration is indefinite. The workstation
publisher token remains separate and must not be replaced by the CI token.

Rotate the CI token before it expires: create and inspect the replacement, update the
environment secret, and keep the old token only until the next approved stable
deployment proves the replacement. Then revoke the old `PublisherTokenObject` from an
authenticated session with `DeleteObject[oldToken]`. Never print token strings in a
log, workflow input, issue, or pull request.

### Stable release sequence

For a release candidate:

1. Update `PacletInfo.wl` and move the matching notes out of the changelog's
   `Unreleased` section.
2. Run `scripts/validate-release.ps1 -Python -ExpectedTag vX.Y.Z`, then merge the
   release changes to `main`.
3. Dispatch `release.yml` on `main` with `ref=main` and the expected stable tag. Trusted
   release tooling from the workflow commit validates that separately checked-out
   candidate, including the Paclet Repository submission target. Confirm the dry-run
   archive, checksum, and manifest artifacts; this event has only read permission and
   cannot instantiate either publication job.
4. Create a signed annotated tag at the validated `main` commit and push it to
   GitHub. The tag event rebuilds and tests under read-only permissions, then passes
   the validated bundle to the serialized GitHub publication job.
5. Confirm that the GitHub Release, checksum, manifest, build attestation, and
   immutable-release verification succeeded. The Wolfram preflight must finish after
   the GitHub publication.
6. Review and approve the pending `wolfram-paclet-repository` deployment. This is the
   only job that receives both the publisher token and entitlement, and those secrets
   are exposed only to its guarded submission step.
7. Wait for the public Paclet Repository page to report the expected version, then
   perform a clean-install smoke test. Search indexing delay is not a workflow failure.
8. Synchronize the updated `main` and tag to Codeberg manually.

Python/ZMQ startup is probed before MUnit starts. Release validation makes one initial
attempt plus at most three startup-only retries. Invalid interpreter/dependency setup
and real test failures are never retried. Stable publication is globally serialized;
an older stable version is never allowed to replace a newer release as `Latest`.

### Partial failure recovery

- A Wolfram outage, rejection, or unapproved deployment does not invalidate the
  already verified GitHub Release. Address or retry only the Wolfram job.
- Before rerunning a failed Wolfram job, confirm that the expected version is not
  already public. The driver refuses an equal or newer public stable version.
- If `SubmitPaclet` may have succeeded but its acknowledgement was lost, do **not**
  rerun it. Inspect the public resource first and record the workflow result as a
  false negative if Wolfram accepted the version.
- Failure to upload the supplementary submission-record artifact does not invalidate
  an acknowledged submission; its upload step is deliberately best-effort.
- Do not add private ``ResourceSystemClient` `` calls, locale-dependent notebook scraping,
  or generated-archive manipulation as recovery mechanisms. If public `SubmitPaclet`
  is unreliable in hosted CI, return Paclet Repository submission to the manual
  procedure until the public interface is dependable.

## Generated and Local Files

Keep local scratch work out of commits unless it is part of the requested change. In
particular, do not commit exploratory notebook churn, virtual environments, caches, or
temporary Wolfram/Python artifacts.
