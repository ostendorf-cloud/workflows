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
# a repository config, and applies the package rules to sample updates in
# the order renovate's "flatten" step uses. That shows which update gets
# "automerge": true and which "minimumReleaseAge" applies, with no
# platform and no network. CI does not set it. Example:
#   REAL_RENOVATE=1 mise x node@24.11.0 npm:renovate@44.238.0 -- \
#     scripts/reusable-renovate-automerge_test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${script_dir}/.."
workflow="${REUSABLE_RENOVATE_WORKFLOW:-${repo_dir}/.github/workflows/reusable-renovate.yaml}"
preset="${RENOVATE_PRESET:-${repo_dir}/default.json}"
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

# The Renovate step without comments and without its "uses:" line, whose
# digest Renovate itself updates, up to the next step or the end of the
# file.
awk '
  /^      - name: Self-hosted Renovate$/ { in_step = 1; next }
  in_step && /^      - / { exit }
  in_step && /^ *#/ { next }
  in_step && /^        uses: / { next }
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
# sorted and comma separated. A rule without "matchUpdateTypes" counts as
# "ALL".
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
# line, whose automerge rules cover exactly <types>. After them comes
# exactly one rule that turns automerge off: every GitHub Actions update.
# No rule names a package, so first party packages merge like any other.
# No rule sets any other option.
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
    (.[-1] | del(.description) == {"matchManagers": ["github-actions"],
      "automerge": false})
  ' "${rules}" >/dev/null; then
    fail "${what}" "the GitHub Actions rule is not last or not exact: $(cat "${rules}")"
    return
  fi
  # First party packages get no rule of their own: no rule matches a
  # package name, so they merge under the switch rules like any other
  # package, and the rules before the GitHub Actions rule all turn
  # automerge on.
  if ! jq -e '
    ([.[] | has("matchPackageNames")] | any | not)
    and ([.[:-1][] | .automerge] | all(. == true))
    and (tostring | contains("ostendorf-cloud") | not)
  ' "${rules}" >/dev/null; then
    fail "${what}" "a rule names a package or a first party rule is left: $(cat "${rules}")"
    return
  fi
  # The only guard against a switch rule that also sets an option such as
  # "ignoreTests" or "automergeType".
  if ! jq -e '
    [.[] | keys[]] - ["automerge", "description", "matchManagers",
      "matchUpdateTypes"] | length == 0
  ' "${rules}" >/dev/null; then
    fail "${what}" "a rule sets another option: $(cat "${rules}")"
    return
  fi
  echo "PASS ${what}"
}

# The step reads both variables from the caller's "vars", has the id the
# Renovate step reads its output from, and nothing else: no "if:", no
# "continue-on-error:".
want_wiring="        if: steps.guard.outputs.run == 'true'
        id: automerge
        env:
          AUTO_MERGE_PATCH: \${{ vars.RENOVATE_AUTO_MERGE_PATCH }}
          AUTO_MERGE_MINOR: \${{ vars.RENOVATE_AUTO_MERGE_MINOR }}"
if [ "$(grep -v '^ *#' "${work}/wiring")" != "${want_wiring}" ]; then
  fail "the step is wired to both variables and nothing else" "got:"$'\n'"$(cat "${work}/wiring")"
else
  echo "PASS the step is wired to both variables and nothing else"
fi

# The Renovate step gets the token, autodiscovery, the package rules and
# the one allowed post upgrade command, and nothing else, such as
# RENOVATE_IGNORE_TESTS, RENOVATE_AUTOMERGE or RENOVATE_PLATFORM_AUTOMERGE.
# scripts/renovate-post-upgrade_test.sh checks the allowed command itself.
want_renovate="        if: steps.guard.outputs.run == 'true'
        with:
          token: \${{ steps.app-token.outputs.token }}
        env:
          RENOVATE_AUTODISCOVER: 'true'
          RENOVATE_PACKAGE_RULES: \${{ steps.automerge.outputs.package-rules }}
          RENOVATE_ALLOWED_COMMANDS: '[\"^pnpm --dir web install --lockfile-only --ignore-scripts --ignore-pnpmfile\$\"]'"
