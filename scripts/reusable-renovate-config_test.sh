#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the "Resolve the shared preset files" step of
# .github/workflows/reusable-renovate-config.yaml. The step's own run block
# is cut out of the workflow file and executed, so the test cannot drift
# from what the workflow runs. renovate is replaced by a stub that records
# where it ran and what it found there, and fails when the config holds
# the marker "BAD". Every case runs in a throwaway directory and touches
# nothing outside it.
#
# With REAL_RENOVATE=1 the stub is skipped and the renovate on PATH runs
# instead, against this repository's own default.json and a copy with a
# misspelt preset. That needs renovate and network access, so CI does not
# set it. Example:
#   REAL_RENOVATE=1 mise x node@24.11.0 npm:renovate@44.238.0 -- \
#     scripts/reusable-renovate-config_test.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${script_dir}/.."
workflow="${REUSABLE_RENOVATE_CONFIG_WORKFLOW:-${repo_dir}/.github/workflows/reusable-renovate-config.yaml}"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/reusable-renovate-config.XXXXXXXX")"
trap 'rm -rf "${work}"' EXIT

# The run block of the step named "Resolve the shared preset files", with
# its 10 space indentation removed.
awk '
  /^      - name: Resolve the shared preset files$/ { in_step = 1; next }
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

# The same step's lines before its run block: its "if:" and "env:".
awk '
  /^      - name: Resolve the shared preset files$/ { in_step = 1; next }
  in_step && /^        run: \|$/ { exit }
  in_step { print }
' "${workflow}" >"${work}/wiring"

