#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the "Build the automerge package rules" step of
# .github/workflows/reusable-renovate.yaml. The step's own run block is cut
# out of the workflow file and executed, so the test cannot drift from what
# the workflow runs. Every case runs in a throwaway directory and touches
# nothing outside it. Needs jq.
#
# With REAL_RENOVATE=1 every generated rule set also runs through the
# renovate on PATH: "renovate-config-validator --strict" validates it as
# global config, and renovate's own code reads it from
# RENOVATE_PACKAGE_RULES, merges this repository's default.json over it as
# a repository config, and applies the package rules to sample updates.
# That shows which update gets "automerge": true, with no platform and no
# network. CI does not set it. Example:
#   REAL_RENOVATE=1 mise x node@24.11.0 npm:renovate@44.238.0 -- \
#     scripts/reusable-renovate-automerge_test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${script_dir}/.."
workflow="${REUSABLE_RENOVATE_WORKFLOW:-${repo_dir}/.github/workflows/reusable-renovate.yaml}"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/reusable-renovate-automerge.XXXXXXXX")"
trap 'rm -rf "${work}"' EXIT

step_name="Build the automerge package rules"

# The run block of the step, with its 10 space indentation removed.
awk -v name="      - name: ${step_name}" '
  $0 == name { in_step = 1; next }
  in_step && /^        run: \|$/ { in_run = 1; next }
  in_run {
    if ($0 ~ /^ *$/) { print ""; next }
    if ($0 !~ /^          /) { exit }
    print substr($0, 11)
  }
' "${workflow}" >"${work}/step.sh"

if [ ! -s "${work}/step.sh" ]; then
  echo "FAIL could not extract the run block from ${workflow}"
  exit 1
fi

# The same step's lines before its run block: its "id:" and "env:".
awk -v name="      - name: ${step_name}" '
  $0 == name { in_step = 1; next }
  in_step && /^        run: \|$/ { exit }
  in_step { print }
' "${workflow}" >"${work}/wiring"

# The Renovate step, up to the next step or the end of the file.
awk '
  /^      - name: Self-hosted Renovate$/ { in_step = 1; next }
  in_step && /^      - / { exit }
  in_step { print }
' "${workflow}" >"${work}/renovate-step"

failures=0

fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# run_case <name> <patch value> <minor value>: runs the step with the two
# variables set to the given values. The value "UNSET" leaves a variable
# out of the environment. Leaves the exit code in "code", the output in
# "out" and the package rules the step wrote in "${work}/rules-<name>",
# an empty file when it wrote none.
run_case() {
  local name="$1" patch="$2" minor="$3"
  local output="${work}/output-${name}"
  : >"${output}"
  local -a vars=(env -u AUTO_MERGE_PATCH -u AUTO_MERGE_MINOR GITHUB_OUTPUT="${output}")
  if [ "${patch}" != "UNSET" ]; then
    vars+=("AUTO_MERGE_PATCH=${patch}")
  fi
  if [ "${minor}" != "UNSET" ]; then
    vars+=("AUTO_MERGE_MINOR=${minor}")
  fi
  code=0
  out="$("${vars[@]}" bash -e "${work}/step.sh" 2>&1)" || code=$?
  sed -n 's/^package-rules=//p' "${output}" >"${work}/rules-${name}"
}

# The update types the rules of one case set "automerge": true for,
# sorted and comma separated.
on_types() {
  jq -r '[.[] | select(.automerge == true) | (.matchUpdateTypes // ["ALL"])[]] | sort | join(",")' \
    "${work}/rules-$1"
}

# expect_off <name> <description>: the case ran, wrote no rules and printed
# that both switches are off.
expect_off() {
  local name="$1" what="$2"
  if [ "${code}" != "0" ]; then
    fail "${what}" "exit code = ${code}, want 0"
    echo "${out}"
  elif [ -s "${work}/rules-${name}" ]; then
    fail "${what}" "wrote package rules: $(cat "${work}/rules-${name}")"
  elif ! grep -qxF "automerge: patch=false minor=false" <<<"${out}"; then
    fail "${what}" "output lacks the off line"
    echo "${out}"
  else
    echo "PASS ${what}"
  fi
}

