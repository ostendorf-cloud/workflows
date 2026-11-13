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
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-renovate-config.yaml@<tag>
  ```

  `<tag>` is a released version once this workflow has one; it has none yet.
- Self-hosted Renovate (`reusable-renovate.yaml`): runs self-hosted Renovate for the calling
  repository, authenticated through the ostendorf-cloud-dependencies GitHub App with a token
  scoped to only that one repository, so autodiscovery finds exactly that repository and no
  other. Meant to be called from a caller's own `schedule`, `workflow_dispatch`, and
  `issues`/`pull_request` `edited` triggers, so a human checking a Renovate rebase checkbox
  reacts within that run's CI time instead of waiting for the next scheduled tick; this
  repository's own `renovate.yaml` does exactly that for itself.

  ```yaml
  jobs:
    renovate:
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-renovate.yaml@<tag>
      secrets: inherit
  ```

  `<tag>` is a released version once this workflow has one; it has none yet.
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
