#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the "Check the triggering event" step of
# .github/workflows/reusable-renovate.yaml, the guard that lets a
# "workflow_run" event start Renovate only for a successful run of a
# "renovate/" branch of the same repository. The step's own run block is cut
# out of the workflow file and executed, so the test cannot drift from what
# the workflow runs. Every case runs in a throwaway directory and touches
# nothing outside it. The injection cases check that a crafted branch name
# is never executed. REUSABLE_RENOVATE_WORKFLOW points the test at another
# copy of the workflow, which is how the mutations of the pull request were
# run.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${script_dir}/.."
workflow="${REUSABLE_RENOVATE_WORKFLOW:-${repo_dir}/.github/workflows/reusable-renovate.yaml}"
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work="$(mktemp -d "${TMPDIR:-/tmp}/reusable-renovate-guard.XXXXXXXX")"
trap 'rm -rf "${work}"' EXIT

step_name="Check the triggering event"

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

# The step's lines before its run block, without comments.
awk -v name="      - name: ${step_name}" '
  $0 == name { in_step = 1; next }
  in_step && /^        run: \|$/ { exit }
  in_step && /^ *#/ { next }
  in_step { print }
' "${workflow}" >"${work}/wiring"

failures=0

fail() {
  echo "FAIL $1: $2"
  failures=$((failures + 1))
}

# run_case <event> <conclusion> <branch> <head repository> <repository>:
# runs the step with these values. Leaves the exit code in "code", the
# printed text in "out" and the value of the "run" output in "result",
# empty when the step wrote no output line. The case runs in an empty
# directory, so a command that a crafted value runs and that creates a file
# shows up in "${work}/case".
run_case() {
  local event="$1" conclusion="$2" branch="$3" head_repo="$4" repo="$5"
  rm -rf "${work}/case"
  mkdir "${work}/case"
  : >"${work}/output"
  code=0
  out="$(cd "${work}/case" && env -i PATH="${PATH}" \
    GITHUB_OUTPUT="${work}/output" EVENT_NAME="${event}" \
    RUN_CONCLUSION="${conclusion}" RUN_HEAD_BRANCH="${branch}" \
    RUN_HEAD_REPOSITORY="${head_repo}" REPOSITORY="${repo}" \
    bash -e "${work}/step.sh" 2>&1)" || code=$?
  result="$(sed -n 's/^run=//p' "${work}/output")"
}

# expect <description> <run|skip>: the step exited 0, wrote exactly one
# output line and it is the wanted one, printed no branch text and created
# no file.
expect() {
  local what="$1" want="$2" want_value=false
  [ "${want}" = "run" ] && want_value=true
  if [ "${code}" != "0" ]; then
    fail "${what}" "exit code = ${code}, want 0"
    echo "${out}"
  elif [ "${result}" != "${want_value}" ]; then
    fail "${what}" "run output = '${result}', want '${want_value}'"
  elif [ "$(wc -l <"${work}/output" | tr -d ' ')" != "1" ]; then
    fail "${what}" "the step wrote other than exactly one output line"
  elif [ -n "$(ls -A "${work}/case")" ]; then
    fail "${what}" "the step created a file: $(ls -A "${work}/case")"
  elif [ "${out}" != "guard: run=${want_value}" ]; then
    fail "${what}" "unexpected printed text: ${out}"
  else
    echo "PASS ${what}"
  fi
}

repo="ostendorf-cloud/skills"
good_branch="renovate/npm-renovate-44.x"

# Events that always run. Their workflow_run fields are empty.
run_case schedule "" "" "" "${repo}"
expect "schedule runs" run
run_case workflow_dispatch "" "" "" "${repo}"
expect "workflow_dispatch runs" run
run_case issues "" "" "" "${repo}"
expect "an issues event runs, the job if decides" run
run_case pull_request "" "" "" "${repo}"
expect "a pull_request event runs, the job if decides" run

# Events outside the allow list never run.
for event in push pull_request_target workflow_call repository_dispatch "" "workflow_run "; do
  run_case "${event}" success "${good_branch}" "${repo}" "${repo}"
  expect "the event '${event}' is skipped" skip
done

# The accepted workflow_run.
run_case workflow_run success "${good_branch}" "${repo}" "${repo}"
expect "a successful renovate branch of the same repository runs" run
run_case workflow_run success "renovate/actions-checkout-5.x" "${repo}" "${repo}"
expect "another renovate branch runs" run
run_case workflow_run success "renovate/major-6.x-lockfile_maintenance+x@y" "${repo}" "${repo}"
expect "a branch with dots, plus and at signs runs" run
run_case workflow_run success "renovate/a/b/c" "${repo}" "${repo}"
expect "a nested renovate branch runs" run