if [ "$(cat "${work}/renovate-step")" != "${want_renovate}" ]; then
  fail "the Renovate step has exactly the expected keys" "got:"$'\n'"$(cat "${work}/renovate-step")"
else
  echo "PASS the Renovate step has exactly the expected keys"
fi

# The step is the one directly before Renovate, so its output exists when
# Renovate starts and no other step can write to $GITHUB_ENV in between.
previous_step="$(awk '
  /^      - / { if ($0 == "      - name: Self-hosted Renovate") { print last; exit } last = $0 }
' "${workflow}")"
if [ "${previous_step}" != "      - name: ${step_name}" ]; then
  fail "the step runs directly before Renovate" "the step before Renovate is '${previous_step}'"
else
  echo "PASS the step runs directly before Renovate"
fi

# No "env:" at workflow or job level, where it would reach Renovate too,
# such as RENOVATE_IGNORE_TESTS.
if grep -nE '^(env:|    env:)' "${workflow}"; then
  fail "no workflow or job level env" "found an 'env:' key at workflow or job level"
else
  echo "PASS no workflow or job level env"
fi

# No step writes to $GITHUB_ENV, where a RENOVATE_* variable would reach
# Renovate too, and the automerge step is the job's only "run:" step.
# Comments are skipped, they may name GITHUB_ENV.
if grep -v '^ *#' "${workflow}" | grep -n 'GITHUB_ENV'; then
  fail "no step writes to GITHUB_ENV" "found GITHUB_ENV outside a comment"
else
  echo "PASS no step writes to GITHUB_ENV"
fi
run_steps="$(grep -cE '^ +(- )?run: ' "${workflow}" || true)"
if [ "${run_steps}" != "2" ]; then
  fail "the automerge step and the guard are the only run steps" "found ${run_steps} 'run:' keys, want 2"
else
  echo "PASS the automerge step and the guard are the only run steps"
fi

# A variable must never be expanded into the script text by the runner.
if grep -qF "\${{" "${work}/step.sh"; then
  fail "the run block holds no expression" "found '\${{' in the run block"
else
  echo "PASS the run block holds no expression"
fi

# The header documents both variables, as AGENTS.md requires.
for var in RENOVATE_AUTO_MERGE_PATCH RENOVATE_AUTO_MERGE_MINOR; do
  if ! sed -n '1,/^on:$/p' "${workflow}" | grep -q "^#   ${var}: "; then
    fail "the header documents ${var}" "no '#   ${var}: ' line above 'on:'"
  else
    echo "PASS the header documents ${var}"
  fi
done

# Off is the default: no variable at all, empty variables, and "false".
run_case unset UNSET UNSET
expect_off unset "no variables means off"
run_case empty "" ""
expect_off empty "empty variables mean off"
run_case false false false
expect_off false "false means off"

# Only the exact string "true" is on.
for value in TRUE True " true" "true " 1 yes on "'true'" '"true"' trueish; do
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

  # Resolves sample updates through renovate's own code: the env parser
  # reads RENOVATE_PACKAGE_RULES into the global config, the repository
  # config is resolved with its presets and merged over it, the way
  # renovate's "mergeRenovateConfig" does, and each update goes through
  # "applyPackageRules", the config of its update type, and
  # "applyPackageRules" again, the way renovate's "flattenUpdates" does.
  # Prints "merge <type> <manager> <name>" for every update that gets
  # automerge, and "age <manager> <name> <minimumReleaseAge>" for every
  # patch update.
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
const updateTypes = ['major', 'minor', 'patch', 'pin', 'digest', 'pinDigest',
  'lockFileMaintenance', 'rollback', 'bump', 'replacement'];

