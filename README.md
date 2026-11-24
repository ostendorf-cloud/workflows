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
  every caller gets the same centralized check. Two optional variables let Renovate merge patch
  and minor updates by itself, see [Renovate automerge](#renovate-automerge).

  ```yaml
  on:
    schedule:
      - cron: "17 * * * *" # hourly; pick your own minute so repositories do not all run at once
    workflow_dispatch:
    issues:
      types: [edited]
    pull_request:
      types: [edited]
    workflow_run:
      workflows: [checks, codeql, dco] # every workflow that runs checks on a pull request
      types: [completed]
      branches: ["renovate/**"]

  jobs:
    renovate:
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-renovate.yaml@v0.3.0
      secrets: inherit
  ```

  Run it hourly as well: a run is skipped for the bot's own edits, and GitHub delays or drops
  scheduled runs under load. The `workflow_run` trigger runs Renovate right after the checks of a
  Renovate branch have finished, so an automerge does not wait for the next tick.

  Finding the name for `workflows:`:
  - The `workflows:` list names every workflow that runs checks on a pull request, for example
    `[checks, codeql, dco]`. Each entry is the `name:` field of a workflow file in
    `.github/workflows/`, not the file name and not a job name.
  - Renovate runs after each listed workflow, and merges only when no check is failing or still
    running. A workflow left out of the list can leave a pending check, so Renovate waits for
    the next scheduled tick.
  - A workflow that does not run on Renovate branches never triggers the event. A name that
    matches no workflow fails silently: no event arrives and the schedule still works.
  - The caller file must be on the default branch, or GitHub delivers no event.
  - The `workflow_run` trigger works only with a release of `reusable-renovate.yaml` that
    contains this change. An older release fails safe: it does nothing for the event.

  Why this is safe, in three lines:
  - A `workflow_run` workflow runs from the default branch with secrets and a write token, even
    for a fork. Its branch and repository text is attacker controlled.
  - `reusable-renovate.yaml` runs Renovate only for a successful run of a branch that starts
    with `renovate/` in the calling repository itself, written once in the reusable workflow.
  - The text only reaches environment variables that are compared, never a script, a checkout
    or a log line. The caller adds the trigger and no `if:`.

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
- pnpm 11 and later raise this error. The action reacts to it only.
- The pnpm policy stays as it is. The action changes no setting and adds no exclude.

The caller keeps two jobs in its own workflow, so the token boundary stays visible there:

- The install job runs code of the pull request. It has `contents: read` only, keeps no
  checkout credential and names no token. On failure it uploads its log as an artifact.
- The comment job runs on a fresh runner with `pull-requests: write`. It checks out nothing. Its
  only step is the action, which downloads the log and passes the token to its script step
  alone.
- The log is data. Only package names of at most 214 characters, versions of at most 64
  characters and strict timestamps reach the comment, in backticks, at most 50 entries, the rest
  counted.
- The earlier comment is found by its author and a body that starts with the marker
  `<!-- pnpm-release-age -->`. The author is `comment-author`, default `github-actions[bot]`.
  It must match the token, or every run posts a new comment. A comment of anyone else is never
  edited.
- The artifact name carries `github.run_attempt`, so a rerun never reads an older log.
- The comment job needs `gh` and `jq` on the runner. Both are installed on `ubuntu-latest`. A
  runner without `jq` fails the step and posts nothing. A failed list call never posts a second
  comment.
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

- Never call the action from the install job, and never give the install job
  `pull-requests: write`. The install runs code of the pull request, which would then share a
  runner with a token that can write to the pull request.
- Replace the install command with the repository's own, for example `task web:deps`. Keep
  `set -o pipefail`, the `2>&1` and the `tee` into `$RUNNER_TEMP/install.log`.
- `log-file` names the log inside the artifact when it is not `install.log`.
- `jdx/mise-action` uses the job's read only token for tool downloads by default and does not
  persist it. Drop the step if the runner already has pnpm.
- A pull request opened by Dependabot runs with a read only `GITHUB_TOKEN` by default. GitHub
  documents that the `permissions` key raises it, so the comment job's `pull-requests: write`
  should apply there too. This is not tested yet.
- The action is referenced by the floating tag `@v0`, like the reusable workflows. It needs a
  release of this repository before `@v0` contains it.

### Post as the dependencies app

The comment can appear as the organisation's dependencies app, like the other Renovate
comments. This variant is optional. Without it the action keeps `github.token` and the author
`github-actions[bot]`.

- The comment job mints a token for the app with `actions/create-github-app-token`, the same
  pinned version as `reusable-renovate.yaml`.
- The token has `pull-requests: write` and no other permission. Without `owner` and
  `repositories` it is scoped to the calling repository only.
- `comment-author` is `ostendorf-cloud-dependencies[bot]`, the login of the app's comments.
  `${{ steps.app-token.outputs.app-slug }}[bot]` gives the same login without hard coding it.
- The private key is readable by every workflow of every branch of this repository, so by
  everyone with write access. With it, any token the app installation allows can be minted for
  any repository the app is installed on. `permission-pull-requests: write` limits only the
  token of this step, never the key.
- Every action in the comment job runs next to the key, like `renovatebot/github-action` in
  `reusable-renovate.yaml`. The supply chain trust is the same.
- Use this variant only where the owner alone has write access and the secret's visibility
  already includes the repository for Renovate. Otherwise keep the default variant with
  `github.token`.
- The install job names no secret and no token. That is the real boundary against the code of
  the pull request, such as pnpm lifecycle scripts.
- The secret is not available to a fork pull request. The comment job is skipped there anyway.
- A Dependabot pull request gets no Actions secrets, so the token step fails there. Renovate is
  the only dependency bot in this organisation.
- Switching the identity on an open pull request leaves the old comment. The new identity posts
  a second one.
- When `GH_APP_DEPENDENCIES_PRIVATE_KEY` is an organisation secret, its visibility must include
  the repository. `GH_APP_DEPENDENCIES_APP_ID` is an organisation variable.
- A stronger design is not built here: a `workflow_run` comment workflow on the default branch,
  with the key in an environment limited to `main`.

Only the comment job changes. The install job stays exactly as above.

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
      # No owner and no repositories: the token is scoped to this repository only.
      - uses: actions/create-github-app-token@<digest>  # <version>
        id: app-token
        with:
          app-id: ${{ vars.GH_APP_DEPENDENCIES_APP_ID }}
          private-key: ${{ secrets.GH_APP_DEPENDENCIES_PRIVATE_KEY }}
          permission-pull-requests: write
      - uses: ostendorf-cloud/workflows/.github/actions/pnpm-release-age-comment@v0
        with:
          github-token: ${{ steps.app-token.outputs.token }}
          comment-author: ostendorf-cloud-dependencies[bot]
          artifact-name: install-log-${{ github.run_attempt }}
```

- Replace `<digest>` and `<version>` in the token step with the pin that
  `reusable-renovate.yaml` uses for `actions/create-github-app-token`. The snippet carries no
  digest, so a Renovate update of the action never needs a README edit.
- `actions/create-github-app-token` marks `app-id` as deprecated in favour of `client-id`.
  The snippet keeps `app-id` and the existing variable, like `reusable-renovate.yaml`.

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
- a `packageRules` entry that raises `minimumReleaseAge` to three days for actions and reusable
  workflows (`github-actions` manager, depTypes `action` and `workflow`), and one after it that
  sets it back to `null`, no floor, for `ostendorf-cloud/workflows`. See
  [GitHub Actions](#github-actions).
- a `packageRules` entry for the `gomod` manager that sets `postUpdateOptions` to
  `gomodUpdateImportPaths` and `gomodTidy`. A Go major update then replaces the old module in
  `go.mod` and rewrites the import paths in the source, instead of adding the new major next to
  the old one. Application logic may still need a manual change, so a major update pull request is
  not always mergeable as it is. No other manager is touched.
- a `packageRules` entry for the `mise` manager that sets `enabled` to `false` for `imagemagick`
  and `conda:imagemagick`. Renovate looks the pin up as a conda package, finds no result and warns
  on every run. The pin is updated by hand. No other mise tool is touched. Delete the rule to
  re-enable the lookup.

### First party references

One package rule covers both kinds of reference to this repository:

- The `github-actions` manager finds the workflow references `@v0` in `.github/workflows`.
- The `renovate-config` manager finds the preset reference `#v0` in the Renovate configuration.

For both, the rule turns off `pinDigests` and sets the `github-actions` versioning. Without the
rule, Renovate proposes a digest pin for `@v0`. It also reads `#v0` with `semver-coerced`
versioning, proposes a bump to the newest exact tag and a digest pin. With the rule, `v0` counts
as the newest `v0.x` tag, so neither reference gets an update. A new tag of this repository
moves `v0`, and every consumer picks it up without a change.

### govue lock file preset

`govue-lockfile.json` is an opt in preset. It regenerates `web/pnpm-lock.yaml` when Renovate
updates the govue npm dependency through a regex custom manager. Renovate regenerates no lock
file for a custom manager, so without it each govue pull request needs a manual pnpm run.

A repository that needs it adds the preset next to the shared one, and sets the pnpm version it
pins in the rule of its govue group:

```json
{
  "extends": [
    "github>ostendorf-cloud/workflows#v0",
    "github>ostendorf-cloud/workflows:govue-lockfile#v0"
  ],
  "packageRules": [
    {
      "matchPackageNames": ["github.com/ostendorf-cloud/govue", "ostendorf-cloud/govue"],
      "groupName": "govue",
      "constraints": { "pnpm": "12.21.0" }
    }
  ]
}
```

- The preset sets one `postUpgradeTasks` command for the `custom.regex` manager and the package
  `ostendorf-cloud/govue`, and for nothing else:

  ```sh
  pnpm --dir web install --lockfile-only --ignore-scripts --ignore-pnpmfile
  ```

- `reusable-renovate.yaml` allows this one command and no other, through
  `RENOVATE_ALLOWED_COMMANDS`. The pattern is anchored with `^` and `$`, because Renovate searches
  a pattern anywhere in the command.
- The gate is global. `postUpgradeTasks` is repository configuration. Any repository on this
  workflow can attach the same command to any dependency or manager, and set
  `workingDirTemplate` inside its checkout. The gate allows exactly one command. The preset only
  chooses when it runs. The impact is low, since the command never changes.
- Renovate commits only `web/pnpm-lock.yaml` from the preset's task (`fileFilters`).
- The task runs no project script and no project pnpmfile.
- It runs in the Renovate job with the dependencies app token of that run, scoped to the calling
  repository. The workflow sets no `permission-*` input, so the token carries every permission
  the GitHub App has on that repository. That set is defined in the infrastructure repository
  and was not checked here. Renovate passes the token to the command as git configuration.
- `installTools` installs pnpm in the Renovate container before the command. The version comes
  from `constraints.pnpm`. Without it Renovate installs the newest stable pnpm.
- Limits: the repository keeps its package in `web/`, and only the govue dependency of the custom
  manager is covered. Other managers regenerate their own lock files.
- To turn the preset's task off in one repository, remove the preset from `extends`. The manual
  step is then back.
- To turn it off for every repository, remove `RENOVATE_ALLOWED_COMMANDS` from
  `reusable-renovate.yaml`. A repository that still extends the preset then gets an artifact error
  on each govue pull request instead of a lock file.
- `scripts/renovate-post-upgrade_test.sh` checks the scope, the command, and the one anchored
  pattern. See [the concept](docs/concepts/renovate-post-upgrade.md) for the design.

## Renovate automerge

`reusable-renovate.yaml` can let Renovate merge updates by itself once the checks are green. Two
GitHub variables switch it, read from the calling repository or its organisation. Both are off
by default, so a repository without them behaves as before.

| Variable | Value `true` merges by itself |
| --- | --- |
| `RENOVATE_AUTO_MERGE_PATCH` | `patch` updates and `pinDigest` updates |
| `RENOVATE_AUTO_MERGE_MINOR` | `minor` and `digest` updates, and everything the patch switch covers |

- Only the exact string `true` turns a switch on. `True`, `1`, `yes` or an empty value are off.
- The minor switch includes patch. `RENOVATE_AUTO_MERGE_MINOR=true` merges patch updates even
  when `RENOVATE_AUTO_MERGE_PATCH` is unset or `false`.
- A `pinDigest` update adds the digest of the version already in use. It changes no code.
- A `digest` update follows the minor switch, not the patch switch. It moves a floating tag such
  as `node:24`, or a Go module without tags, and can carry more than a patch.
- Major updates never merge through these switches. Neither do `pin`, `lockFileMaintenance`,
  `rollback`, `bump`, `replacement` and `lockfileUpdate` updates.
- Nothing the `github-actions` manager finds merges through these switches, whatever they say:
  no action, no reusable workflow, no container or service image of a workflow. See
  [GitHub Actions](#github-actions).
- Packages under `ostendorf-cloud` never merge through these switches. A first party release
  always needs a human. The rule matches `ostendorf-cloud/**`, `@ostendorf-cloud/**`,
  `github.com/ostendorf-cloud/**`, `ghcr.io/ostendorf-cloud/**`,
  `https://github.com/ostendorf-cloud/**` and `git::https://github.com/ostendorf-cloud/**`.
- A repository's own configuration can still merge any of these. A package rule with
  `matchUpdateTypes: ["major"]` and `automerge: true`, the `:automergeAll` preset or a top level
  `major: { "automerge": true }` merges majors. A package rule with `matchPackageNames: ["*"]` and
  `automerge: true` merges first party packages.
- No release follows by itself. An automerged `fix(deps)` commit only lands in the release pull
  request that `release-me` keeps open. A release happens when the owner merges that pull
  request.

### GitHub Actions

Actions in this organisation are pinned by digest with a version comment, such as
`actions/checkout@<sha> # v4.1.2`. Renovate produces two kinds of update for such a reference.

| Change upstream | `updateType` | Version |
| --- | --- | --- |
| New release `v4.1.3` | `patch`, new digest | `v4.1.3`, semver level set |
| Tag `v4.1.2` moved to another commit | `digest` | `v4.1.2` unchanged, no semver level |

- A moved tag is the pattern of a compromised action. When the moved tag is the version in use,
  the update keeps the version, so `matchUpdateTypes` sees only `digest`.
- When the moved tag is newer than the version in use, Renovate offers it as an ordinary `patch`
  or `minor` update with the bad digest. Nothing in the update type tells the two apart.
- Confirmed against renovate 44.238.0. Its lookup adds `{ updateType: "digest", newValue:
  currentValue }` when the current digest differs from the tag's digest. A lookup run for a
  digest that did not match its tag returned that update with `newMajor`, `newMinor` and
  `newPatch` all `null`. The same run returned `patch`, `minor` and `major` updates with a new
  digest for the newer releases.
- GitHub Actions therefore never merge through the switches. The workflow adds
  `{"matchManagers": ["github-actions"], "automerge": false}` after the switch rules. It covers
  actions, reusable workflows and the container and service images of a workflow.
- Actions are few updates per repository. They stay a human decision.
- The preset delays an action or reusable workflow release by three days with
  `minimumReleaseAge`. That is a delay that gives a compromised release time to be noticed, not a
  guarantee:
  - The `github-tags` datasource dates a tag by its commit date, or by its tagger date for an
    annotated tag. The pusher controls both. A new tag on a backdated commit passes the floor at
    once. A GitHub release with a later date moves the date forward.
  - A moved tag is dated by the commit it now points to. The pusher can backdate that too.
- The floor matches depTypes `action` and `workflow` only. Container and service images in a
  workflow get no floor. A `ghcr.io` image has no release timestamp, and with the default
  `minimumReleaseAgeBehaviour` `timestamp-required` a floor would hold it forever.
- The first party workflow reference `ostendorf-cloud/workflows` has no floor. It stays on its
  floating tag. Other first party actions, such as `ostendorf-cloud/release-me/action`, wait three
  days too.
- Docker digests outside workflow files, such as in a Dockerfile, keep following the minor
  switch. The preset sets no release age for Docker or other registries. Only Docker Hub provides
  release timestamps, so a floor would hold updates from other registries forever.
- To let action patches merge again later, remove the one rule `actions_rule` from the step
  `Build the automerge package rules` in `reusable-renovate.yaml`. The release age floor stays.

### Branch protection comes first

Automerge is only as safe as the checks that gate it.

- Renovate merges a pull request itself only when no status check and no check run on its branch
  failed or is still running. It waits while no check exists at all.
- A skipped or neutral check run counts as passed. A workflow with a path filter therefore does
  not gate an update outside its paths.
- Renovate does not read the required checks itself. It relies on GitHub's merge API, which
  refuses a merge while a required check is missing.
- Renovate also turns on GitHub's own auto-merge when the repository allows it. GitHub then
  merges once the required checks pass, and ignores checks that are not required.
- Required checks come from branch protection or a ruleset. Those live in the infrastructure
  repository.
- Turn a switch on only for a repository whose default branch requires the checks that matter.
- To check in the infrastructure repository, not verified here:
  - The `ostendorf-cloud-dependencies` app is no bypass actor of a ruleset on the default branch.
  - The app has contents write and pull requests write.
  - The app has workflows write, to merge a pull request that changes a workflow file.

### Set, override and turn off

A repository variable wins over an organisation variable of the same name. An organisation
default can therefore be overridden per repository. Where the variables are managed as code in
the infrastructure repository, set them there instead of with `gh`.

```sh
# Organisation default: patch updates merge by themselves in every repository.
gh variable set RENOVATE_AUTO_MERGE_PATCH --org ostendorf-cloud --visibility all --body true

# One repository also merges minor updates.
gh variable set RENOVATE_AUTO_MERGE_MINOR --repo ostendorf-cloud/<repository> --body true

# One repository opts out of the organisation default.
gh variable set RENOVATE_AUTO_MERGE_PATCH --repo ostendorf-cloud/<repository> --body false
```

- To turn automerge off, set the variable to `false` or delete it. Deleting a repository
  variable falls back to the organisation variable, if one exists.
- A repository can also veto automerge in its own `renovate.json` with a package rule:

  ```json
  {
    "packageRules": [{ "matchPackageNames": ["*"], "automerge": false }]
  }
  ```

  These do NOT veto: a top level `"automerge": false`, and a top level
  `"patch": { "automerge": false }`. The switch rules are package rules. Renovate applies package
  rules on top of top level options, and again after the config of the update type.
- The change takes effect on the next Renovate run, for Renovate's own merge.
- It does not reach a pull request that Renovate already armed with GitHub's native auto-merge
  (`platformAutomerge`, on by default). That pull request keeps GitHub's auto-merge and merges once
  its required checks pass. Turning a switch off, or adding the veto rule, does not disarm it.
  Disarm each one by hand, or close it:

  ```sh
  gh pr merge <number> --disable-auto
  ```

  Read from the code of renovate 44.238.0, not tested live: its GitHub platform has
  `cancelPlatformAutomerge`, but no code under `workers` calls it.

### How it works

- The step `Build the automerge package rules` compares each variable with `true`. It then picks
  fixed package rules and passes them to Renovate as `RENOVATE_PACKAGE_RULES`. A variable's
  value never becomes part of the configuration.
- Renovate reads those rules into its global configuration. It appends the rules of the
  repository's own configuration and of its presets after them. A later rule wins over an earlier
  one.
- `scripts/reusable-renovate-automerge_test.sh` runs that step for every combination of the two
  switches. With `REAL_RENOVATE=1` it also validates the rules with `renovate-config-validator
  --strict` and applies them through Renovate's own code to sample updates under `default.json`.
- CI runs only the default mode. The release age rules in `default.json` are checked in the real
  mode only, so whoever edits `default.json` runs it by hand:

  ```sh
  REAL_RENOVATE=1 mise x node@24.11.0 npm:renovate@44.238.0 -- \
    scripts/reusable-renovate-automerge_test.sh
  ```

## Development

```sh
task setup   # mise install, the pinned toolchain
task check   # every check this repository runs in CI, one after another
```

`task --list` shows the individual targets if you want to run just one.

## License

[Apache-2.0](LICENSE)
