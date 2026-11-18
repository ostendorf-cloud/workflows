#!/usr/bin/env bash
# Copyright 2026 Simon Ostendorf
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the token boundary of the pnpm release age comment: the composite action in
# .github/actions/pnpm-release-age-comment/action.yaml and the caller snippet in README.md.
# The install job runs untrusted code and must never hold a write token. Only the comment
# job may, and only for the one script step inside the action. The snippet is also linted
# with actionlint, so the documented caller stays a valid workflow.
#
# The app variant of the snippet is held to the same rules, and its token step to the
# pinned action and the scope of reusable-renovate.yaml.
#
# Environment: RELEASE_AGE_ACTION, RELEASE_AGE_README and RELEASE_AGE_RENOVATE override the
# files under test.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
action=${RELEASE_AGE_ACTION:-$here/../.github/actions/pnpm-release-age-comment/action.yaml}
readme=${RELEASE_AGE_README:-$here/../README.md}
renovate=${RELEASE_AGE_RENOVATE:-$here/../.github/workflows/reusable-renovate.yaml}
# An explicit template, because macOS mktemp ignores TMPDIR without one.
work=$(mktemp -d "${TMPDIR:-/tmp}/pnpm-release-age-action-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

fails=0
checks=0

assert() {
  checks=$((checks + 1))
  if ! "$@"; then
    fails=$((fails + 1))
    printf 'FAIL: %s\n' "$*" >&2
  fi
}

# The first yaml block of the README section is the caller workflow.
awk '
  /^## pnpm release age comment$/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section && !in_block && /^```yaml$/ { in_block = 1; next }
  in_block && /^```$/ { exit }
  in_block { print }
' "$readme" >"$work/caller.yaml"

q() { yq -r "$1" "$2"; }
eq() { [[ $(q "$1" "$3") == "$2" ]]; }
has() { [[ $(q "$1" "$3") == *"$2"* ]]; }
lacks() { [[ $(q "$1" "$3") != *"$2"* ]]; }
hex40() { [[ $(q "$1" "$2") =~ @[0-9a-f]{40}$ ]]; }

a=$action
c=$work/caller.yaml
guard="github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository"

# --- The action ---

assert eq '.runs.using' composite "$a"
assert eq '.inputs."github-token".required' true "$a"
assert eq '.inputs."github-token".default' null "$a"
assert eq '.inputs."artifact-name".required' true "$a"
assert eq '.inputs."log-file".default' install.log "$a"
assert eq '.inputs."comment-author".required' false "$a"
assert eq '.inputs."comment-author".default' 'github-actions[bot]' "$a"
assert eq '.inputs | keys | sort | join(",")' artifact-name,comment-author,github-token,log-file "$a"
# Every input is documented in the header comment above "name:".
for input in github-token artifact-name log-file comment-author; do
  assert grep -qE "^#   $input " "$a"
done

# Two steps: the download and the script. No checkout: the script ships with the action,
# so the job holding the token never checks out code of the pull request.
assert eq '.runs.steps | length' 2 "$a"
assert eq '[.runs.steps[] | select(.uses != null and (.uses | test("checkout")))] | length' 0 "$a"
assert eq '[.runs.steps[] | select(.uses != null)] | length' 1 "$a"

download='.runs.steps[0]'
assert has "$download.uses" actions/download-artifact@ "$a"
assert hex40 "$download.uses" "$a"
# No log, for example after a failed setup step, means no comment.
assert eq "$download.\"continue-on-error\"" true "$a"
assert eq "$download.with.name" "\${{ inputs.artifact-name }}" "$a"
# Exactly these keys: no "repository", no token, nothing that reaches another run.
assert eq "$download.with | keys | sort | join(\",\")" name,path "$a"
assert eq "$download.with.path" "\${{ runner.temp }}/pnpm-release-age-log" "$a"
# The token is never handed to the download.
assert lacks "$download | tojson" 'token' "$a"

script='.runs.steps[1]'
assert eq "$script.shell" bash "$a"
assert eq "$script.env.GH_TOKEN" "\${{ inputs.github-token }}" "$a"
assert eq "$script.env.REPO" "\${{ github.repository }}" "$a"
assert eq "$script.env.PR" "\${{ github.event.pull_request.number }}" "$a"
assert eq "$script.env.LOG_FILE" "\${{ inputs.log-file }}" "$a"
assert eq "$script.env.COMMENT_AUTHOR" "\${{ inputs.comment-author }}" "$a"
assert eq "$script.env | keys | sort | join(\",\")" COMMENT_AUTHOR,GH_TOKEN,LOG_FILE,PR,REPO "$a"
# The author reaches the script step only, through env.
assert eq '[.runs.steps[] | tojson | select(test("inputs.comment-author"))] | length' 1 "$a"
assert eq "$script.run" "bash \"\$GITHUB_ACTION_PATH/release-age-comment.sh\" \"\$RUNNER_TEMP/pnpm-release-age-log/\$LOG_FILE\"" "$a"
# The token reaches one step only, and no expression is expanded inside a run block.
assert eq '[.runs.steps[] | select(.env.GH_TOKEN != null)] | length' 1 "$a"
assert lacks '[.runs.steps[].run | select(. != null)] | join("\n")' "\${{" "$a"
assert eq '[.runs.steps[] | tojson | select(test("inputs.github-token"))] | length' 1 "$a"
# Each step skips a fork pull request and any other event on its own as well.
assert eq "$download.if" "$guard" "$a"
assert eq "$script.if" "$guard" "$a"

# --- The caller snippet ---

assert test -s "$c"
deps='.jobs.install'
comment='.jobs["release-age-comment"]'

# The workflow default stays read only, and nothing is set for every job.
assert eq '.permissions | keys | join(",")' contents "$c"
assert eq '.permissions.contents' read "$c"
assert eq '.env' null "$c"

# Exactly one job may write pull requests: the comment job.
assert eq '[.jobs[] | select(.permissions."pull-requests" == "write")] | length' 1 "$c"
assert eq "$comment.permissions.\"pull-requests\"" write "$c"
assert eq "$comment.permissions.contents" read "$c"
assert eq "$comment.permissions | keys | sort | join(\",\")" contents,pull-requests "$c"
assert eq "$deps.permissions | keys | join(\",\")" contents "$c"
assert eq "$deps.permissions.contents" read "$c"

# The install job keeps no checkout credential and never names the token or a secret.
assert eq "$deps.steps[0].with.\"persist-credentials\"" false "$c"
assert eq "[$deps.steps[].env.GH_TOKEN | select(. != null)] | length" 0 "$c"
assert lacks "$deps | tojson" 'github.token' "$c"
assert lacks "$deps | tojson" 'secrets.' "$c"
assert lacks "$deps | tojson" 'token:' "$c"

upload="$deps.steps[] | select(.uses != null and (.uses | test(\"upload-artifact\")))"
assert eq "$upload | .if" 'failure()' "$c"
assert hex40 "$upload | .uses" "$c"
assert eq "$upload | .with.path" "\${{ runner.temp }}/install.log" "$c"
assert has "$upload | .with.name" 'github.run_attempt' "$c"
assert eq "$deps.steps[] | select(.name == \"Install the dependencies and keep the log\") | .run" \
  "set -o pipefail"$'\n'"pnpm install --frozen-lockfile 2>&1 | tee \"\$RUNNER_TEMP/install.log\"" "$c"

# The comment job runs after the install job, only for a failed install on a pull request
# of the same repository, one run at a time per pull request.
assert eq "$comment.needs" install "$c"
assert eq "$comment.if" "\${{ always() && needs.install.result == 'failure' && $guard }}" "$c"
assert eq "$comment.concurrency.\"cancel-in-progress\"" false "$c"
assert has "$comment.concurrency.group" 'github.event.pull_request.number' "$c"

# Its only step is the action at the floating first party tag, which gets the token and
# the artifact name of the same attempt the install job uploaded.
assert eq "$comment.steps | length" 1 "$c"
assert eq "$comment.steps[0].uses" ostendorf-cloud/workflows/.github/actions/pnpm-release-age-comment@v0 "$c"
assert eq "$comment.steps[0].with.\"github-token\"" "\${{ github.token }}" "$c"
assert eq "$comment.steps[0].with.\"artifact-name\"" "$(q "$upload | .with.name" "$c")" "$c"
assert eq "$comment.steps[0].with.\"log-file\"" null "$c"
assert eq "[.jobs[] | tojson | select(test(\"github.token\"))] | length" 1 "$c"

# The documented caller is a valid workflow.
assert actionlint -no-color "$c"

# The README warns right below the snippet never to merge the two jobs, and the action
# header says the same.
after_snippet=$(awk '
  /^## pnpm release age comment$/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section && /^```yaml$/ { in_block = 1; next }
  in_block && /^```$/ { in_block = 0; done = 1; next }
  done && /^- / { print; exit }
' "$readme")
assert test "$after_snippet" = "- Never call the action from the install job, and never give the install job"
assert grep -qF 'never from the install job itself' "$action"

# --- The caller snippet with the dependencies app ---

# The first yaml block under the app heading is the same caller, posting as the app.
awk '
  /^### Post as the dependencies app$/ { in_section = 1; next }
  in_section && /^##/ { exit }
  in_section && !in_block && /^```yaml$/ { in_block = 1; next }
  in_block && /^```$/ { exit }
  in_block { print }
' "$readme" >"$work/caller-app.yaml"
p=$work/caller-app.yaml
assert test -s "$p"

# Everything but the comment job's steps is the default caller unchanged: the install job
# still names no token and no secret, and the workflow default stays read only.
assert eq 'del(.jobs["release-age-comment"].steps) | to_json(0)' "$(q 'del(.jobs["release-age-comment"].steps) | to_json(0)' "$c")" "$p"
assert eq '.permissions | to_json(0)' '{"contents":"read"}' "$p"
assert eq '.env' null "$p"
assert lacks "$deps | tojson" 'secrets.' "$p"
assert lacks "$deps | tojson" 'vars.' "$p"
assert lacks "$deps | tojson" 'token' "$p"
assert lacks "$deps | tojson" 'create-github-app-token' "$p"

# The comment job alone writes pull requests, and holds nothing else.
assert eq '[.jobs[] | select(.permissions."pull-requests" == "write")] | length' 1 "$p"
assert eq "$comment.permissions | to_json(0)" '{"contents":"read","pull-requests":"write"}' "$p"

# Two steps: mint the app token, then the action with it.
assert eq "$comment.steps | length" 2 "$p"
mint="$comment.steps[0]"
assert eq "$mint.id" app-token "$p"
# The same pinned action as in reusable-renovate.yaml, digest and version comment.
renovate_mint=$(grep -oE 'actions/create-github-app-token@[0-9a-f]{40}  # v[0-9.]+' "$renovate")
assert test -n "$renovate_mint"
assert grep -qF "      - uses: $renovate_mint" "$readme"
assert eq "$mint.uses" "${renovate_mint%%  #*}" "$p"
# Exactly the app, its key and one permission. No "owner" and no "repositories", so the
# token is scoped to the calling repository only.
assert eq "$mint.with | keys | sort | join(\",\")" app-id,permission-pull-requests,private-key "$p"
assert eq "[$mint.with | keys[] | select(test(\"^permission-\"))] | join(\",\")" permission-pull-requests "$p"
assert eq "$mint.with.\"permission-pull-requests\"" write "$p"
assert eq "$mint.with.\"app-id\"" "\${{ vars.GH_APP_DEPENDENCIES_APP_ID }}" "$p"
assert eq "$mint.with.\"private-key\"" "\${{ secrets.GH_APP_DEPENDENCIES_PRIVATE_KEY }}" "$p"
# The private key is named once in the whole workflow: in the mint step.
assert eq '[.. | select(tag == "!!str") | select(test("secrets\\."))] | length' 1 "$p"
assert eq "[$comment.steps[1:][] | tojson | select(test(\"secrets\\\\.\"))] | length" 0 "$p"

use="$comment.steps[1]"
assert eq "$use.uses" ostendorf-cloud/workflows/.github/actions/pnpm-release-age-comment@v0 "$p"
assert eq "$use.with | keys | sort | join(\",\")" artifact-name,comment-author,github-token "$p"
assert eq "$use.with.\"github-token\"" "\${{ steps.app-token.outputs.token }}" "$p"
assert eq "$use.with.\"artifact-name\"" "$(q "$comment.steps[0].with.\"artifact-name\"" "$c")" "$p"
# The login of the app is the one reusable-renovate.yaml knows the app by.
assert eq "$use.with.\"comment-author\"" 'ostendorf-cloud-dependencies[bot]' "$p"
assert grep -qF "'ostendorf-cloud-dependencies[bot]'" "$renovate"
# The workflow token is not passed anywhere in this variant.
assert lacks 'tojson' 'github.token' "$p"

# The documented app caller is a valid workflow.
assert actionlint -no-color "$p"

printf '%d checks, %d failed\n' "$checks" "$fails"
[[ $fails -eq 0 ]]