# expect_on <name> <description> <types>: the case wrote valid JSON, one
# line, whose automerge rules cover exactly <types>, and whose last rule
# turns automerge off for every first party package.
expect_on() {
  local name="$1" what="$2" want="$3"
  local rules="${work}/rules-${name}"
  if [ "${code}" != "0" ]; then
    fail "${what}" "exit code = ${code}, want 0"
    echo "${out}"
    return
  fi
  if ! jq -e 'type == "array"' "${rules}" >/dev/null 2>&1; then
    fail "${what}" "the package rules are not a JSON array: $(cat "${rules}")"
    return
  fi
  if [ "$(wc -l <"${rules}" | tr -d ' ')" != "1" ]; then
    fail "${what}" "the package rules are not exactly one line"
    return
  fi
  local got
  got="$(on_types "${name}")"
  if [ "${got}" != "${want}" ]; then
    fail "${what}" "automerge is on for '${got}', want '${want}'"
    return
  fi
  if ! jq -e '
    (.[-1] | .automerge == false and (has("matchUpdateTypes") | not) and
      (.matchPackageNames | sort) == (["@ostendorf-cloud/**",
        "ghcr.io/ostendorf-cloud/**", "github.com/ostendorf-cloud/**",
        "ostendorf-cloud/**"]))
    and ([.[] | select(.automerge == false)] | length) == 1
    and ([.[] | keys[]] - ["automerge", "description", "matchPackageNames",
      "matchUpdateTypes"] | length) == 0
  ' "${rules}" >/dev/null; then
    fail "${what}" "the first party rule is not last, not complete, or other options are set: $(cat "${rules}")"
    return
  fi
  echo "PASS ${what}"
}

# The step reads both variables from the caller's "vars", has the id the
# Renovate step reads its output from, and the Renovate step passes that
# output on as RENOVATE_PACKAGE_RULES.
for want in \
  "        id: automerge" \
  "          AUTO_MERGE_PATCH: \${{ vars.RENOVATE_AUTO_MERGE_PATCH }}" \
  "          AUTO_MERGE_MINOR: \${{ vars.RENOVATE_AUTO_MERGE_MINOR }}"; do
  if ! grep -qxF -- "${want}" "${work}/wiring"; then
    fail "the step is wired to both variables" "lacks '${want}'"
  fi
done
want="          RENOVATE_PACKAGE_RULES: \${{ steps.automerge.outputs.package-rules }}"
if ! grep -qxF -- "${want}" "${work}/renovate-step"; then
  fail "Renovate gets the package rules" "lacks '${want}'"
fi
# A variable must never be expanded into the script text by the runner.
if grep -qF "\${{" "${work}/step.sh"; then
  fail "the run block holds no expression" "found '\${{' in the run block"
fi
# The header documents both variables, as AGENTS.md requires.
for var in RENOVATE_AUTO_MERGE_PATCH RENOVATE_AUTO_MERGE_MINOR; do
  if ! sed -n '1,/^on:$/p' "${workflow}" | grep -q "^#   ${var}: "; then
    fail "the header documents ${var}" "no '#   ${var}: ' line above 'on:'"
  fi
done
if [ "${failures}" -eq 0 ]; then
  echo "PASS the step is wired to both variables and to Renovate"
fi

# Off is the default: no variable at all, empty variables, and "false".
run_case unset UNSET UNSET
expect_off unset "no variables means off"
run_case empty "" ""
expect_off empty "empty variables mean off"
run_case false false false
expect_off false "false means off"