# Branches that must not run.
for branch in main master "feature/renovate/x" "renovate" "renovate/" "Renovate/x" "RENOVATE/x" \
  "renovate-x" "xrenovate/x" " renovate/x" "renovate/x " "renovate\\x" "/renovate/x" \
  "refs/heads/renovate/x" "renovate/x y" ""; do
  run_case workflow_run success "${branch}" "${repo}" "${repo}"
  expect "the branch '${branch}' is skipped" skip
done

# A branch with a newline or shell metacharacters is skipped and never
# executed. A command that ran would create a file in the case directory.
# The single quotes are the point: these are literal attack strings.
# shellcheck disable=SC2016
for branch in \
  $'renovate/x\nmain' $'renovate/x\n' $'\nrenovate/x' $'renovate/x\nrun=true' \
  'renovate/$(touch pwned)' 'renovate/`touch pwned`' 'renovate/x;touch pwned' \
  'renovate/x&&touch pwned' 'renovate/x|touch pwned' 'renovate/x>pwned' \
  'renovate/${IFS}x' "renovate/x'" 'renovate/x"' 'renovate/*' 'renovate/x#' \
  'renovate/$(touch pwned)/x' 'renovate/x::set-output name=run::true' \
  $'renovate/x\r' $'renovate/x\t'; do
  run_case workflow_run success "${branch}" "${repo}" "${repo}"
  expect "the crafted branch '${branch//$'\n'/\\n}' is skipped and not executed" skip
done

# A workflow_run of another conclusion, another head repository or no
# data is skipped.
for conclusion in failure cancelled skipped timed_out action_required neutral stale startup_failure \
  Success SUCCESS "success " " success" ""; do
  run_case workflow_run "${conclusion}" "${good_branch}" "${repo}" "${repo}"
  expect "the conclusion '${conclusion}' is skipped" skip
done
run_case workflow_run success "${good_branch}" "owner/other" "${repo}"
expect "a fork named owner/other is skipped" skip
run_case workflow_run success "${good_branch}" "ostendorf-cloud/skills-fork" "${repo}"
expect "another repository with a longer name is skipped" skip
run_case workflow_run success "${good_branch}" "other/skills" "${repo}"
expect "another owner with the same name is skipped" skip
run_case workflow_run success "${good_branch}" "" "${repo}"
expect "an empty head repository is skipped" skip
run_case workflow_run success "${good_branch}" "" ""
expect "an empty head repository and an empty repository are skipped" skip
run_case workflow_run success "${good_branch}" "${repo}" ""
expect "an empty repository is skipped" skip
run_case workflow_run success "${good_branch}" "${repo}" "ostendorf-cloud/other"
expect "a head repository that is not the repository is skipped" skip
run_case workflow_run "" "" "" "" ""
expect "a workflow_run with no data is skipped" skip

# The step has no variable set at all, as on an event that has no
# workflow_run object: it still ends cleanly with run=false.
: >"${work}/output"
code=0
(cd "${work}" && env -i PATH="${PATH}" GITHUB_OUTPUT="${work}/output" EVENT_NAME=workflow_run \
  bash -e "${work}/step.sh" >/dev/null 2>&1) || code=$?
if [ "${code}" = "0" ] && [ "$(cat "${work}/output")" = "run=false" ]; then
  echo "PASS unset variables on a workflow_run are skipped"
else
  fail "unset variables on a workflow_run are skipped" "exit code ${code}, output $(cat "${work}/output")"
fi

# The step is wired to exactly these variables and nothing else.
want_wiring="        id: guard
        env:
          EVENT_NAME: \${{ github.event_name }}
          REPOSITORY: \${{ github.repository }}
          RUN_CONCLUSION: \${{ github.event.workflow_run.conclusion }}
          RUN_HEAD_BRANCH: \${{ github.event.workflow_run.head_branch }}
          RUN_HEAD_REPOSITORY: \${{ github.event.workflow_run.head_repository.full_name }}"
if [ "$(cat "${work}/wiring")" != "${want_wiring}" ]; then
  fail "the step is wired to the five variables and nothing else" "got:"$'\n'"$(cat "${work}/wiring")"
else
  echo "PASS the step is wired to the five variables and nothing else"
fi

# No expression text inside the run block: GitHub would paste it into the
# script before bash reads it.
if grep -qF "\${{" "${work}/step.sh"; then
  fail "the run block holds no expression" "found '\${{' in the run block"
else
  echo "PASS the run block holds no expression"
fi