// [manager, name, update types, depType]. The github-actions depTypes are
// the ones renovate's github-actions manager assigns: "action" for a step's
// "uses", "workflow" for a reusable workflow call, "container" and
// "service" for a job's images.
const samples = [
  ['npm', 'left-pad', ['patch', 'minor', 'major', 'digest', 'pinDigest', 'pin', 'lockFileMaintenance'], 'dependencies'],
  ['github-actions', 'actions/checkout', ['patch', 'minor', 'major', 'digest', 'pinDigest'], 'action'],
  ['github-actions', 'ghcr.io/example/app', ['patch', 'digest'], 'container'],
  ['github-actions', 'postgres', ['patch', 'digest'], 'service'],
  ['github-actions', 'example/shared', ['patch'], 'workflow'],
  // A custom manager may set the depType "action" too. The floor is scoped
  // to the github-actions manager, so it gets none.
  ['regex', 'example/tool', ['patch'], 'action'],
  ['dockerfile', 'node', ['patch', 'digest'], 'final'],
  ['gomod', 'golang.org/x/net', ['digest'], 'require'],
  ['github-actions', 'ostendorf-cloud/workflows', ['patch', 'digest'], 'workflow'],
  ['github-actions', 'ostendorf-cloud/release-me/action', ['patch'], 'action'],
  ['renovate-config', 'ostendorf-cloud/workflows', ['patch', 'minor', 'major'], 'preset'],
  ['npm', '@ostendorf-cloud/kit', ['patch', 'major'], 'dependencies'],
  ['gomod', 'github.com/ostendorf-cloud/kit', ['minor'], 'require'],
  ['dockerfile', 'ghcr.io/ostendorf-cloud/kit', ['digest'], 'final'],
  ['terraform', 'https://github.com/ostendorf-cloud/kit', ['patch'], 'module'],
  ['terraform', 'git::https://github.com/ostendorf-cloud/kit', ['patch'], 'module'],
];
for (const [manager, name, types, depType] of samples) {
  for (const updateType of types) {
    let c = { ...merged, manager, depType, depName: name, packageName: name, updateType };
    c = await applyPackageRules(c, 'datasource-merge');
    c = mergeChildConfig(c, c[updateType]);
    for (const t of updateTypes) delete c[t];
    c = await applyPackageRules(c, 'update-type-merge');
    if (c.automerge === true) console.log(`merge ${updateType} ${manager} ${name}`);
    if (updateType === 'patch') console.log(`age ${manager} ${name} ${c.minimumReleaseAge ?? 'none'}`);
  }
}
EOF

  # resolve <name> <repo config file>: prints the resolver's lines for the
  # rules of case <name>, sorted.
  resolve() {
    RULES="$(cat "${work}/rules-$1")" LOG_LEVEL=fatal \
      node "${work}/resolve.mjs" "${dist}" "$2" 2>/dev/null | sort
  }

  # expect_resolved <name> <description> <repo config file> <want merge lines>
  expect_resolved() {
    local got
    if ! got="$(resolve "$1" "$3")"; then
      fail "$2" "renovate could not resolve the config"
      return
    fi
    got="$(grep '^merge ' <<<"${got}" || true)"
    if [ "${got}" != "$4" ]; then
      fail "$2" "automerge resolved for:"$'\n'"${got}"$'\n'"want:"$'\n'"$4"
    else
      echo "PASS $2"
    fi
  }

  lines() {
    printf '%s\n' "$@" | sort
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

  # Nothing the github-actions manager finds merges: no action, no
  # reusable workflow, no container or service image. First party
  # packages of other managers merge like any other package on patch and
  # minor, the renovate-config preset reference included, and never on
  # major.
  patch_want="$(lines \
    "merge patch npm left-pad" \
    "merge pinDigest npm left-pad" \
    "merge patch dockerfile node" \
    "merge patch regex example/tool" \
    "merge patch renovate-config ostendorf-cloud/workflows" \
    "merge patch npm @ostendorf-cloud/kit" \
    "merge patch terraform https://github.com/ostendorf-cloud/kit" \
    "merge patch terraform git::https://github.com/ostendorf-cloud/kit")"
  minor_want="$(lines \
    "merge digest dockerfile node" \
    "merge digest gomod golang.org/x/net" \
    "merge digest npm left-pad" \
    "merge minor npm left-pad" \
    "merge patch dockerfile node" \
    "merge patch npm left-pad" \
    "merge patch regex example/tool" \
    "merge pinDigest npm left-pad" \
    "merge digest dockerfile ghcr.io/ostendorf-cloud/kit" \
    "merge minor gomod github.com/ostendorf-cloud/kit" \
    "merge minor renovate-config ostendorf-cloud/workflows" \
    "merge patch renovate-config ostendorf-cloud/workflows" \
    "merge patch npm @ostendorf-cloud/kit" \
    "merge patch terraform https://github.com/ostendorf-cloud/kit" \
    "merge patch terraform git::https://github.com/ostendorf-cloud/kit")"

  expect_resolved unset "off: nothing automerges under default.json" "${preset}" ""
  expect_resolved patch "patch: third party patch and pinDigest automerge, no GitHub Actions" "${preset}" \
    "${patch_want}"
  expect_resolved both "patch and minor: third party patch, minor and digest automerge, no GitHub Actions" \
    "${preset}" "${minor_want}"
  expect_resolved minor "minor alone: the same as patch and minor" "${preset}" "${minor_want}"

  # The release age floor of the preset: three days for actions and
  # reusable workflows, none for container and service images in a
  # workflow, none for the first party workflow reference, two days for
  # npm, none for other managers. It applies with the switches off too.
  got_age="$(resolve unset "${preset}" | grep '^age ' || true)"
  want_age="$(lines \
    "age dockerfile node none" \
    "age github-actions actions/checkout 3 days" \
    "age github-actions example/shared 3 days" \
    "age github-actions ghcr.io/example/app none" \
    "age github-actions postgres none" \
    "age github-actions ostendorf-cloud/release-me/action 3 days" \
    "age github-actions ostendorf-cloud/workflows none" \
    "age npm @ostendorf-cloud/kit 2 days" \
    "age npm left-pad 2 days" \
    "age regex example/tool none" \
    "age renovate-config ostendorf-cloud/workflows none" \
    "age terraform git::https://github.com/ostendorf-cloud/kit none" \
    "age terraform https://github.com/ostendorf-cloud/kit none")"
  if [ "${got_age}" != "${want_age}" ]; then
    fail "the preset sets the release age floor" "got:"$'\n'"${got_age}"$'\n'"want:"$'\n'"${want_age}"
  else
    echo "PASS the preset sets the release age floor"
  fi

  # A repository's own package rule comes after the global ones and wins.
  jq '.packageRules += [{"matchPackageNames": ["*"], "automerge": false}]' \
    "${preset}" >"${work}/veto.json"
  expect_resolved both "a repository package rule vetoes automerge" "${work}/veto.json" ""

  # A top level "automerge": false does not veto: package rules apply on
  # top of it. The README says so.
  jq '. + {"automerge": false}' "${preset}" >"${work}/top-level.json"
  expect_resolved both "a top level automerge false does not veto" "${work}/top-level.json" "${minor_want}"

  # Neither does "patch": {"automerge": false}: renovate applies the
  # package rules again after the update type's own config.
  jq '. + {"patch": {"automerge": false}}' "${preset}" >"${work}/top-patch.json"
  expect_resolved patch "a top level patch automerge false does not veto" "${work}/top-patch.json" \
    "${patch_want}"

  # A repository's own rule can still merge majors: the switches never
  # merge them, the repository can.
  jq '.packageRules += [{"matchUpdateTypes": ["major"], "automerge": true}]' \
    "${preset}" >"${work}/repo-major.json"
  expect_resolved patch "a repository rule merges majors by itself" "${work}/repo-major.json" \
    "$(lines "${patch_want}" \
      "merge major github-actions actions/checkout" \
      "merge major npm @ostendorf-cloud/kit" \
      "merge major npm left-pad" \
      "merge major renovate-config ostendorf-cloud/workflows")"
fi

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
