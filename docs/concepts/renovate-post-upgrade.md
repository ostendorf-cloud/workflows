# Renovate post upgrade task for the govue lock file

Status: proposed, for issue #91.

## Problem

- ostendorf.tech moves the Go and the npm half of `govue` in one Renovate group named `govue`.
- The npm half is found by a regex custom manager, because the npm manager skips the
  `&path:/web` specifier.
- Renovate regenerates no lock file for a custom manager, so `web/pnpm-lock.yaml` stays old.
- Every govue pull request needs `pnpm install --lockfile-only` in `web/` by hand.
- The self hosted workflow `reusable-renovate.yaml` sets no `allowedCommands`.
- Renovate therefore runs no `postUpgradeTasks` command at all today.

## Goals

- A govue pull request carries the regenerated `web/pnpm-lock.yaml` in the update commit.
- `allowedCommands` holds exactly one anchored pattern for one fixed command string.
- The task runs for the govue npm dependency of the custom manager and for no other update.
- The task runs no project script and no project pnpmfile.
- A repository opts in with one `extends` entry and opts out by removing it.
- A test proves the task scope, the command string and the single anchored pattern.

## Non goals

- Other package managers, other dependencies and other lock files.
- Changing how the custom manager extracts the govue version.
- A shell for post upgrade commands (`allowShellExecutorForPostUpgradeCommands` stays off).
- Running the task for every repository through `default.json`.

## Approach

- Global side: the Renovate step of `reusable-renovate.yaml` gets the environment variable
  `RENOVATE_ALLOWED_COMMANDS`, next to `RENOVATE_PACKAGE_RULES` that it already sets.
- Value: `["^pnpm --dir web install --lockfile-only --ignore-scripts --ignore-pnpmfile$"]`.
- Renovate tests each pattern with a regex `test`, not a full match. `^` and `$` make the
  pattern match the whole command and nothing longer or shorter.
- `--dir web` sits in the command, so the allowed pattern also fixes the directory.
  `workingDirTemplate` would move the directory out of the allowed pattern.
- The pattern has no regex metacharacter besides the anchors. It matches one string only.
- Repository side: a second published preset `govue-lockfile.json`, extended as
  `github>ostendorf-cloud/workflows:govue-lockfile#v0`.
- The preset holds one package rule: `matchManagers: ["custom.regex"]` and
  `matchPackageNames: ["ostendorf-cloud/govue"]`.
- It sets `postUpgradeTasks` with the one command, `fileFilters: ["web/pnpm-lock.yaml"]`,
  `executionMode: "update"` and `installTools: { "pnpm": {} }`.
- `executionMode: "update"` runs the task for the upgrade that carries it. `"branch"` reads
  the task from the first upgrade of the branch, which may be the Go half and carry none.
- The task runs after Renovate wrote every file of the branch, so pnpm sees the new specifier.
- pnpm: `installTools` makes Renovate run `install-tool pnpm <version>` before the command
  when `binarySource` is `install` in the containerbase image the action runs.
- The pnpm version comes from `constraints.pnpm` of the upgrade. Without it Renovate installs
  the newest stable pnpm. The repository sets it in its govue rule to the pnpm it pins.

## Token and what the run can write

- The task runs inside the Renovate job, with the token that job already mints.
- That token is the dependencies app token, scoped to the calling repository only.
- Renovate hands it to the child process as git URL rewrite configuration
  (`GIT_CONFIG_KEY_n` and `GIT_CONFIG_VALUE_n`). Other variables of the job are not passed.
- The run can write what the app may write in that one repository: branches and pull requests.
- No new secret and no new permission is added.
- Renovate commits only files that match `fileFilters`, so only `web/pnpm-lock.yaml`.
- `--ignore-scripts` and `--ignore-pnpmfile` close the path for project code to run.
- pnpm still reads the repository's own pnpm settings, such as `pnpm-workspace.yaml`.
  Those come from the default branch, like the rest of the repository's configuration.
- A dependency the new lock file names still installs from its registry in later jobs.
  The release age floors and the frozen lock file checks of the repository still apply.

## Alternatives

- A per repository rule in each `renovate.json`: every repository restates the command, and
  the test in this repository cannot see it.
- The task in `default.json`: every repository would run pnpm on every update, also without
  a `web/` directory.
- No automation: the manual step stays on every govue pull request and is easy to forget.
- A wider pattern such as `^pnpm install.*$`: it lets any repository run any pnpm flags.
- `workingDirTemplate: "web"`: works, but the allowed pattern then no longer fixes the
  directory.
- `executionMode: "branch"`: depends on which upgrade of the group sorts first.

## Open questions

- Does the action's Renovate image run with `binarySource=install`? Check the first real run.
- Does pnpm skip a `prepare` script of a git hosted dependency under `--ignore-scripts`?
  Check the first real run log. govue is first party.
- pnpm 12 refuses a package younger than its release age floor. Does a fresh govue tag
  trip it? Check the first real run.
- The `constraints.pnpm` value duplicates the pnpm pin of `mise.toml` in the repository.
  Owner decides whether a check keeps both equal.
