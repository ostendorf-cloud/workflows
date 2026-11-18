# workflows

Shared, reusable GitHub Actions workflows for the `ostendorf-cloud` organisation.

## What it does

Each workflow in `.github/workflows/` is a `workflow_call` reusable workflow a repository in
this organisation references by tag, instead of copying the same job into every repository.
Each directory in `.github/actions/` is a composite action, referenced the same way.

## Use

A consuming repository's own workflow calls one with `uses:`, pinned to a released tag:

```yaml
jobs:
  dco:
    uses: ostendorf-cloud/workflows/.github/workflows/reusable-dco.yaml@v0.3.0
    secrets: inherit
```

The examples in this file pin an exact tag. The floating form `@v0` is the organisation's
preferred pin, see [Versioning](#versioning). It appears with the next release.

## Versioning

- Every stable release moves the floating major tag. For the `0.x` line that tag is `v0`.
- The organisation prefers `@v0`. A consumer then gets every release without a pull request.
- `@v0` first appears with the next release after the change that enabled it. Until then, pin
  an exact tag such as `@v0.3.0`.
- An exact tag such as `@v0.3.0` stays available for a consumer that wants to pin.
- A pre-release never moves `v0`.
- Releases stay in the `0.x` line.
- A breaking change bumps the minor version. `release-me` turns a breaking change below
  `1.0.0` into a minor bump (`bump-minor-pre-major: true` in `release-me.yaml`).
- A minor bump alone does not signal a breaking change, since a plain `feat` bumps the minor
  version too.
- A breaking change needs an upgrade note in the release notes. The maintainer writes it by hand
  into a `release-me-notes` block on the release pull request. Nothing enforces it.
- A breaking change reaches every consumer on `@v0` on its next run. The owner accepts this.
- Third party actions stay pinned by commit digest, not by a floating tag.

### Rollout

1. Merge the change that enabled `major-tag`.
2. Merge the release pull request that follows.
3. Check that `v0` exists and points at the release commit.
4. Each consumer switches its references to `@v0` and removes its `## Deviations` entry about
   the missing tag, in the same change.

A consumer with its own `pinDigests: true` in `renovate.json` must extend the preset or copy its
rule for first party workflows, or Renovate pins `@v0` to a digest again.

Each reusable workflow documents its own required `inputs` and `secrets` in a header comment
above its `on:` block.

Available and planned workflows:

- DCO sign-off check (`reusable-dco.yaml`): fails a pull request carrying a commit without a
  valid Developer Certificate of Origin trailer.
- Renovate configuration check (`reusable-renovate-config.yaml`): fails when a repository's
  `renovate.json` does not parse, carries an unknown or wrongly typed option, or, with its
  `strict` input enabled, needs a migration. Also fails on a nonexistent preset named in
  `extends`, bundled/shorthand presets included, by actually resolving it with a local
  Renovate run. Two kinds of preset are out of scope, for different reasons:
  a preset addressed with `local>org/repo` fails even when it is public and valid, because
  `--platform=local` has no local-preset implementation at all, not because of a missing
  credential (use `github>org/repo` instead); a preset hosted in a private, credential-gated
  remote source fails the same way as a nonexistent one, since this workflow accepts no
  platform token from the caller. The lookup runs with the workflow's own read only
  `github.token` as `GITHUB_COM_TOKEN`, so the runner's shared API rate limit does not fail it.
  A caller sets no new input or secret.
  - `extra-files`: validates more config files, such as a shared `default.json` preset, that
    the validator would not find on its own.
  - `preset-files`: resolves each named shared preset from the checkout, so a nonexistent
    preset in its own `extends` fails the pull request that adds it.

  ```yaml
  jobs:
    renovate-config:
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-renovate-config.yaml@v0.3.0
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
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-renovate.yaml@v0.3.0
      secrets: inherit
  ```

- License-header check (`reusable-license.yaml`): runs `addlicense -check` over the files a
  caller selects and fails when one lacks a header. It never adds or rewrites a header.
  - Inputs: `copyright-holder`, `year` and `find-commands` are required. `license-type`,
    `license-file`, `addlicense-version` (default `1.2.0`) and `runs-on-runner` are optional.
  - `license-type` is a built-in `addlicense` template, passed as `-l`. `license-file` is the
    path of a header template file, passed as `-f`. They exclude each other: setting both fails
    the job at once, and a `license-file` that does not exist fails and is named. Setting
    neither uses `apache`, as before.
  - With `license-file` the job does not pass `-s=only`, because `addlicense` 1.2.0 ignores `-f`
    when it is set. `addlicense` then reads the file and fails on one it cannot read.
  - `-check` verifies that the word copyright or an SPDX identifier appears near the top of the
    file, not which license it names and not the holder. A file carrying
    `SPDX-License-Identifier: Apache-2.0` passes against an Elastic-2.0 header file, and a file
    without a header fails. Comparing a header with the repository's `LICENSE` is a separate
    check that belongs in the calling repository.
  - `find-commands` is one or more complete shell commands, one per line. Each prints a
    newline-separated list of paths, and the union of all lists is checked.
  - The check fails closed. It fails when a command exits non zero, including a failing step
    inside a loop or a pipeline. It fails and names every printed path that is not a regular
    file after all commands have ended, so a command may create the files it prints. It fails
    when no command prints a path.
  - The log states how many files go to `addlicense` and lists them.

  ```yaml
  jobs:
    license:
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-license.yaml@<tag>
      with:
        copyright-holder: Example Owner
        year: "2026"
        find-commands: |
          find . -name '*.go' -not -path './vendor/*'
  ```

- CodeQL scanning: planned, tracked by its own issue.

## pnpm release age comment

pnpm 11 and later refuse a locked package that is younger than `minimumReleaseAge`. An install
with `--frozen-lockfile` then fails with `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION`, and only the
log says why. The composite action `.github/actions/pnpm-release-age-comment` explains that
failure on the pull request.

- It posts one comment per pull request and updates it in place on a rerun.
- The comment lists each refused `name@version` with its publication time, the cutoff of the
  failed run, a rerun hint and a link to the run.
- Any other install failure, a missing log, another event or a fork pull request leaves no
  comment.
- pnpm 10 and earlier never print this error, so the comment never appears there.
- The pnpm policy stays as it is. The action changes no setting and adds no exclude.

The caller keeps two jobs in its own workflow, so the token boundary stays visible there:

- The install job runs code of the pull request. It has `contents: read` only, keeps no
  checkout credential and names no token. On failure it uploads its log as an artifact.
- The comment job runs on a fresh runner with `pull-requests: write`. It checks out nothing. Its
  only step is the action, which downloads the log and passes the token to its script step
  alone.
- The log is data. Only package names of at most 214 characters and strict timestamps reach the
  comment, in backticks, at most 50 entries, the rest counted.
- The earlier comment is found by its marker `<!-- pnpm-release-age -->` and the author
  `github-actions[bot]`. Pass `${{ github.token }}`, or every run posts a new comment.
- The artifact name carries `github.run_attempt`, so a rerun never reads an older log.
- `set -o pipefail` is required in the install step. Without a `shell` key a step runs as
  `bash -e {0}`, and the job would take the exit code of `tee` instead of the install.

```yaml
name: checks

on:
  pull_request:

permissions:
  contents: read

jobs:
  install:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1  # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@236a21c3b91f5db6d4e174b348674a0f0caac06d  # v5.2.9
      - name: Install the dependencies and keep the log
        run: |
          set -o pipefail
          pnpm install --frozen-lockfile 2>&1 | tee "$RUNNER_TEMP/install.log"
      - name: Keep the install log for the comment job
        if: failure()
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9  # v7.0.2
        with:
          name: install-log-${{ github.run_attempt }}
          path: ${{ runner.temp }}/install.log
          if-no-files-found: ignore
          retention-days: 1

  release-age-comment:
    needs: install
    if: >-
      ${{ always() && needs.install.result == 'failure'
      && github.event_name == 'pull_request'
      && github.event.pull_request.head.repo.full_name == github.repository }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    # Two quick reruns must not both create the comment.
    concurrency:
      group: release-age-comment-${{ github.event.pull_request.number }}
      cancel-in-progress: false
    steps:
      - uses: ostendorf-cloud/workflows/.github/actions/pnpm-release-age-comment@v0
        with:
          github-token: ${{ github.token }}
          artifact-name: install-log-${{ github.run_attempt }}
```

- Replace the install command with the repository's own, for example `task web:deps`. Keep
  `set -o pipefail`, the `2>&1` and the `tee` into `$RUNNER_TEMP/install.log`.
- `log-file` names the log inside the artifact when it is not `install.log`.
- `jdx/mise-action` uses the job's read only token for tool downloads by default and does not
  persist it. Drop the step if the runner already has pnpm.
- The action is referenced by the floating tag `@v0`, like the reusable workflows. It needs a
  release of this repository before `@v0` contains it.

## Renovate preset

`default.json`, at the repository root, is a shared Renovate preset for every repository in this
organisation, not this repository's own configuration (that stays in `renovate.json`). A consuming
repository extends it at the floating tag, the same way it calls a reusable workflow:

```json
{
  "extends": ["github>ostendorf-cloud/workflows#v0"]
}
```

`#v0` is the recommended form. An exact tag such as `#<tag>` works too, but Renovate then opens a
pull request to the next exact tag, as it does for any other dependency.

Renovate's `renovate-config` manager treats the preset reference as a dependency like any
other. The preset keeps the floating `#v0` as it is, see
[First party references](#first-party-references).

The preset carries what is genuinely organisation-wide, so a repository's own `renovate.json`
only needs to hold what is actually specific to it:

- `config:recommended`, `:semanticCommits` and `:gitSignOff`. `dependencyDashboard` is not
  restated, since `config:recommended` already extends `:dependencyDashboard`.
- `pinDigests`, with a `packageRules` entry that turns it off for `ostendorf-cloud/workflows`.
  The preset leaves first party workflow references and its own preset reference unpinned on
  purpose: a digest pin would rewrite `@v0` into `@<sha> # v0` and defeat the floating tag.
- the `dependencies` label.
- a `packageRules` entry that raises `minimumReleaseAge` to two days for the npm manager. pnpm 12
  defaults its own `minimumReleaseAge` to 1440 minutes (one day) and refuses a younger lockfile
  entry under `--frozen-lockfile`, while Renovate's own default is disabled, so Renovate opened a
  pull request the moment a release appeared and every job downstream of the dependency update
  failed with `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION`. Two days sits above pnpm's one-day floor.

### First party references

One package rule covers both kinds of reference to this repository:

- The `github-actions` manager finds the workflow references `@v0` in `.github/workflows`.
- The `renovate-config` manager finds the preset reference `#v0` in the Renovate configuration.

For both, the rule turns off `pinDigests` and sets the `github-actions` versioning. Without the
rule, Renovate proposes a digest pin for `@v0`. It also reads `#v0` with `semver-coerced`
versioning, proposes a bump to the newest exact tag and a digest pin. With the rule, `v0` counts
as the newest `v0.x` tag, so neither reference gets an update. A new tag of this repository
moves `v0`, and every consumer picks it up without a change.

## Development

```sh
task setup   # mise install, the pinned toolchain
task check   # every check this repository runs in CI, one after another
```

`task --list` shows the individual targets if you want to run just one.

## License

[Apache-2.0](LICENSE)
