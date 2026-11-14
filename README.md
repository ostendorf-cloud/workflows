# workflows

Shared, reusable GitHub Actions workflows for the `ostendorf-cloud` organisation.

## What it does

Each workflow in `.github/workflows/` is a `workflow_call` reusable workflow a repository in
this organisation references by tag, instead of copying the same job into every repository.

## Use

A consuming repository's own workflow calls one with `uses:`, pinned to a released tag:

```yaml
jobs:
  dco:
    uses: ostendorf-cloud/workflows/.github/workflows/reusable-dco.yaml@v0.1.1
    secrets: inherit
```

Each reusable workflow documents its own required `inputs` and `secrets` in a header comment
above its `on:` block.

Available and planned workflows:

- DCO sign-off check (`reusable-dco.yaml`): fails a pull request carrying a commit without a
  valid Developer Certificate of Origin trailer.
- Renovate configuration check (`reusable-renovate-config.yaml`): fails when a repository's
  `renovate.json` does not parse, carries an unknown or wrongly typed option, or, with its
  `strict` input enabled, needs a migration. Also fails on a nonexistent preset named in
  `extends`, bundled/shorthand presets included, by actually resolving it with a local,
  credential-free Renovate run. Two kinds of preset are out of scope, for different reasons:
  a preset addressed with `local>org/repo` fails even when it is public and valid, because
  `--platform=local` has no local-preset implementation at all, not because of a missing
  credential (use `github>org/repo` instead); a preset hosted in a private, credential-gated
  remote source fails the same way as a nonexistent one, since this workflow accepts no
  platform token.

  ```yaml
  jobs:
    renovate-config:
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-renovate-config.yaml@v0.2.0
  ```

- Checks (`reusable-checks.yaml`): runs a caller's own lint and test targets as a matrix, one
  job per check, with workflow-level concurrency, draft gating and path filtering built in
  instead of copied into every caller's own `checks.yaml`. `checks` is a JSON array of
  `{"task", "paths", "paths-ignore"}` objects: `task` is a `task` target and also becomes the
  job's own name, so a failing job names the check that failed; `paths` and `paths-ignore` are
  each an optional array of glob patterns, matched the way `case` matches: `*` spans any run of
  characters, `/` included, so `*.md` already covers `docs/adr/0001-x.md`. Write `*.md`, never
  `**/*.md`: `**` is accepted but is only a second `*`, so `**/*.md` demands a literal `/` and
  silently fails to match a file at the repository root. A check with
  neither key always runs; one with only `paths` runs when a changed file matches any of its
  patterns; `paths-ignore` then excludes a file that would otherwise match. The concurrency
  group cancels a superseded pull request run and never cancels a push to the default branch.
  No job runs while the pull request is a draft: a caller's own `pull_request` trigger must
  list `ready_for_review` in its `types`, on top of whichever types it already needs, or the
  suite never runs again once a draft pull request is marked ready. A check whose path filter
  matches nothing skips its own `task` call but still exits 0, so a required status check
  reports success instead of staying pending, since a reusable workflow has no way to filter
  its own trigger the way a caller's own `on: pull_request: paths:` would.

  Path filtering decodes its pattern arrays with `jq`, which the runner image has to provide.
  GitHub's hosted Ubuntu images preinstall it. A caller pointing `runs-on` at an image that
  does not carry `jq` fails the check with a message naming it, rather than silently skipping
  the filter. The caller's own `mise.toml` does not cover this: the checkout inside this
  workflow is the caller's repository, so the mise step installs the caller's toolchain.

  A `paths` or `paths-ignore` array can list more than one pattern; a file only needs to match
  one of them. This repository's own `checks.yaml` calls this workflow with exactly that shape,
  below. A pull request touching only `README.md` matches `*.md`, so `lint:markdown` runs, and
  matches neither `*.yaml` nor `*.yml`, so `lint:yaml` is skipped. One touching
  `.yamllint.yaml` matches `*.yaml` and runs `lint:yaml` instead.

  ```yaml
  on:
    push:
      branches: [main]
    pull_request:
      types: [opened, synchronize, reopened, ready_for_review]

  jobs:
    checks:
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-checks.yaml@v0.2.0
      with:
        checks: |
          [
            {"task": "lint:actions", "paths": [".github/workflows/*"]},
            {"task": "lint:yaml", "paths": ["*.yaml", "*.yml"]}
          ]
  ```

- Self-hosted Renovate (`reusable-renovate.yaml`): runs self-hosted Renovate for the calling
  repository, authenticated through the ostendorf-cloud-dependencies GitHub App with a token
  scoped to only that one repository, so autodiscovery finds exactly that repository and no
  other. Meant to be called from a caller's own `schedule`, `workflow_dispatch`, and
  `issues`/`pull_request` `edited` triggers, so a human checking a Renovate rebase checkbox
  reacts within that run's CI time instead of waiting for the next scheduled tick; this
  repository's own `renovate.yaml` does exactly that for itself. The anti-loop logic deciding
  whether an `edited` event should actually trigger a run lives inside `reusable-renovate.yaml`
  itself, as a job-level `if:`, so a caller does not need to write or get that condition right:
  every caller gets the same centralized check.

  ```yaml
  on:
    schedule:
      - cron: "17 3 * * *" # an example schedule; pick any cron that fits your repository
    workflow_dispatch:
    issues:
      types: [edited]
    pull_request:
      types: [edited]

  jobs:
    renovate:
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-renovate.yaml@v0.2.0
      secrets: inherit
  ```

- CodeQL scanning: planned, tracked by its own issue.
- License-header check: planned, tracked by its own issue.

## Development

```sh
task setup   # mise install, the pinned toolchain
task check   # every check this repository runs in CI, one after another
```

`task --list` shows the individual targets if you want to run just one.

## License

[Apache-2.0](LICENSE)
