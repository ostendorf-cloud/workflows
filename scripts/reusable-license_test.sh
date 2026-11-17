#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the "Check license headers" step of
# .github/workflows/reusable-license.yaml. The step's own run block is cut
# out of the workflow file and executed, so the test cannot drift from what
# the workflow runs. addlicense is replaced by a stub that records its
# arguments and exits 0, like addlicense 1.2.0 does on a path that does not
# exist. Every case runs in a throwaway directory and touches nothing
# outside it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="${REUSABLE_LICENSE_WORKFLOW:-${script_dir}/../.github/workflows/reusable-license.yaml}"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/reusable-license.XXXXXXXX")"
trap 'rm -rf "${work}"' EXIT

# The run block of the step named "Check license headers", with its
# 10 space indentation removed.
awk '
  /^      - name: Check license headers$/ { in_step = 1; next }
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

mkdir -p "${work}/bin"
cat >"${work}/bin/addlicense" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_ARGS}"
exit 0
EOF
chmod +x "${work}/bin/addlicense"

failures=0

# run_case <name> <find-commands>: runs the step in a fresh workspace with
# a few files, leaves the exit code in "code", the output in "out" and the
# addlicense arguments, if any, in "${work}/args".
run_case() {
  local name="$1" commands="$2"
  local ws="${work}/ws-${name}"
  mkdir -p "${ws}/src" "${ws}/dir.go"
  : >"${ws}/src/a.go"
  : >"${ws}/src/b.go"
  : >"${ws}/-dash.go"
  rm -f "${work}/args"
  code=0
  out="$(cd "${ws}" &&
    PATH="${work}/bin:${PATH}" STUB_ARGS="${work}/args" \
      COPYRIGHT_HOLDER=Test YEAR=2026 LICENSE_TYPE=apache FIND_COMMANDS="${commands}" \
      bash -e "${work}/step.sh" 2>&1)" || code=$?
}

expect() {
  local name="$1" want_code="$2" want_text="$3"
  if [ "${code}" != "${want_code}" ]; then
    echo "FAIL ${name}: exit code = ${code}, want ${want_code}"
    echo "${out}"
    failures=$((failures + 1))
  elif ! grep -qF -- "${want_text}" <<<"${out}"; then
    echo "FAIL ${name}: output lacks '${want_text}'"
    echo "${out}"
    failures=$((failures + 1))
  else
    echo "PASS ${name}"
  fi
}

expect_absent() {
  local name="$1" text="$2"
  if grep -qF -- "${text}" <<<"${out}"; then
    echo "FAIL ${name}: output holds '${text}'"
    echo "${out}"
    failures=$((failures + 1))
  fi
}

# expect_ws_file <name> <file>: the file exists in the case's workspace.
expect_ws_file() {
  if [ ! -e "${work}/ws-$1/$2" ]; then
    echo "FAIL $1: $2 was not created, so its command did not run"
    failures=$((failures + 1))
  fi
}

expect_not_called() {
  if [ -e "${work}/args" ]; then
    echo "FAIL $1: addlicense was called"
    failures=$((failures + 1))
  fi
}

run_case ok $'find src -name \'*.go\''
expect "files are passed and counted" 0 "passing 2 file(s) to addlicense"
if ! grep -qx "src/a.go" "${work}/args"; then
  echo "FAIL files are passed and counted: addlicense got no src/a.go"
  failures=$((failures + 1))
fi

run_case two $'find src -name a.go\nfind src -name b.go'
expect "several commands are united" 0 "passing 2 file(s) to addlicense"

# Case 1: a command that exits non zero fails the job, even when it
# printed paths first, and addlicense never runs.
run_case failing $'echo src/a.go; exit 3'
expect "a failing command fails the job" 1 "find command failed with exit status 3"
expect_not_called "a failing command fails the job"

# The first failing command does not stop the later ones: both run, both
# are reported, the job fails.
run_case both $'touch ran1; exit 1\ntouch ran2; echo src/a.go'
expect "a failing first command fails the job" 1 "at least one find command failed"
expect_ws_file both ran1
expect_ws_file both ran2
expect_not_called "a failing first command fails the job"

# A successful command after a failing one is not reported as failed: the
# status is reset for every command.
run_case reset $'exit 3\nfind src -name a.go'
expect "a later success is not reported" 1 "find command failed with exit status 3: exit 3"
if [ "$(grep -c "find command failed with exit status" <<<"${out}")" != "1" ]; then
  echo "FAIL a later success is not reported: more than one command reported"
  echo "${out}"
  failures=$((failures + 1))
fi

# A failing command with a valid file list fails on the command, not on
# the path check.
run_case failmsg $'echo src/a.go; exit 3'
expect "a failing command is named as such" 1 "at least one find command failed"
expect_absent "a failing command is named as such" "not a regular file"

# The real shape of the govue command: a loop whose own status is the
# status of its last command, an echo. The mkdir fails because its parent
# is a file, which holds as root too. Every printed path exists, so only
# "set -e" can catch it.
run_case loop $': >blocker; find src -name \'*.go\' | while read -r f; do mkdir -p blocker/x; cp "${f}" blocker/x/; echo "${f}"; done'
expect "a failing step inside a loop fails the job" 1 "find command failed with exit status"
expect_not_called "a failing step inside a loop fails the job"

# A path starting with a dash reaches addlicense after "--".
run_case dash $'printf \'%s\\n\' -dash.go'
expect "a path starting with a dash is passed" 0 "passing 1 file(s) to addlicense"
if [ "$(grep -nx -e '--' "${work}/args" | cut -d: -f1)" != "$(($(grep -nx -e '-dash.go' "${work}/args" | cut -d: -f1) - 1))" ]; then
  echo "FAIL a path starting with a dash is passed: no -- right before -dash.go"
  cat "${work}/args"
  failures=$((failures + 1))
fi

run_case pipefail $'false | cat'
expect "a failing pipeline stage fails the job" 1 "find command failed with exit status 1"

run_case later $'find src -name a.go\nfind /nonexistent-dir-for-test'
expect "a later failing command fails the job" 1 "find command failed"
expect_not_called "a later failing command fails the job"

# Case 2: a listed path that is not a regular file fails the job and is
# named, and addlicense never runs.
run_case missing $'echo src/gone.go'
expect "a missing path fails the job" 1 "not a regular file: src/gone.go"
expect_not_called "a missing path fails the job"

run_case directory $'echo dir.go'
expect "a directory fails the job" 1 "not a regular file: dir.go"
expect_not_called "a directory fails the job"

# Case 3: the job logs the number of files it passes. An empty result
# keeps its own failure.
run_case none $'true'
expect "no match keeps its failure" 1 "no files matched any of the configured find-commands"

# A command may create the files it prints, as the govue pull request 129
# command does for .mts files.
copy_dir="${work}/mts"
run_case copy "mkdir -p ${copy_dir} && echo 'x' >${copy_dir}/m.ts && echo ${copy_dir}/m.ts"
expect "a command may create the files it prints" 0 "passing 1 file(s) to addlicense"

# A command that reads stdin must not eat the remaining command lines.
run_case stdin $'cat >/dev/null\nfind src -name a.go'
expect "a command cannot consume the command list" 0 "passing 1 file(s) to addlicense"

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
