#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for .github/actions/pnpm-release-age-comment/release-age-comment.sh and for the
# install step of the caller snippet in README.md. A stub gh first on PATH records every
# call and prints a fixture comment list for the list call, or applies a --jq expression
# to it with the real jq, so no network is used. A jq wrapper first on PATH records every
# argument of each jq call and then runs the real jq.
#
# Environment: RELEASE_AGE_SCRIPT and RELEASE_AGE_README override the files under test.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=${RELEASE_AGE_SCRIPT:-$here/../.github/actions/pnpm-release-age-comment/release-age-comment.sh}
readme=${RELEASE_AGE_README:-$here/../README.md}
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work=$(mktemp -d "${TMPDIR:-/tmp}/pnpm-release-age-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

REAL_JQ=$(command -v jq)
export REAL_JQ

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/calls"
expr=
prev=
for a in "$@"; do
  case $a in
    body=@*) cat "${a#body=@}" >"$STUB_DIR/body" ;;
  esac
  if [[ $prev == --jq ]]; then
    expr=$a
  fi
  prev=$a
done
if [[ -n $expr ]]; then
  printf '%s\n' "$expr" >>"$STUB_DIR/jq_args"
  if [[ -f $STUB_DIR/comments.json ]]; then
    "$REAL_JQ" -r "$expr" "$STUB_DIR/comments.json"
  fi
elif [[ $* == *--paginate* ]]; then
  # gh prints each page as a JSON array of its own: two pages show that the filter reads
  # a stream of arrays.
  if [[ -f $STUB_DIR/comments.json ]]; then
    "$REAL_JQ" -c '.[:1]' "$STUB_DIR/comments.json"
    "$REAL_JQ" -c '.[1:]' "$STUB_DIR/comments.json"
  else
    printf '[]\n'
  fi
fi
exit 0
STUB
chmod +x "$work/bin/gh"

cat >"$work/bin/jq" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$STUB_DIR/jq_args"
exec "$REAL_JQ" "$@"
STUB
chmod +x "$work/bin/jq"

fails=0
checks=0

assert() {
  checks=$((checks + 1))
  if ! "$@"; then
    fails=$((fails + 1))
    printf 'FAIL: %s\n' "$*" >&2
  fi
}

no_calls() { [[ ! -e $STUB_DIR/calls ]]; }
no_patch() { ! grep -qF 'PATCH' "$STUB_DIR/calls"; }
no_post() { ! grep -qF 'POST' "$STUB_DIR/calls"; }
body_has() { grep -qF -- "$1" "$STUB_DIR/body"; }
body_lacks() { ! grep -qF -- "$1" "$STUB_DIR/body"; }
call_count() { wc -l <"$STUB_DIR/calls" | tr -d ' '; }

# run_case LOG_CONTENT [COMMENTS_JSON]: runs the script on a fresh stub state. COMMENT_AUTHOR
# reaches the script only when CASE_AUTHOR is set, and stderr lands in $STUB_DIR/stderr.
run_case() {
  STUB_DIR=$(mktemp -d "$work/case.XXXXXX")
  export STUB_DIR
  printf '%b' "$1" >"$STUB_DIR/install.log"
  if [[ -n ${2:-} ]]; then
    printf '%s' "$2" >"$STUB_DIR/comments.json"
  fi
  (
    unset COMMENT_AUTHOR
    if [[ -n ${CASE_AUTHOR+set} ]]; then
      export COMMENT_AUTHOR=$CASE_AUTHOR
    fi
    PATH="$work/bin:$PATH" REPO=o/r PR=7 GH_TOKEN=fake-token-for-tests GITHUB_SERVER_URL=https://github.com \
      GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=99 \
      bash "$script" "$STUB_DIR/install.log" 2>"$STUB_DIR/stderr"
  )
  status=$?
}

marker='<!-- pnpm-release-age -->'
list_call='api --paginate repos/o/r/issues/7/comments'

