# Changelog

## [v0.10.1](https://github.com/ostendorf-cloud/workflows/compare/v0.10.0...v0.10.1) (2026-11-28)

### Bug Fixes

- **ci:** use the client id for the dependencies and security apps ([#110](https://github.com/ostendorf-cloud/workflows/pull/110))
- **ci:** use the client id for the release app token ([#109](https://github.com/ostendorf-cloud/workflows/pull/109))

## [v0.10.0](https://github.com/ostendorf-cloud/workflows/compare/v0.9.0...v0.10.0) (2026-11-27)

### Features

- **renovate:** let first party patch and minor updates automerge ([#102](https://github.com/ostendorf-cloud/workflows/pull/102))

### Bug Fixes

- **renovate:** accept pull_request_target for conflicting PRs ([#105](https://github.com/ostendorf-cloud/workflows/pull/105))

## [v0.9.0](https://github.com/ostendorf-cloud/workflows/compare/v0.8.0...v0.9.0) (2026-11-26)

### Features

- add a shared AGENTS.md line limit check ([#96](https://github.com/ostendorf-cloud/workflows/pull/96))

## [v0.8.0](https://github.com/ostendorf-cloud/workflows/compare/v0.7.0...v0.8.0) (2026-11-24)

### Features

- **renovate:** regenerate the govue pnpm lock file after an update ([#92](https://github.com/ostendorf-cloud/workflows/pull/92))
- **renovate:** migrate Go imports on a major module update ([#85](https://github.com/ostendorf-cloud/workflows/pull/85))

### Bug Fixes

- **renovate:** skip the mise imagemagick lookup ([#88](https://github.com/ostendorf-cloud/workflows/pull/88))
- **test:** derive the app token pin from the workflow, not the README ([#90](https://github.com/ostendorf-cloud/workflows/pull/90))

## [v0.7.0](https://github.com/ostendorf-cloud/workflows/compare/v0.6.0...v0.7.0) (2026-11-19)

### Features

- **renovate:** run after the checks of a Renovate branch ([#74](https://github.com/ostendorf-cloud/workflows/pull/74))

## [v0.6.0](https://github.com/ostendorf-cloud/workflows/compare/v0.5.0...v0.6.0) (2026-11-18)

### Features

- let the release age comment be posted by an app ([#67](https://github.com/ostendorf-cloud/workflows/pull/67))

## [v0.5.0](https://github.com/ostendorf-cloud/workflows/compare/v0.4.1...v0.5.0) (2026-11-18)

### Features

- **renovate:** switch automerge for patch and minor updates by variable ([#63](https://github.com/ostendorf-cloud/workflows/pull/63))
- share the pnpm release age comment as a composite action ([#61](https://github.com/ostendorf-cloud/workflows/pull/61))

## [v0.4.1](https://github.com/ostendorf-cloud/workflows/compare/v0.4.0...v0.4.1) (2026-11-17)

### Bug Fixes

- **renovate:** leave the preset reference unpinned ([#58](https://github.com/ostendorf-cloud/workflows/pull/58))

## [v0.4.0](https://github.com/ostendorf-cloud/workflows/compare/v0.3.0...v0.4.0) (2026-11-17)

### Features

- **license:** accept a header file through license-file ([#54](https://github.com/ostendorf-cloud/workflows/pull/54))
- **release:** move a floating v0 tag on every stable release ([#53](https://github.com/ostendorf-cloud/workflows/pull/53))

### Bug Fixes

- **renovate-config:** resolve a shared preset's own extends in CI ([#55](https://github.com/ostendorf-cloud/workflows/pull/55))
- **license:** fail closed on a failing find command or a bad path ([#52](https://github.com/ostendorf-cloud/workflows/pull/52))
- **renovate-config:** pass github.token for preset lookups ([#49](https://github.com/ostendorf-cloud/workflows/pull/49))

## [v0.3.0](https://github.com/ostendorf-cloud/workflows/compare/v0.2.2...v0.3.0) (2026-11-15)

### Features

- **renovate:** publish a shared preset ([#40](https://github.com/ostendorf-cloud/workflows/pull/40))

## [v0.2.2](https://github.com/ostendorf-cloud/workflows/compare/v0.2.1...v0.2.2) (2026-11-13)

### Bug Fixes

- **renovate:** move concurrency to job level ([#35](https://github.com/ostendorf-cloud/workflows/pull/35))

## [v0.2.1](https://github.com/ostendorf-cloud/workflows/compare/v0.2.0...v0.2.1) (2026-11-13)

### Bug Fixes

- **renovate-config:** pin an explicit Node.js version ([#33](https://github.com/ostendorf-cloud/workflows/pull/33))

## [v0.2.0](https://github.com/ostendorf-cloud/workflows/compare/v0.1.1...v0.2.0) (2026-11-13)

### Features

- **workflows:** run renovate per repository on checkbox edits ([#29](https://github.com/ostendorf-cloud/workflows/pull/29))
- **workflows:** resolve extends presets with renovate --platform=local ([#26](https://github.com/ostendorf-cloud/workflows/pull/26))
- **workflows:** add a reusable Renovate config validation workflow ([#24](https://github.com/ostendorf-cloud/workflows/pull/24))

### Bug Fixes

- **renovate:** scope the app token to the whole organisation ([#19](https://github.com/ostendorf-cloud/workflows/pull/19))

## [v0.1.1](https://github.com/ostendorf-cloud/workflows/compare/v0.1.0...v0.1.1) (2026-11-12)

### Bug Fixes

- **dco:** check out this repository instead of the caller ([#11](https://github.com/ostendorf-cloud/workflows/pull/11))

## v0.1.0 (2026-11-12)

### Features

- add reusable CodeQL workflow ([#7](https://github.com/ostendorf-cloud/workflows/pull/7))
- **workflows:** add self-hosted renovate workflow ([#6](https://github.com/ostendorf-cloud/workflows/pull/6))
- add reusable license-header check workflow ([#5](https://github.com/ostendorf-cloud/workflows/pull/5))