# Only the exact string "true" is on.
for value in TRUE True " true" "true " 1 yes on "'true'" '"true"'; do
  run_case odd "${value}" "${value}"
  expect_off odd "the value '${value}' is off"
done

# Patch alone.
run_case patch true UNSET
expect_on patch "patch on, minor unset" "patch,pinDigest"
if ! grep -qxF "automerge: patch=true minor=false" <<<"${out}"; then
  fail "patch on, minor unset" "output lacks the switch line"
fi
run_case patch-minor-false true false
expect_on patch-minor-false "patch on, minor false" "patch,pinDigest"

# Minor includes patch, with or without the patch variable.
run_case both true true
expect_on both "patch and minor on" "digest,minor,patch,pinDigest"
run_case minor UNSET true
expect_on minor "minor on without the patch variable" "digest,minor,patch,pinDigest"
run_case minor-patch-false false true
expect_on minor-patch-false "minor on, patch false" "digest,minor,patch,pinDigest"
if ! grep -qxF "automerge: patch=true minor=true" <<<"${out}"; then
  fail "minor on, patch false" "output lacks the switch line"
fi

# A crafted value is only compared, never written into the config.
injection='true","automerge":true,"x":"'
run_case inject "${injection}" "${injection}"
expect_off inject "a crafted value is off"
run_case inject-patch true "${injection}"
expect_on inject-patch "a crafted minor value next to patch on" "patch,pinDigest"
if grep -qF '"x"' "${work}/rules-inject-patch"; then
  fail "a crafted minor value next to patch on" "the value reached the rules"
fi
injection_newline=$'true\npackage-rules=[{"automerge":true}]'
run_case inject-newline "${injection_newline}" UNSET
expect_off inject-newline "a value with a newline and a second output line is off"
if grep -q '^package-rules=' "${work}/output-inject-newline"; then
  fail "a value with a newline and a second output line is off" "an output line was written"
fi

if [ "${REAL_RENOVATE:-}" = "1" ]; then
  # The npm package's dist directory. node_modules/.bin/renovate is a
  # symlink into it or, with mise's npm backend, a shim next to it.
  renovate_bin="$(command -v renovate)"
  dist="$(dirname "$(readlink -f "${renovate_bin}")")"
  if [ ! -f "${dist}/config/utils.js" ]; then
    dist="$(dirname "${renovate_bin}")/../renovate/dist"
  fi
  if [ ! -f "${dist}/config/utils.js" ]; then
    echo "FAIL could not find the renovate package next to ${renovate_bin}"
    exit 1
  fi

  # Resolves automerge for sample updates through renovate's own code:
  # the env parser reads RENOVATE_PACKAGE_RULES into the global config,
  # the repository config is resolved with its presets and merged over
  # it, the way renovate's "mergeRenovateConfig" does, and
  # "applyPackageRules" decides each update.
  cat >"${work}/resolve.mjs" <<'EOF'
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [dist, repoFile] = process.argv.slice(2);
const load = (p) => import(pathToFileURL(join(dist, p)).href);
const { getConfig: getEnvConfig } = await load('workers/global/config/parse/env.js');
const { getConfig: getDefaults } = await load('config/defaults.js');
const { mergeChildConfig } = await load('config/utils.js');
const { resolveConfigPresets } = await load('config/presets/index.js');
const { applyPackageRules } = await load('util/package-rules/index.js');

const env = {};
if (process.env.RULES) env.RENOVATE_PACKAGE_RULES = process.env.RULES;
const globalConfig = await getEnvConfig(env);
delete globalConfig.hostRules;
const repo = JSON.parse(readFileSync(repoFile, 'utf8'));
const { config: repoResolved } = await resolveConfigPresets(repo);
const merged = mergeChildConfig(mergeChildConfig(getDefaults(), globalConfig), repoResolved);

