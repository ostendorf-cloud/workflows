#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the weekly schedule of the renovate package in default.json. Renovate
# ships a patch release almost every day, so the preset proposes it once a week.
# The rule must cover the npm manager and the mise manager, which reads
# "npm:renovate" in mise.toml and names it depName "npm:renovate", packageName
# "renovate". Every case runs in a throwaway directory. Needs jq.
#
# A mutation case removes the schedule, a manager or a name from a copy of the
# preset and expects the check to fail.
#
# With REAL_RENOVATE=1 renovate's own code applies the package rules to sample
# updates, and "renovate-config-validator --strict" validates the preset. CI does
# not set it. Example:
#   REAL_RENOVATE=1 mise x node@24.11.0 npm:renovate@44.238.0 -- \
#     scripts/renovate-preset-weekly_test.sh
#
# Environment: RENOVATE_PRESET overrides the preset under test.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${script_dir}/.."
preset="${RENOVATE_PRESET:-${repo_dir}/default.json}"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/renovate-preset-weekly.XXXXXXXX")"
trap 'rm -rf "${work}"' EXIT

failures=0

fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# The package rules that name the renovate package.
renovate_rules='[.packageRules[] | select((.matchPackageNames // []) | index("renovate"))]'

# check_rule <preset file>: exits 0 when exactly one rule names "renovate", with
# the weekly schedule, both managers and both spellings of the name, and
# nothing else that changes what Renovate does with it.
check_rule() {
  jq -e "
    ${renovate_rules} as \$r
    | (\$r | length) == 1
    and (\$r[0] | .schedule == [\"before 6am on monday\"]
      and ((.matchManagers | sort) == [\"mise\", \"npm\"])
      and ((.matchPackageNames | sort) == [\"npm:renovate\", \"renovate\"])
      and ([keys[]] - [\"description\", \"matchManagers\", \"matchPackageNames\", \"schedule\"] | length == 0))
  " "$1" >/dev/null 2>&1
}

expect_ok() {
  if check_rule "$2"; then
    echo "PASS $1"
  else
    fail "$1" "the rule check failed"
  fi
}

# expect_mutant <description> <jq filter>: applies the filter to a copy of the
# preset and expects the rule check to fail on it. A filter that changes nothing
# fails the case too, so a mutation cannot silently miss.
n=0
expect_mutant() {
  n=$((n + 1))
  local file="${work}/mutant-${n}.json"
  jq "$2" "${preset}" >"${file}"
  if cmp -s "${preset}" "${file}" || [ "$(jq -S . "${preset}")" = "$(jq -S . "${file}")" ]; then
    fail "$1" "the mutation did not change the preset"
  elif check_rule "${file}"; then
    fail "$1" "the rule check still passes"
  else
    echo "PASS $1"
  fi
}

if ! jq -e . "${preset}" >/dev/null 2>&1; then
  echo "FAIL ${preset} is not valid JSON"
  exit 1
fi

expect_ok "the renovate package has one weekly rule for npm and mise" "${preset}"

# The rule comes after the generic npm rule and sets no release age, so it
# cannot change it.
if jq -e "${renovate_rules} | .[0] | has(\"minimumReleaseAge\") | not" "${preset}" >/dev/null; then
  echo "PASS the weekly rule sets no release age"
else
  fail "the weekly rule sets no release age" "the rule has minimumReleaseAge"
fi

# The rule names the package exactly: no glob, no regex.
if jq -e "${renovate_rules} | .[0].matchPackageNames | all(test(\"^[a-z:]+\$\"))" "${preset}" >/dev/null; then
  echo "PASS the names are exact"
else
  fail "the names are exact" "a name holds a pattern"
fi

expect_mutant "mutation: no schedule fails" \
  '(.packageRules[] | select((.matchPackageNames // []) | index("renovate"))) |= del(.schedule)'
expect_mutant "mutation: a daily schedule fails" \
  '(.packageRules[] | select((.matchPackageNames // []) | index("renovate"))).schedule = ["before 6am"]'
expect_mutant "mutation: no mise manager fails" \
  '(.packageRules[] | select((.matchPackageNames // []) | index("renovate"))).matchManagers = ["npm"]'
expect_mutant "mutation: no npm manager fails" \
  '(.packageRules[] | select((.matchPackageNames // []) | index("renovate"))).matchManagers = ["mise"]'
expect_mutant "mutation: no npm:renovate name fails" \
  '(.packageRules[] | select((.matchPackageNames // []) | index("renovate"))).matchPackageNames = ["renovate"]'
expect_mutant "mutation: no renovate name fails" \
  '(.packageRules[] | select((.matchPackageNames // []) | index("npm:renovate"))).matchPackageNames = ["npm:renovate"]'
expect_mutant "mutation: no rule at all fails" \
  'del(.packageRules[] | select((.matchPackageNames // []) | index("renovate")))'

if [ "${REAL_RENOVATE:-}" = "1" ]; then
  if renovate-config-validator --strict "${preset}" >"${work}/validate.log" 2>&1; then
    echo "PASS renovate-config-validator --strict accepts the preset"
  else
    fail "renovate-config-validator --strict accepts the preset" "$(cat "${work}/validate.log")"
  fi

  # The npm package's dist directory.
  renovate_bin="$(command -v renovate)"
  dist="$(dirname "$(readlink -f "${renovate_bin}")")"
  if [ ! -f "${dist}/config/utils.js" ]; then
    dist="$(dirname "${renovate_bin}")/../renovate/dist"
  fi
  if [ ! -f "${dist}/config/utils.js" ]; then
    echo "FAIL could not find the renovate package next to ${renovate_bin}"
    exit 1
  fi

  # Extracts "npm:renovate" from a mise.toml with renovate's own mise manager,
  # then applies the package rules of the preset to the dependency it found and
  # to a few that must not match. Prints "<manager> <depName> <schedule>". The
  # default schedule is "at any time".
  cat >"${work}/resolve.mjs" <<'EOF'
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [dist, repoFile] = process.argv.slice(2);
const load = (p) => import(pathToFileURL(join(dist, p)).href);
const { GlobalConfig } = await load('config/global.js');
GlobalConfig.set({ localDir: mkdtempSync(join(tmpdir(), 'preset-weekly-')) });
const { getConfig: getDefaults } = await load('config/defaults.js');
const { mergeChildConfig } = await load('config/utils.js');
const { resolveConfigPresets } = await load('config/presets/index.js');
const { applyPackageRules } = await load('util/package-rules/index.js');
const { extractPackageFile } = await load('modules/manager/mise/extract.js');
const { readFileSync } = await import('node:fs');

const { config: repo } = await resolveConfigPresets(JSON.parse(readFileSync(repoFile, 'utf8')));
const merged = mergeChildConfig(getDefaults(), repo);

const mise = await extractPackageFile(
  '[tools]\n"npm:renovate" = "44.238.0"\n"npm:left-pad" = "1.0.0"\nnode = "24"\n', 'mise.toml');
const deps = mise.deps.map((d) => ({ manager: 'mise', ...d }));
deps.push({ manager: 'npm', depName: 'renovate', packageName: 'renovate', depType: 'devDependencies' });
deps.push({ manager: 'npm', depName: 'left-pad', packageName: 'left-pad', depType: 'dependencies' });
deps.push({ manager: 'github-actions', depName: 'renovatebot/github-action',
  packageName: 'renovatebot/github-action', depType: 'action' });

for (const d of deps) {
  const c = await applyPackageRules({ ...merged, ...d, updateType: 'patch' }, 'datasource-merge');
  console.log(`${d.manager} ${d.depName} ${JSON.stringify(c.schedule ?? null)}`);
}
EOF

  got="$(LOG_LEVEL=fatal node "${work}/resolve.mjs" "${dist}" "${preset}" 2>/dev/null | sort || true)"
  want="$(printf '%s\n' \
    'mise npm:renovate ["before 6am on monday"]' \
    'mise npm:left-pad ["at any time"]' \
    'mise node ["at any time"]' \
    'npm renovate ["before 6am on monday"]' \
    'npm left-pad ["at any time"]' \
    'github-actions renovatebot/github-action ["at any time"]' | sort)"
  if [ "${got}" != "${want}" ]; then
    fail "renovate applies the weekly schedule to npm:renovate in a mise.toml and to renovate in npm" \
      "got:"$'\n'"${got}"$'\n'"want:"$'\n'"${want}"
  else
    echo "PASS renovate applies the weekly schedule to npm:renovate in a mise.toml and to renovate in npm"
  fi
fi

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
