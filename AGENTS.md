# workflows

Shared, reusable GitHub Actions workflows for the `ostendorf-cloud` organisation. The baseline
rules apply and are not repeated here.

## Layout

- `.github/workflows/<name>.yaml`: one reusable workflow per file, each independently callable
  through `workflow_call`. A consuming repository references one as
  `uses: ostendorf-cloud/workflows/.github/workflows/<name>.yaml@<tag>`.
- No application code, no Go module, no `package.json`: this repository IS workflow YAML, plus a
  couple of shell scripts under `scripts/` for its own CI glue, such as the DCO check.

## Commands

```sh
task setup           # mise install
task check           # every check, one after another
task --list          # one target per check
```

- One task target per check and one CI job per target. `check` aggregates them and holds no
  command of its own. CI calls the small targets, never `check`.

## Constraints

- Every workflow file is validated by `actionlint`.
- Every reusable workflow documents its required `inputs` and `secrets` in a header comment
  above `on:`. A consuming repository cannot infer them from code the way it could read a Go
  function signature.
- Actions are pinned by digest with a trailing `# vX.Y.Z` comment, exactly like every other
  repository in this organisation.
- License header (Apache-2.0, "Copyright 2026 Simon Ostendorf") on every shell script under
  `scripts/`, checked by `lint:license`. The workflow YAML files do not carry a header comment:
  YAML has no clean, idiomatic header-comment-block convention matching the Go and shell pattern
  this organisation uses elsewhere, and none of `release-me`, `web-kit` or `skills` put a license
  header on their own `.yaml`/`.yml` workflow files either.

## Deviations

- None.