const samples = [
  ['npm', 'left-pad', 'patch'],
  ['npm', 'left-pad', 'minor'],
  ['npm', 'left-pad', 'major'],
  ['npm', 'left-pad', 'digest'],
  ['npm', 'left-pad', 'pinDigest'],
  ['npm', 'left-pad', 'pin'],
  ['npm', 'left-pad', 'lockFileMaintenance'],
  ['github-actions', 'actions/checkout', 'patch'],
  ['github-actions', 'actions/checkout', 'major'],
  ['gomod', 'golang.org/x/net', 'digest'],
  ['github-actions', 'ostendorf-cloud/workflows', 'patch'],
  ['npm', '@ostendorf-cloud/kit', 'patch'],
  ['gomod', 'github.com/ostendorf-cloud/kit', 'minor'],
  ['docker', 'ghcr.io/ostendorf-cloud/kit', 'digest'],
];
for (const [manager, name, updateType] of samples) {
  const out = await applyPackageRules({
    ...merged, manager, depName: name, packageName: name, updateType,
  });
  if (out.automerge === true) console.log(`${updateType} ${manager} ${name}`);
}
EOF

  # resolve <name> <repo config file>: prints every sample update that
  # gets automerge, one per line, sorted, for the rules of case <name>.
  resolve() {
    RULES="$(cat "${work}/rules-$1")" LOG_LEVEL=fatal \
      node "${work}/resolve.mjs" "${dist}" "$2" 2>/dev/null | sort
  }

  # expect_resolved <name> <description> <repo config file> <want lines>
  expect_resolved() {
    local got
    if ! got="$(resolve "$1" "$3")"; then
      fail "$2" "renovate could not resolve the config"
      return
    fi
    if [ "${got}" != "$4" ]; then
      fail "$2" "automerge resolved for:"$'\n'"${got}"$'\n'"want:"$'\n'"$4"
    else
      echo "PASS $2"
    fi
  }

  for name in patch both minor; do
    jq '{packageRules: .}' "${work}/rules-${name}" >"${work}/global-${name}.json"
    if renovate-config-validator --strict "${work}/global-${name}.json" \
      >"${work}/validate-${name}.log" 2>&1; then
      echo "PASS renovate-config-validator --strict accepts the ${name} rules"
    else
      fail "renovate-config-validator --strict accepts the ${name} rules" "$(cat "${work}/validate-${name}.log")"
    fi
  done

  preset="${repo_dir}/default.json"
  expect_resolved unset "off: nothing automerges under default.json" "${preset}" ""
  expect_resolved patch "patch: only third party patch and pinDigest automerge" "${preset}" \
    "$(printf '%s\n' \
      "patch github-actions actions/checkout" \
      "patch npm left-pad" \
      "pinDigest npm left-pad" | sort)"
  minor_want="$(printf '%s\n' \
    "digest gomod golang.org/x/net" \
    "digest npm left-pad" \
    "minor npm left-pad" \
    "patch github-actions actions/checkout" \
    "patch npm left-pad" \
    "pinDigest npm left-pad" | sort)"
  expect_resolved both "patch and minor: third party patch, minor and digest automerge" \
    "${preset}" "${minor_want}"
  expect_resolved minor "minor alone: the same as patch and minor" "${preset}" "${minor_want}"

  # A repository's own package rule comes after the global ones and wins.
  jq '.packageRules += [{"matchPackageNames": ["*"], "automerge": false}]' \
    "${preset}" >"${work}/veto.json"
  expect_resolved both "a repository package rule vetoes automerge" "${work}/veto.json" ""

  # A top level "automerge": false does not veto: package rules apply on
  # top of it. The README says so.
  jq '. + {"automerge": false}' "${preset}" >"${work}/top-level.json"
  expect_resolved patch "a top level automerge false does not veto" "${work}/top-level.json" \
    "$(printf '%s\n' \
      "patch github-actions actions/checkout" \
      "patch npm left-pad" \
      "pinDigest npm left-pad" | sort)"
fi

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