# 1. The real pnpm 12 failure of a pull request, no earlier comment: list, then one POST.
real_log='Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION

  × installing dependencies
  ╰─▶ 1 lockfile entries failed verification:
        ignore@7.0.16 was published at 2026-11-17T05:56:55.170Z, within the
      minimumReleaseAge cutoff (2026-11-16T23:05:09.237Z)
  help: The lockfile contains entries that the active policies reject. This
        can mean the lockfile is stale, or that someone committed a lockfile
        that bypassed the policy locally ...
'
run_case "WARN something first
$real_log"
assert test "$status" -eq 0
assert test "$(call_count)" -eq 2
assert grep -qF 'api -X POST repos/o/r/issues/7/comments -F body=@' "$STUB_DIR/calls"
assert test "$(head -n 1 "$STUB_DIR/body")" = "$marker"
assert body_has "The dependency install failed because a locked package is younger than pnpm's minimumReleaseAge."
assert body_has "- \`ignore@7.0.16\`, published at \`2026-11-17T05:56:55.170Z\`"
assert body_has "Cutoff of the failed run: \`2026-11-16T23:05:09.237Z\`"
assert body_has 'published before the cutoff of that run'
assert body_has 'Rerun the failed jobs'
assert body_has 'No change in the repository is needed'
# The policy age is not claimed anywhere, it differs per repository.
assert body_lacks 'one day'
assert body_lacks 'default'
# The comment points at its run and says it goes stale.
assert body_has 'Run: https://github.com/o/r/actions/runs/99'
assert body_has 'This comment belongs to that run. If a later run passes, ignore it.'

