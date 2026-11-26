#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the "lint:agents-md" task in Taskfile.yaml. The real task runs
# through a local include with "flatten: true", from a throwaway directory
# that holds the fixtures, so the test also proves the task checks the
# caller's directory and not the directory of the included Taskfile. The
# fixture files are generated, one line per number. A last step breaks the
# comparison in a copy of the Taskfile and requires this suite to fail on
# it, so a check that passes everything cannot go unnoticed.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
taskfile="${LINT_AGENTS_MD_TASKFILE:-${script_dir}/../Taskfile.yaml}"
taskfile="$(cd "$(dirname "${taskfile}")" && pwd)/$(basename "${taskfile}")"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/lint-agents-md.XXXXXXXX")"
trap 'rm -rf "${work}"' EXIT

# lines <n> <file>: a file of exactly n lines, parent directories created.
lines() {
  mkdir -p "$(dirname "$2")"
  seq "$1" >"$2"
}

# lines_nonl <n> <file>: like lines, but the last line has no newline.
lines_nonl() {
  mkdir -p "$(dirname "$2")"
  seq "$1" | awk '{ printf "%s%s", sep, $0; sep = "\n" }' >"$2"
}

# suite <label> <taskfile>: runs every case against the given Taskfile and
# adds the failed cases to "failures".
failures=0
suite() {
  local label="$1" tf="$2" n=0
  local ws code out

  # check <name> <want_code> <want_text|""> <env and task args...>: runs the
  # task in the current fixture directory.
  check() {
    local name="$1" want_code="$2" want_text="$3"
    shift 3
    n=$((n + 1))
    code=0
    out="$(cd "${ws}" && env "$@" task lint:agents-md 2>&1)" || code=$?
    # Task maps a failing command to its own exit code, so a failure is any
    # non zero code, passed as "1".
    if { [ "${want_code}" = 0 ] && [ "${code}" != 0 ]; } ||
      { [ "${want_code}" != 0 ] && [ "${code}" = 0 ]; }; then
      echo "FAIL ${label} ${name}: exit code = ${code}, want ${want_code}"
      echo "${out}"
      failures=$((failures + 1))
    elif [ -n "${want_text}" ] && ! grep -qF -- "${want_text}" <<<"${out}"; then
      echo "FAIL ${label} ${name}: output lacks '${want_text}'"
      echo "${out}"
      failures=$((failures + 1))
    elif [ -z "${want_text}" ] && grep -qE '^(warning|error):' <<<"${out}"; then
      echo "FAIL ${label} ${name}: unexpected finding"
      echo "${out}"
      failures=$((failures + 1))
    else
      echo "PASS ${label} ${name}"
    fi
  }

  # fixture <case>: an empty caller directory that includes the Taskfile
  # under test.
  fixture() {
    ws="${work}/${label}-$1"
    mkdir -p "${ws}"
    cat >"${ws}/Taskfile.yaml" <<EOF
version: "3"
includes:
  shared:
    taskfile: ${tf}
    flatten: true
EOF
  }

  # Root file: under, at and over the default limit of 150.
  fixture root-under
  lines 149 "${ws}/AGENTS.md"
  check "root under the limit" 0 "" MODE=fail
  fixture root-at
  lines 150 "${ws}/AGENTS.md"
  check "root at the limit" 0 "" MODE=fail
  fixture root-over
  lines 151 "${ws}/AGENTS.md"
  check "root over the limit fails in fail mode" 1 "error: ./AGENTS.md has 151 lines, the limit is 150" MODE=fail
  check "root over the limit warns by default" 0 "warning: ./AGENTS.md has 151 lines, the limit is 150"
  check "root over the limit warns in warn mode" 0 "warning: ./AGENTS.md has 151 lines" MODE=warn

  # Nested file: under, at and over the default limit of 100.
  fixture nested-under
  lines 10 "${ws}/AGENTS.md"
  lines 99 "${ws}/sub/AGENTS.md"
  check "nested under the limit" 0 "" MODE=fail
  fixture nested-at
  lines 10 "${ws}/AGENTS.md"
  lines 100 "${ws}/sub/dir/AGENTS.md"
  check "nested at the limit" 0 "" MODE=fail
  fixture nested-over
  lines 10 "${ws}/AGENTS.md"
  lines 101 "${ws}/sub/AGENTS.md"
  check "nested over the limit fails in fail mode" 1 "error: ./sub/AGENTS.md has 101 lines, the limit is 100" MODE=fail
  check "nested over the limit warns by default" 0 "warning: ./sub/AGENTS.md has 101 lines, the limit is 100"

  # A nested file may hold up to the nested limit, not the root limit.
  fixture nested-not-root
  lines 120 "${ws}/sub/AGENTS.md"
  check "a nested file does not get the root limit" 1 "limit is 100" MODE=fail

  # The root limit does not apply to a nested file in the other direction.
  fixture root-not-nested
  lines 120 "${ws}/AGENTS.md"
  check "the root file does not get the nested limit" 0 "" MODE=fail

  # Limits from the environment and from CLI variables.
  fixture custom
  lines 30 "${ws}/AGENTS.md"
  lines 20 "${ws}/sub/AGENTS.md"
  check "ROOT_LIMIT from the environment" 1 "the limit is 29" MODE=fail ROOT_LIMIT=29 NESTED_LIMIT=20
  check "NESTED_LIMIT from the environment" 1 "the limit is 19" MODE=fail ROOT_LIMIT=30 NESTED_LIMIT=19
  check "limits at the lines pass" 0 "" MODE=fail ROOT_LIMIT=30 NESTED_LIMIT=20
  code=0
  out="$(cd "${ws}" && task lint:agents-md MODE=fail ROOT_LIMIT=29 2>&1)" || code=$?
  if [ "${code}" = 0 ] || ! grep -qF "the limit is 29" <<<"${out}"; then
    echo "FAIL ${label} limits from CLI variables: exit code = ${code}"
    echo "${out}"
    failures=$((failures + 1))
  else
    echo "PASS ${label} limits from CLI variables"
  fi

  # Skipped trees hold huge files that must not count.
  fixture skipped
  lines 10 "${ws}/AGENTS.md"
  lines 500 "${ws}/node_modules/pkg/AGENTS.md"
  lines 500 "${ws}/.git/AGENTS.md"
  lines 500 "${ws}/.claude/worktrees/x/AGENTS.md"
  lines 500 "${ws}/vendor/lib/AGENTS.md"
  check "node_modules, .git, worktrees and vendor are skipped" 0 "" MODE=fail

  # A last line without a trailing newline still counts.
  fixture nonl-at
  lines_nonl 150 "${ws}/AGENTS.md"
  lines_nonl 100 "${ws}/sub/AGENTS.md"
  check "files at the limit without a final newline pass" 0 "" MODE=fail
  fixture nonl-over
  lines_nonl 151 "${ws}/AGENTS.md"
  check "a root file over the limit without a final newline fails" 1 "./AGENTS.md has 151 lines" MODE=fail
  fixture nonl-over-nested
  lines_nonl 101 "${ws}/sub/AGENTS.md"
  check "a nested file over the limit without a final newline fails" 1 "./sub/AGENTS.md has 101 lines" MODE=fail

  # A directory name with a space.
  fixture space
  lines 10 "${ws}/AGENTS.md"
  lines 101 "${ws}/my docs/AGENTS.md"
  check "a directory with a space is checked" 1 "./my docs/AGENTS.md has 101 lines" MODE=fail
  fixture space-ok
  lines 100 "${ws}/my docs/AGENTS.md"
  check "a directory with a space at the limit passes" 0 "" MODE=fail

  # No AGENTS.md at all is not a failure.
  fixture none
  check "no AGENTS.md passes" 0 "" MODE=fail

  # Both findings are reported, not only the first.
  fixture both
  lines 200 "${ws}/AGENTS.md"
  lines 200 "${ws}/a/AGENTS.md"
  check "every finding is reported" 1 "./a/AGENTS.md has 200 lines" MODE=fail
  check "the root finding is reported too" 1 "./AGENTS.md has 200 lines" MODE=fail
}

suite real "${taskfile}"
real_failures="${failures}"

# Mutation: an off by one in the comparison must make the suite fail. The
# mutated copy is only used here, and its failures are not counted.
mutated="${work}/mutated.yaml"
from="-gt \"\$limit\""
to="-ge \"\$limit\""
content="$(<"${taskfile}")"
printf '%s\n' "${content//"${from}"/"${to}"}" >"${mutated}"
if cmp -s "${taskfile}" "${mutated}"; then
  echo "FAIL mutation: the comparison to mutate was not found in ${taskfile}"
  failures=$((failures + 1))
else
  failures=0
  suite mutant "${mutated}" >"${work}/mutant.log" 2>&1 || true
  if [ "${failures}" -eq 0 ]; then
    echo "FAIL mutation: the suite passes with a broken comparison"
    real_failures=$((real_failures + 1))
  else
    echo "PASS mutation: the suite fails with a broken comparison"
  fi
  failures="${real_failures}"
fi

if [ "${failures}" -ne 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi

echo "all tests passed"