# Nothing prints a variable, so a crafted value cannot forge a workflow
# command in the log. Only the fixed "guard: run=" line is printed.
if grep -nE 'echo|printf' "${work}/step.sh" | grep -vE 'echo "guard: run=\$\{run\}"$|echo "run=\$\{run\}" >>"\$\{GITHUB_OUTPUT\}"$'; then
  fail "the step prints only the fixed lines" "another echo or printf in the run block"
else
  echo "PASS the step prints only the fixed lines"
fi

# The step is the first step of the job, before the checkout and the token.
first_step="$(awk '/^    steps:$/ { s = 1; next } s && /^      - / { print; exit }' "${workflow}")"
if [ "${first_step}" != "      - name: ${step_name}" ]; then
  fail "the guard is the first step" "the first step is '${first_step}'"
else
  echo "PASS the guard is the first step"
fi

# Every other step runs only when the guard said so. Counted per step
# header, comments skipped.
other_steps="$(grep -cE '^      - ' "${workflow}")"
gated="$(grep -v '^ *#' "${workflow}" | grep -cE "^        if: steps\.guard\.outputs\.run == 'true'$" || true)"
if [ "${other_steps}" != "$((gated + 1))" ]; then
  fail "every step after the guard is gated" "${other_steps} steps, ${gated} gated, want all but the guard"
else
  echo "PASS every step after the guard is gated"
fi

# No gated step may run on failure or always, and none may continue on error.
if grep -v '^ *#' "${workflow}" | grep -nE 'continue-on-error|always\(\)|failure\(\)|cancelled\(\)'; then
  fail "no step overrides the gate" "found continue-on-error or a status function"
else
  echo "PASS no step overrides the gate"
fi

# The job "if:" carries the same condition, case insensitive on its own,
# so the step is the exact one. Every piece must be present, once.
job_if="$(awk '
  /^    if: >-$/ { in_if = 1; next }
  in_if && /^    [a-z]/ { exit }
  in_if && /^ *#/ { next }
  in_if { print }
' "${workflow}")"
for piece in \
  "github.event.workflow_run.conclusion == 'success'" \
  "github.event.workflow_run.head_repository.full_name == github.repository" \
  "startsWith(github.event.workflow_run.head_branch, 'renovate/')" \
  "github.event_name == 'workflow_run' &&" \
  "github.event_name != 'workflow_run' &&" \
  "github.event_name == 'schedule'" \
  "github.event_name == 'workflow_dispatch'"; do
  if [ "$(grep -cF -- "${piece}" <<<"${job_if}")" != "1" ]; then
    fail "the job if holds '${piece}' once" "missing or repeated"
  else
    echo "PASS the job if holds '${piece}' once"
  fi
done

# The old anti-loop clause still guards the edited events, and the head
# branch text appears in no run block other than through the variable.
if ! grep -qF "github.event.sender.login != 'ostendorf-cloud-dependencies[bot]'" <<<"${job_if}"; then
  fail "the anti-loop clause stays" "the sender check is gone"
else
  echo "PASS the anti-loop clause stays"
fi
if grep -v '^ *#' "${workflow}" | grep -nE 'workflow_run\.(head|pull|display)' | grep -vE '^[0-9]+:\s+(RUN_HEAD_[A-Z_]+: \$\{\{|startsWith\(|github\.event\.workflow_run\.head_repository\.full_name == github\.repository)'; then
  fail "workflow_run head fields are used only as variables or in the job if" "found another use"
else
  echo "PASS workflow_run head fields are used only as variables or in the job if"
fi

# The workflow never checks out the head of the triggering run.
if grep -v '^ *#' "${workflow}" | grep -nE 'head_sha|head_branch.*ref:|ref: .*workflow_run'; then
  fail "no checkout of the triggering run" "found a ref taken from the workflow_run"
else
  echo "PASS no checkout of the triggering run"
fi

# The header documents the event, as AGENTS.md requires for a contract.
if ! sed -n '1,/^on:$/p' "${workflow}" | grep -q '^# Run after the checks:$'; then
  fail "the header documents the workflow_run trigger" "no '# Run after the checks:' line above 'on:'"
else
  echo "PASS the header documents the workflow_run trigger"
fi

# The concurrency group still serialises every run of the repository.
if ! grep -qE '^      group: \$\{\{ github.workflow \}\}$' "${workflow}" ||
  ! grep -qE '^      cancel-in-progress: false$' "${workflow}"; then
  fail "one Renovate run at a time" "the concurrency group or cancel-in-progress changed"
else
  echo "PASS one Renovate run at a time"
fi

if [ "${failures}" -gt 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "all passed"
