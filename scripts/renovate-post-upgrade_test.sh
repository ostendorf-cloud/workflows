#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the one post upgrade task: the "RENOVATE_ALLOWED_COMMANDS"
# value of the "Self-hosted Renovate" step in
# .github/workflows/reusable-renovate.yaml, the opt in preset
# govue-lockfile.json and the shared preset default.json. The values are
# read from the files themselves, so the test cannot drift from them.
#
# Renovate tests each allowed pattern with a regex search on the command,
# not a full match. The test therefore checks that the one pattern is
# anchored and holds no other regex metacharacter, so it matches exactly
# one string, and that this string is the one command of the preset.
#
# Environment overrides point a check at a copy, for mutation runs:
#   POST_UPGRADE_WORKFLOW, POST_UPGRADE_PRESET, POST_UPGRADE_DEFAULT_PRESET.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${script_dir}/.."
workflow="${POST_UPGRADE_WORKFLOW:-${repo_dir}/.github/workflows/reusable-renovate.yaml}"
preset="${POST_UPGRADE_PRESET:-${repo_dir}/govue-lockfile.json}"
default_preset="${POST_UPGRADE_DEFAULT_PRESET:-${repo_dir}/default.json}"

failures=0

pass() {
  echo "PASS $1"
}

fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# check <name> <want> <got>
check() {
  if [ "$3" = "$2" ]; then
    pass "$1"
  else
    fail "$1" "got '$3', want '$2'"
  fi
}

# The raw value of RENOVATE_ALLOWED_COMMANDS, a JSON array as text.
allowed_raw="$(yq -r '.jobs.renovate.steps[]
  | select(.name == "Self-hosted Renovate")
  | .env.RENOVATE_ALLOWED_COMMANDS // ""' "${workflow}")"

if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${allowed_raw}"; then
  fail "RENOVATE_ALLOWED_COMMANDS is a JSON array" "got '${allowed_raw}'"
  echo "${failures} test(s) failed"
  exit 1
fi
pass "RENOVATE_ALLOWED_COMMANDS is a JSON array"

check "allowedCommands holds exactly one entry" 1 "$(jq 'length' <<<"${allowed_raw}")"

pattern="$(jq -r '.[0] // ""' <<<"${allowed_raw}")"

if [[ "${pattern}" == ^* && "${pattern}" == *$ ]]; then
  pass "the allowed pattern is anchored at both ends"
else
  fail "the allowed pattern is anchored at both ends" "got '${pattern}'"
fi

# The text between the anchors. With no regex metacharacter in it, the
# pattern matches this one string and nothing else.
inner="${pattern#^}"
inner="${inner%$}"
if [ -n "${inner}" ] && ! grep -q '[][\\.*+?(){}|^$]' <<<"${inner}"; then
  pass "the allowed pattern holds no other regex metacharacter"
else
  fail "the allowed pattern holds no other regex metacharacter" "got '${inner}'"
fi

# Every post upgrade command the preset sets, at the top level or in any
# package rule.
commands="$(jq -c '[(.postUpgradeTasks.commands // [])[],
  ((.packageRules // [])[] | (.postUpgradeTasks.commands // [])[])]' "${preset}")"
check "the preset sets exactly one command" 1 "$(jq 'length' <<<"${commands}")"
command="$(jq -r '.[0] // ""' <<<"${commands}")"

check "the preset command equals the allowed pattern's one match" "${inner}" "${command}"

# The same through a regex engine: the pattern matches the command and
# neither a longer nor a shorter form of it.
matches="$(jq -c --arg p "${pattern}" --arg c "${command}" \
  '[($c | test($p)), (($c + " x") | test($p)), (("x " + $c) | test($p)),
    ($c[0:-1] | test($p))]' <<<'null')"
check "the pattern matches the command and no longer or shorter form" \
  '[true,false,false,false]' "${matches}"

for flag in --lockfile-only --ignore-scripts --ignore-pnpmfile; do
  if [[ " ${command} " == *" ${flag} "* ]]; then
    pass "the command carries ${flag}"
  else
    fail "the command carries ${flag}" "got '${command}'"
  fi
done

# Where the task is set: one package rule, not the top level.
check "the preset sets no top level task" false \
  "$(jq 'has("postUpgradeTasks")' "${preset}")"
check "exactly one package rule sets the task" 1 \
  "$(jq '[(.packageRules // [])[] | select(has("postUpgradeTasks"))] | length' "${preset}")"

# That rule matches the govue dependency of the regex custom manager, with
# no other match option that could widen or move it.
scope="$(jq -c '[(.packageRules // [])[] | select(has("postUpgradeTasks"))][0]
  | with_entries(select(.key | startswith("match") or startswith("exclude")))' "${preset}")"
check "the task is scoped to the govue custom manager dependency only" \
  '{"matchManagers":["custom.regex"],"matchPackageNames":["ostendorf-cloud/govue"]}' \
  "${scope}"

tasks="$(jq -c '[(.packageRules // [])[] | select(has("postUpgradeTasks"))][0].postUpgradeTasks' \
  "${preset}")"
check "only the web lock file is committed" '["web/pnpm-lock.yaml"]' \
  "$(jq -c '.fileFilters' <<<"${tasks}")"
check "the task runs per update" '"update"' "$(jq -c '.executionMode' <<<"${tasks}")"
check "the task installs pnpm and no other tool" '["pnpm"]' \
  "$(jq -c '.installTools // {} | keys' <<<"${tasks}")"

# The shared preset every repository extends runs no task.
check "default.json sets no post upgrade task" 0 \
  "$(jq '[.. | objects | select(has("postUpgradeTasks"))] | length' "${default_preset}")"

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
