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

- CodeQL scanning: planned, tracked by its own issue.
- License-header check: planned, tracked by its own issue.

## Renovate preset

`default.json`, at the repository root, is a shared Renovate preset for every repository in this
organisation, not this repository's own configuration (that stays in `renovate.json`). A consuming
repository extends it pinned to a released tag, the same way it pins a reusable workflow:

```json
{
  "extends": ["github>ostendorf-cloud/workflows#<tag>"]
}
```

Once `v0` exists, `github>ostendorf-cloud/workflows#v0` works as well. It is not verified how
Renovate's `renovate-config` manager treats `#v0`. The first consumer migration will show it.

Renovate's `renovate-config` manager treats a pinned preset tag as a dependency like any other,
so Renovate itself opens a pull request to bump that tag whenever a new one is released. Pinning
the preset costs no manual maintenance beyond merging that pull request.

The preset carries what is genuinely organisation-wide, so a repository's own `renovate.json`
only needs to hold what is actually specific to it:

- `config:recommended`, `:semanticCommits` and `:gitSignOff`. `dependencyDashboard` is not
  restated, since `config:recommended` already extends `:dependencyDashboard`.
- `pinDigests`, with a `packageRules` entry that turns it off for `ostendorf-cloud/workflows`.
  The preset leaves first party workflow references unpinned on purpose: a digest pin would
  rewrite `@v0` into `@<sha> # v0` and defeat the floating tag.
- the `dependencies` label.
- a `packageRules` entry that raises `minimumReleaseAge` to two days for the npm manager. pnpm 12
  defaults its own `minimumReleaseAge` to 1440 minutes (one day) and refuses a younger lockfile
  entry under `--frozen-lockfile`, while Renovate's own default is disabled, so Renovate opened a
  pull request the moment a release appeared and every job downstream of the dependency update
  failed with `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION`. Two days sits above pnpm's one-day floor.

## Development

```sh
task setup   # mise install, the pinned toolchain
task check   # every check this repository runs in CI, one after another
```

`task --list` shows the individual targets if you want to run just one.

## License

[Apache-2.0](LICENSE)
