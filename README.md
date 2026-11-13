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
  `strict` input enabled, needs a migration. It does not catch a nonexistent preset named in
  `extends`: Renovate's own validator does not resolve presets either, so that mistake still
  only surfaces once the hosted Renovate app runs.

  ```yaml
  jobs:
    renovate-config:
      uses: ostendorf-cloud/workflows/.github/workflows/reusable-renovate-config.yaml@<tag>
  ```

  `<tag>` is a released version once this workflow has one; it has none yet.
- CodeQL scanning: planned, tracked by its own issue.
- License-header check: planned, tracked by its own issue.
- Self-hosted Renovate: planned, tracked by its own issue.

## Development

```sh
task setup   # mise install, the pinned toolchain
task check   # every check this repository runs in CI, one after another
```

`task --list` shows the individual targets if you want to run just one.

## License

[Apache-2.0](LICENSE)