# 2. Two entries, one scoped, behind colour codes: every entry is listed once.
run_case '\033[31mError: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\033[39m
  ╰─▶ 2 lockfile entries failed verification:
        \033[1mignore@7.0.16\033[22m was published at 2026-11-17T05:56:55.170Z, within the
      minimumReleaseAge cutoff (2026-11-16T23:05:09.237Z)
        @vue/shared@3.5.1-beta.2 was published at 2026-11-17T06:00:00.000Z, within the
      minimumReleaseAge cutoff (2026-11-16T23:05:09.237Z)
'
assert body_has "- \`ignore@7.0.16\`, published at \`2026-11-17T05:56:55.170Z\`"
assert body_has "- \`@vue/shared@3.5.1-beta.2\`, published at \`2026-11-17T06:00:00.000Z\`"
assert test "$(grep -c '^- ' "$STUB_DIR/body")" -eq 2
assert test "$(grep -c 'Cutoff of the failed run' "$STUB_DIR/body")" -eq 1

# 3. Error code, no entry in the log: the comment is still written, without a list.
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION something unparseable\n'
assert test "$(call_count)" -eq 2
assert body_has 'minimumReleaseAge'
assert body_lacks 'Packages refused'
assert body_lacks 'Cutoff of the failed run'

# 4. An entry before the error code is not read.
run_case 'old@1.0.0 was published at 2026-01-01T00:00:00.000Z\nError: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n'
assert body_lacks 'old@1.0.0'

# 5. An earlier comment of the bot exists: PATCH that comment, never a second POST.
bot='{"id":4242,"user":{"login":"github-actions[bot]"},"body":"<!-- pnpm-release-age -->\\nold"}'
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION a@1.0.0\n' "[$bot]"
assert grep -qF 'api -X PATCH repos/o/r/issues/comments/4242 -F body=@' "$STUB_DIR/calls"
assert no_post
assert test "$(call_count)" -eq 2

# 6. The list call asks for the comments of the pull request.
assert grep -qxF "$list_call" "$STUB_DIR/calls"

# 7. Several comments: a human copy of the marker and a bot comment without it are never
# touched, and the oldest of two bot comments with the marker is the one updated.
human='{"id":1,"user":{"login":"someone"},"body":"<!-- pnpm-release-age -->\\ncopied"}'
other='{"id":2,"user":{"login":"github-actions[bot]"},"body":"a different bot comment"}'
older='{"id":3,"user":{"login":"github-actions[bot]"},"body":"<!-- pnpm-release-age -->\\nfirst"}'
newer='{"id":4,"user":{"login":"github-actions[bot]"},"body":"<!-- pnpm-release-age -->\\nsecond"}'
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION a@1.0.0\n' "[$human,$other,$older,$newer]"
assert grep -qF 'api -X PATCH repos/o/r/issues/comments/3 -F body=@' "$STUB_DIR/calls"
assert test "$(call_count)" -eq 2
# Only a human copy and an unrelated bot comment: a new comment is posted.
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION a@1.0.0\n' "[$human,$other]"
assert grep -qF 'api -X POST repos/o/r/issues/7/comments -F body=@' "$STUB_DIR/calls"
assert no_patch
# A bot comment must start with the marker. One that carries it later, for example a
# quote, is never edited.
middle='{"id":5,"user":{"login":"github-actions[bot]"},"body":"quoted: <!-- pnpm-release-age -->\\nold"}'
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION a@1.0.0\n' "[$middle]"
assert grep -qF 'api -X POST repos/o/r/issues/7/comments -F body=@' "$STUB_DIR/calls"
assert no_patch

# 7b. COMMENT_AUTHOR names the author of the earlier comment, for example a GitHub App.
# Only a comment of that author that starts with the marker is updated. A comment of
# github-actions[bot], a human comment and a user named like the app, each with the
# marker, are never edited.
fail_log='Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION a@1.0.0\n'
app='ostendorf-cloud-dependencies[bot]'
app_old='{"id":8,"user":{"login":"ostendorf-cloud-dependencies[bot]"},"body":"<!-- pnpm-release-age -->\\nfirst"}'
app_new='{"id":9,"user":{"login":"ostendorf-cloud-dependencies[bot]"},"body":"<!-- pnpm-release-age -->\\nsecond"}'
app_other='{"id":10,"user":{"login":"ostendorf-cloud-dependencies[bot]"},"body":"a different app comment"}'
lookalike='{"id":11,"user":{"login":"ostendorf-cloud-dependencies"},"body":"<!-- pnpm-release-age -->\\ncopied"}'

# filter_lacks VALUE: no jq program of the run contains VALUE, so the author is data.
filter_lacks() { ! grep -F 'select(' "$STUB_DIR/jq_args" | grep -qF -- "$1"; }
# arg_given VALUE: VALUE reached jq as an argument of its own, as with --arg.
arg_given() { grep -qxF -- "$1" "$STUB_DIR/jq_args"; }

CASE_AUTHOR=$app run_case "$fail_log" "[$human,$lookalike,$older,$app_other,$app_old,$app_new]"
assert test "$status" -eq 0
assert grep -qF 'api -X PATCH repos/o/r/issues/comments/8 -F body=@' "$STUB_DIR/calls"
assert no_post
assert test "$(call_count)" -eq 2
assert arg_given "$app"
assert filter_lacks "$app"
assert filter_lacks 'github-actions'
# The page with the app comment may come after the first page.
CASE_AUTHOR=$app run_case "$fail_log" "[$older,$app_old]"
assert grep -qF 'api -X PATCH repos/o/r/issues/comments/8 -F body=@' "$STUB_DIR/calls"
# Only comments of other authors carry the marker: a new comment, nothing edited.
CASE_AUTHOR=$app run_case "$fail_log" "[$human,$lookalike,$older,$app_other]"
assert grep -qF 'api -X POST repos/o/r/issues/7/comments -F body=@' "$STUB_DIR/calls"
assert no_patch
# Without COMMENT_AUTHOR, and with an empty one, the author is github-actions[bot] and a
# comment of the app is never edited.
run_case "$fail_log" "[$app_old,$human,$older]"
assert test "$status" -eq 0
assert grep -qF 'api -X PATCH repos/o/r/issues/comments/3 -F body=@' "$STUB_DIR/calls"
assert test "$(call_count)" -eq 2
assert arg_given 'github-actions[bot]'
assert filter_lacks 'github-actions'
run_case "$fail_log" "[$app_old,$human]"
assert grep -qF 'api -X POST repos/o/r/issues/7/comments -F body=@' "$STUB_DIR/calls"
assert no_patch
CASE_AUTHOR='' run_case "$fail_log" "[$app_old,$older]"
assert test "$status" -eq 0
assert grep -qF 'api -X PATCH repos/o/r/issues/comments/3 -F body=@' "$STUB_DIR/calls"
# A plain user login is accepted as well.
CASE_AUTHOR=someone run_case "$fail_log" "[$older,$human]"
assert grep -qF 'api -X PATCH repos/o/r/issues/comments/1 -F body=@' "$STUB_DIR/calls"

# 7c. COMMENT_AUTHOR must be a GitHub login or an app slug with "[bot]", at most 40
# characters. Anything else fails with a message before any gh call, with or without a
# release age failure in the log.
rep40() { head -c "$1" /dev/zero | tr '\0' a; }
CASE_AUTHOR="$(rep40 35)[bot]" run_case "$fail_log" "[$older]"
assert test "$status" -eq 0
assert grep -qF 'api -X POST repos/o/r/issues/7/comments -F body=@' "$STUB_DIR/calls"
CASE_AUTHOR=$(rep40 40) run_case "$fail_log"
assert test "$status" -eq 0
bad_authors=(
  "$(rep40 36)[bot]"
  "$(rep40 41)"
  'a"b'
  "a'b"
  'a b'
  'github-actions[bot] '
  $'a\nb'
  $'a\tb'
  "a\$(id)"
  "\$(id)"
  "a\`id\`"
  'a\b'
  'a;b'
  'a|b'
  'a)'
  '-leading'
  '[bot]'
  'a[bot'
  'a[bot][bot]'
  'a[BOT]'
  'a.b'
  'a/b'
  'a_b'
)
for bad in "${bad_authors[@]}"; do
  CASE_AUTHOR=$bad run_case "$fail_log" "[$older]"
  assert test "$status" -ne 0
  assert no_calls
  assert grep -qF 'COMMENT_AUTHOR' "$STUB_DIR/stderr"
done
CASE_AUTHOR='a"b' run_case 'ERR_PNPM_FETCH_404 not found\n'
assert test "$status" -ne 0
assert no_calls

# 8. Another failure: no gh call, exit 0.
run_case 'ERR_PNPM_FETCH_404 not found\n'
assert test "$status" -eq 0
assert no_calls

# 9. A missing log, for example when the install job failed before it: no gh call, exit 0.
STUB_DIR=$(mktemp -d "$work/case.XXXXXX")
export STUB_DIR
PATH="$work/bin:$PATH" REPO=o/r PR=7 bash "$script" "$work/none.log"
assert test "$?" -eq 0
assert no_calls

# 10. pnpm wraps its lines: right after "was published at", inside the cutoff, and a long
# scoped name with a build suffix.
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION
  ╰─▶ 2 lockfile entries failed verification:
        ignore@7.0.16 was published at
      2026-11-17T05:56:55.170Z, within the minimumReleaseAge
      cutoff (
      2026-11-16T23:05:09.237Z)
        @very-long-scope-name-for-testing/some-extremely-long-package-name@12.34.56-rc.1+build.5
      was published at 2026-11-17T06:00:00.000Z, within the
'
assert body_has "- \`ignore@7.0.16\`, published at \`2026-11-17T05:56:55.170Z\`"
assert body_has "- \`@very-long-scope-name-for-testing/some-extremely-long-package-name@12.34.56-rc.1+build.5\`, published at \`2026-11-17T06:00:00.000Z\`"
assert body_has "Cutoff of the failed run: \`2026-11-16T23:05:09.237Z\`"

# 11. Names may have capitals.
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n  JSONStream@1.3.6 was published at 2026-11-17T05:56:55.170Z, within the\n'
assert body_has "- \`JSONStream@1.3.6\`, published at"

# 12. The same entry twice is listed once.
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION
  dup@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the
  dup@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the
'
assert test "$(grep -c "^- \`dup@1.0.0\`" "$STUB_DIR/body")" -eq 1

# 13. Two cutoffs: the first one wins.
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION
  a@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the minimumReleaseAge cutoff (2026-11-16T00:00:00.000Z)
  b@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the minimumReleaseAge cutoff (2027-01-01T00:00:00.000Z)
'
assert body_has "\`2026-11-16T00:00:00.000Z\`"
assert body_lacks '2027-01-01'

# 14. A timestamp must be complete, and a cutoff must be a timestamp: nothing else is printed.
run_case 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION
  bad@1.0.0 was published at 2026-11-17T05:56:55.Z, within the
  worse@1.0.0 was published at 2026-11-17Tfoo, within the
  minimumReleaseAge cutoff (evil text)
'
assert body_lacks 'bad@1.0.0'
assert body_lacks 'worse@1.0.0'
assert body_lacks 'evil'
assert body_lacks 'Cutoff of the failed run'

# 14b. Markup, mentions and a forged marker in the log never reach the comment, and every
# listed name sits in backticks.
run_case "Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION
  <!-- pnpm-release-age --> @someone <img src=x> \`tick\`@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the
  ok@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the
"
assert test "$(grep -cF "$marker" "$STUB_DIR/body")" -eq 1
assert body_lacks '@someone'
assert body_lacks '<img'
assert body_lacks "\`tick\`"
assert body_has "- \`ok@1.0.0\`, published at"
assert test "$(grep -c '^- ' "$STUB_DIR/body")" -eq 1
assert test "$(grep -c "^- \`[^\`]*\`, published at \`[^\`]*\`\$" "$STUB_DIR/body")" -eq 1

# 15. Many entries: at most 50 are listed, then the rest is counted, and the body stays small.
big='Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n'
for i in $(seq 1 2000); do
  big+="  pkg$i@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the\n  minimumReleaseAge cutoff (2026-11-16T23:05:09.237Z)\n"
done
run_case "$big"
assert test "$(grep -c "^- \`pkg" "$STUB_DIR/body")" -eq 50
assert body_has 'and 1950 more'
assert test "$(wc -c <"$STUB_DIR/body")" -lt 60000

# gen_log N: a log with N refused entries.
gen_log() {
  local out='Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n' i
  for ((i = 1; i <= $1; i++)); do
    out+="  pkg$i@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the\n"
  done
  printf '%s' "$out"
}

# 15b. Exactly at the limit nothing is said about more, one above it the rest is counted.
run_case "$(gen_log 50)"
assert test "$(grep -c "^- \`pkg" "$STUB_DIR/body")" -eq 50
assert body_lacks ' more'
run_case "$(gen_log 51)"
assert test "$(grep -c "^- \`pkg" "$STUB_DIR/body")" -eq 50
assert body_has '- and 1 more'

# 15c. A package name is at most 214 characters long, the npm limit. A longer run of name
# characters is not a package and is not listed.
rep() { head -c "$1" /dev/zero | tr '\0' "$2"; }
run_case "Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n  $(rep 214 b)@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the\n"
assert body_has "$(rep 214 b)@1.0.0"
run_case "Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n  $(rep 215 b)@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the\n"
assert body_lacks "$(rep 20 b)"
run_case "Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n  $(rep 20000 a)@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the\n"
assert body_lacks "$(rep 20 a)"
assert test "$(wc -c <"$STUB_DIR/body")" -lt 2000

# 15d. A version is at most 64 characters long: a digit and 63 more. A longer one is not
# listed, and 50 entries with a 20000 character version keep the body small.
run_case "Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n  v@1$(rep 63 0) was published at 2026-11-17T05:56:55.170Z, within the\n"
assert body_has "- \`v@1$(rep 63 0)\`, published at"
run_case "Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n  v@1$(rep 64 0) was published at 2026-11-17T05:56:55.170Z, within the\n"
assert body_lacks "v@1$(rep 20 0)"
long_version=$(rep 20000 9)
huge='Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n'
for i in $(seq 1 50); do
  huge+="  big$i@$long_version was published at 2026-11-17T05:56:55.170Z, within the\n"
done
huge+='  ok@1.0.0 was published at 2026-11-17T05:56:55.170Z, within the\n'
run_case "$huge"
assert body_lacks "$(rep 20 9)"
assert body_has "- \`ok@1.0.0\`, published at"
assert test "$(grep -c '^- ' "$STUB_DIR/body")" -eq 1
assert test "$(wc -c <"$STUB_DIR/body")" -lt 60000

# 15e. A bold red colour code is stripped, a scope with a dot is a scope, and a version
# that starts with a letter is not a version.
run_case '\033[1;31mError: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\033[0m
  \033[1;31mred@1.0.0\033[0m was published at 2026-11-17T05:56:55.170Z, within the
  @my.scope/dotted@2.0.0 was published at 2026-11-17T05:56:55.170Z, within the
  letter@v1.0.0 was published at 2026-11-17T05:56:55.170Z, within the
'
assert body_has "- \`red@1.0.0\`, published at"
assert body_has "- \`@my.scope/dotted@2.0.0\`, published at"
assert body_lacks 'letter@'
assert test "$(grep -c '^- ' "$STUB_DIR/body")" -eq 2

# 16. A missing REPO or PR fails before any gh call.
STUB_DIR=$(mktemp -d "$work/case.XXXXXX")
export STUB_DIR
printf 'Error: ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION\n' >"$STUB_DIR/install.log"
PATH="$work/bin:$PATH" REPO=o/r bash "$script" "$STUB_DIR/install.log" 2>/dev/null
assert test "$?" -ne 0
assert no_calls

# 17. The install step of the caller snippet in README.md, run as GitHub runs a step
# without a shell key: "bash -e {0}", which has no pipefail of its own.
snippet=$(awk '
  /^## pnpm release age comment$/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section && !in_block && /^```yaml$/ { in_block = 1; next }
  in_block && /^```$/ { exit }
  in_block { print }
' "$readme")
install_run=$(printf '%s\n' "$snippet" |
  yq -r '.jobs.install.steps[] | select(.name == "Install the dependencies and keep the log") | .run')
assert test -n "$install_run"

# run_install EXIT: runs the step with a stub pnpm that prints to both streams and exits EXIT.
run_install() {
  mkdir -p "$work/install/bin" "$work/install/tmp"
  printf '#!/usr/bin/env bash\necho installing\necho oops >&2\nexit %s\n' "$1" >"$work/install/bin/pnpm"
  chmod +x "$work/install/bin/pnpm"
  printf '%s\n' "$install_run" >"$work/install/step.sh"
  PATH="$work/install/bin:$PATH" RUNNER_TEMP="$work/install/tmp" \
    bash -e "$work/install/step.sh" >/dev/null 2>&1
}
# The exit code is the install's own, never tee's, so a failed install stays a failed job.
run_install 7
assert test "$?" -eq 7
assert grep -qF installing "$work/install/tmp/install.log"
assert grep -qF oops "$work/install/tmp/install.log"
run_install 0
assert test "$?" -eq 0
# A second run overwrites the log, it never appends to an old one.
printf 'OLD LOG\n' >"$work/install/tmp/install.log"
run_install 0
assert test "$(head -n 1 "$work/install/tmp/install.log")" = installing

printf '%d checks, %d failed\n' "$checks" "$fails"
[[ $fails -eq 0 ]]