mkdir -p "${work}/bin"
cat >"${work}/bin/renovate" <<'EOF'
#!/usr/bin/env bash
{
  echo "call"
  echo "args: $*"
  echo "cwd: ${PWD}"
  echo "files: $(ls -A)"
} >>"${STUB_LOG}"
cat ./* >>"${STUB_LOG}"
if grep -q BAD ./*; then
  echo "stub: Cannot find preset's package"
  exit 1
fi
# What renovate prints when it does not read the config it was given.
if grep -q ONBOARD ./*; then
  echo "DRY-RUN: Would commit files to Onboarding branch"
  exit 0
fi
echo "stub: ok"
EOF
chmod +x "${work}/bin/renovate"

failures=0
path_prefix="${work}/bin:"
if [ "${REAL_RENOVATE:-}" = "1" ]; then
  path_prefix=""
fi

# run_case <name> <preset-files>: runs the step in the case's workspace,
# which the caller has filled, and leaves the exit code in "code", the
# output in "out" and the stub log in "${work}/log-<name>".
run_case() {
  local name="$1" files="$2"
  local ws="${work}/ws-${name}"
  mkdir -p "${ws}" "${work}/tmp-${name}"
  : >"${work}/log-${name}"
  code=0
  out="$(cd "${ws}" &&
    PATH="${path_prefix}${PATH}" STUB_LOG="${work}/log-${name}" \
      RUNNER_TEMP="${work}/tmp-${name}" PRESET_FILES="${files}" \
      bash -e "${work}/step.sh" 2>&1)" || code=$?
}

ws() {
  mkdir -p "${work}/ws-$1"
  echo "${work}/ws-$1"
}

fail() {
  echo "FAIL $1: $2"
  echo "${out}"
  failures=$((failures + 1))
}

expect() {
  local name="$1" want_code="$2" want_text="$3"
  if [ "${code}" != "${want_code}" ]; then
    fail "${name}" "exit code = ${code}, want ${want_code}"
  elif ! grep -qF -- "${want_text}" <<<"${out}"; then
    fail "${name}" "output lacks '${want_text}'"
  else
    echo "PASS ${name}"
  fi
}

calls() {
  grep -cx call "${work}/log-$1" || true
}

if [ "${REAL_RENOVATE:-}" = "1" ]; then
  cp "${repo_dir}/default.json" "$(ws real-good)/default.json"
  run_case real-good default.json
  expect "the current default.json resolves" 0 "resolving default.json as renovate.json"

  sed 's/":semanticCommits"/":semanticCommitss"/' "${repo_dir}/default.json" \
    >"$(ws real-bad)/default.json"
  if ! grep -qF ':semanticCommitss' "${work}/ws-real-bad/default.json"; then
    echo "FAIL the mutation did not apply to default.json"
    exit 1
  fi
  run_case real-bad default.json
  expect "a misspelt preset fails" 1 "Cannot find preset's package (:semanticCommitss)"

  # The same misspelt preset with the temporary directory inside a git
  # work tree: renovate ignores the copy and runs onboarding.
  cp "${work}/ws-real-bad/default.json" "$(ws real-onboard)/default.json"
  mkdir -p "${work}/tmp-real-onboard"
  git -C "${work}/tmp-real-onboard" init -q
  run_case real-onboard default.json
  expect "a copy renovate does not read fails" 1 "must not be inside a git work tree"

  if [ "${failures}" -ne 0 ]; then
    echo "${failures} test(s) failed"
    exit 1
  fi
  echo "all tests passed"
  exit 0
fi

# The step runs only when "preset-files" is set, reads its list from that
# input and gets the workflow's own token for the preset lookup.
wiring_ok=1
for want in \
  "        if: inputs.preset-files != ''" \
  "          PRESET_FILES: \${{ inputs.preset-files }}" \
  "          GITHUB_COM_TOKEN: \${{ github.token }}"; do
  if ! grep -qxF -- "${want}" "${work}/wiring"; then
    echo "FAIL the step is wired to its input and token: lacks '${want}'"
    cat "${work}/wiring"
    failures=$((failures + 1))
    wiring_ok=0
  fi
done
if [ "${wiring_ok}" = "1" ]; then
  echo "PASS the step is wired to its input and token"
fi

# A resolving preset passes, runs in a directory of its own that holds
# only the copy, named renovate.json, with the same content.
echo '{"extends": ["config:recommended"]}' >"$(ws good)/default.json"
echo 'other' >"${work}/ws-good/renovate.json"
run_case good default.json
expect "a resolving preset passes" 0 "resolving default.json as renovate.json"
if ! grep -qx "files: renovate.json" "${work}/log-good"; then
  fail "a resolving preset passes" "renovate did not see only renovate.json"
  cat "${work}/log-good"
fi
if grep -qx "cwd: ${work}/ws-good" "${work}/log-good"; then
  fail "a resolving preset passes" "renovate ran in the checkout"
fi
if ! grep -qF '"config:recommended"' "${work}/log-good"; then
  fail "a resolving preset passes" "renovate did not see the preset's content"
fi
if ! grep -qx "args: --platform=local --config-validation-error" "${work}/log-good"; then
  fail "a resolving preset passes" "renovate got other arguments"
  cat "${work}/log-good"
fi
if [ -n "$(ls -A "${work}/tmp-good")" ]; then
  fail "a resolving preset passes" "the temporary directory was left behind"
fi

# An unresolvable preset fails the job and is named.
echo '{"extends": [":BAD"]}' >"$(ws bad)/default.json"
run_case bad default.json
expect "an unresolvable preset fails" 1 "preset file does not resolve: default.json (exit code 1)"

# Every file runs, also after a failing one, and the job still fails.
echo '{"extends": [":BAD"]}' >"$(ws two)/a.json"
echo '{}' >"${work}/ws-two/b.json"
run_case two $'a.json\nb.json'
expect "a failing first file fails the job" 1 "resolving b.json as renovate.json"
if [ "$(calls two)" != "2" ]; then
  fail "a failing first file fails the job" "renovate ran $(calls two) time(s), want 2"
fi

# The space-separated form splits too.
echo '{}' >"$(ws space)/a.json"
echo '{}' >"${work}/ws-space/b.json"
run_case space "a.json b.json"
expect "a space-separated list runs every file" 0 "resolving b.json as renovate.json"
if [ "$(calls space)" != "2" ]; then
  fail "a space-separated list runs every file" "renovate ran $(calls space) time(s), want 2"
fi

# A missing file fails the job without running renovate on it.
ws missing >/dev/null
run_case missing gone.json
expect "a missing file fails" 1 "preset file does not exist: gone.json"
if [ "$(calls missing)" != "0" ]; then
  fail "a missing file fails" "renovate ran"
fi

# JSON5 and JSONC keep their format.
echo '{}' >"$(ws json5)/p.json5"
run_case json5 p.json5
expect "a .json5 preset is copied as renovate.json5" 0 "resolving p.json5 as renovate.json5"
echo '{}' >"$(ws jsonc)/p.jsonc"
run_case jsonc p.jsonc
expect "a .jsonc preset is copied as renovate.jsonc" 0 "resolving p.jsonc as renovate.jsonc"

# Any other extension fails without running renovate.
echo '{}' >"$(ws yaml)/p.yaml"
run_case yaml p.yaml
expect "an unsupported extension fails" 1 "preset file is not .json, .json5 or .jsonc: p.yaml"
if [ "$(calls yaml)" != "0" ]; then
  fail "an unsupported extension fails" "renovate ran"
fi

# Renovate that does not read the copy runs onboarding and exits 0. The
# step must not take that for a pass.
echo '{"extends": [":ONBOARD"]}' >"$(ws onboard)/default.json"
run_case onboard default.json
expect "an onboarding run fails" 1 "must not be inside a git work tree"

# A value made only of whitespace names no file and fails.
ws blank >/dev/null
run_case blank $' \n\t '
expect "a blank input fails" 1 "the preset-files input names no file"
if [ "$(calls blank)" != "0" ]; then
  fail "a blank input fails" "renovate ran"
fi

# A file in a subdirectory is found relative to the checkout.
mkdir -p "$(ws sub)/presets"
echo '{}' >"${work}/ws-sub/presets/x.json"
run_case sub presets/x.json
expect "a preset in a subdirectory resolves" 0 "resolving presets/x.json as renovate.json"

# The shared preset migrates Go imports on a major update, for the gomod
# manager and for no other. PRESET_UNDER_TEST points the check at a copy.
preset="${PRESET_UNDER_TEST:-${repo_dir}/default.json}"
go_options='["gomodUpdateImportPaths","gomodTidy"]'

# Rules that name exactly the gomod manager and set both options.
gomod_rules="$(jq --argjson want "${go_options}" '
  [(.packageRules // [])[]
   | select(.matchManagers == ["gomod"]
            and ((.postUpdateOptions // []) | sort) == ($want | sort))]
  | length' "${preset}")"
if [ "${gomod_rules}" = "1" ]; then
  echo "PASS the gomod manager gets the Go import path options"
else
  echo "FAIL the gomod manager gets the Go import path options: ${gomod_rules} matching rule(s), want 1"
  failures=$((failures + 1))
fi

# Any other place that sets a Go option: the top level or another rule.
elsewhere="$(jq '
  [(if .postUpdateOptions then {rule: "top level", o: .postUpdateOptions} else empty end),
   ((.packageRules // [])[]
    | select(.postUpdateOptions and .matchManagers != ["gomod"])
    | {rule: "other", o: .postUpdateOptions})]
  | map(select(.o | any(startswith("gomod"))))
  | length' "${preset}")"
if [ "${elsewhere}" = "0" ]; then
  echo "PASS no other manager gets a Go option"
else
  echo "FAIL no other manager gets a Go option: ${elsewhere} other place(s) set one"
  failures=$((failures + 1))
fi

# The shared preset leaves out the mise pins that have no Renovate datasource
# result, for the mise manager and for those package names only.
mise_rules="$(jq '
  [(.packageRules // [])[]
   | select(.matchManagers == ["mise"]
            and ((.matchPackageNames // []) | sort) == ["conda:imagemagick", "imagemagick"]
            and .enabled == false)]
  | length' "${preset}")"
if [ "${mise_rules}" = "1" ]; then
  echo "PASS the mise manager skips the imagemagick lookup"
else
  echo "FAIL the mise manager skips the imagemagick lookup: ${mise_rules} matching rule(s), want 1"
  failures=$((failures + 1))
fi

# No other mise pin is disabled: every rule that disables something for the mise
# manager, or for every manager, must name packages, and only the two above.
mise_wide="$(jq '
  [(.packageRules // [])[]
   | select(.enabled == false
            and (((.matchManagers // []) | length) == 0 or ((.matchManagers // []) | index("mise")))
            and (((.matchPackageNames // []) | sort) != ["conda:imagemagick", "imagemagick"]))]
  | length' "${preset}")"
mise_global="$(jq '[select(.enabled == false)] | length' "${preset}")"
if [ "${mise_wide}" = "0" ] && [ "${mise_global}" = "0" ]; then
  echo "PASS no other mise package is disabled"
else
  echo "FAIL no other mise package is disabled: ${mise_wide} wide rule(s), ${mise_global} global"
  failures=$((failures + 1))
fi

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
