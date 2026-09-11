#!/usr/bin/env bash
# Focused executable tests for the shared CircleCI round-trip action.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
action_script="$root_dir/.github/actions/circleci-round-trip/round_trip.sh"
workflow_file="$root_dir/.github/workflows/circleci-round-trip.yml"
real_path=${PATH}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1
  local needle=$2
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

# Composite-action input ids are hyphenated. A snake_case key here silently
# leaves the action input empty/defaulted even though actionlint accepts it.
for input in format triggered-by upstream-sha timeout-seconds poll-seconds empty-grace-seconds max-transient-failures; do
  grep -Fq "          ${input}:" "$workflow_file" || fail "workflow does not pass action input ${input}"
done
# The loop above only proves the KEY exists under `with:`. Hard-coding
# `format: excel` there satisfies it while every caller silently gets an Excel
# round-trip whatever it asked for -- the one hop no other assertion covers.
# shellcheck disable=SC2016  # ${{ }} is GitHub Actions syntax to match literally
grep -Fq 'format: ${{ inputs.format }}' "$workflow_file" \
  || fail "workflow does not forward its format input to the action"
grep -Fq "CIRCLECI_API_TOKEN: \${{ secrets.CIRCLECI_API_TOKEN }}" "$workflow_file" \
  || fail "workflow does not use the canonical CIRCLECI_API_TOKEN secret"
action_ref=$(sed -nE 's/^        uses: ParamountDataManagement\/\.github\/\.github\/actions\/circleci-round-trip@(.+)$/\1/p' "$workflow_file")
[[ "$action_ref" =~ ^[0-9a-f]{40}$ ]] \
  || fail "central workflow must use an immutable reachable commit SHA: $action_ref"
if ! git -C "$root_dir" cat-file -e "$action_ref^{commit}" 2>/dev/null; then
  fail "central workflow action pin is not a reachable commit: $action_ref"
fi
for action_file in .github/actions/circleci-round-trip/action.yml .github/actions/circleci-round-trip/round_trip.sh; do
  git -C "$root_dir" cat-file -e "$action_ref:$action_file" 2>/dev/null \
    || fail "pinned commit $action_ref does not contain $action_file"
  # A release-pin PR intentionally changes the workflow/action contract while
  # still pointing at the previous reachable release. Enforce byte equality on
  # the post-merge push to main, where the pin must match the shipped files.
  if [[ "${GITHUB_EVENT_NAME:-}" == "push" && "${GITHUB_REF:-}" == "refs/heads/main" ]]; then
    git -C "$root_dir" show "$action_ref:$action_file" | diff -u - "$root_dir/$action_file" \
      || fail "working tree $action_file differs from pinned commit $action_ref"
  fi
done
# Reachable and containing the files is not enough: the PREVIOUS release is both,
# and pinning it would leave every caller's `format` input unread by an action
# that does not declare it. Bind the pin to the capability the workflow requires.
git -C "$root_dir" show "$action_ref:.github/actions/circleci-round-trip/action.yml" \
  | grep -Eq '^  format:' \
  || fail "the pinned action release does not declare the format input: $action_ref"
git -C "$root_dir" show "$action_ref:.github/actions/circleci-round-trip/round_trip.sh" \
  | grep -Fq 'CIRCLECI_ROUND_TRIP_FORMAT' \
  || fail "the pinned action release does not read CIRCLECI_ROUND_TRIP_FORMAT: $action_ref"

grep -Fq "post-merge commit on" "$root_dir/.github/CIRCLECI-ROUND-TRIP-RELEASE.md" \
  || fail "release contract does not require callers to use the post-merge main commit"

# The composite action is the only path a real caller takes, and every case
# below invokes round_trip.sh directly with env vars -- so deleting an `env:`
# mapping in action.yml would leave all of them green while the action silently
# stopped forwarding that input. Bind the two together: every variable the
# script REQUIRES must be mapped from an action input, and `format` by name,
# because it is the one that selects which round-trip runs.
action_yaml="$root_dir/.github/actions/circleci-round-trip/action.yml"
required_vars=$(sed -nE 's/^: "\$\{(CIRCLECI_[A-Z_]+):\?.*$/\1/p' "$action_script")
[[ -n "$required_vars" ]] || fail "round_trip.sh declares no required CIRCLECI_* variables"
while read -r required_var; do
  [[ -n "$required_var" ]] || continue
  # CIRCLECI_API_TOKEN comes from the reusable workflow's secrets block, not an input.
  [[ "$required_var" == CIRCLECI_API_TOKEN ]] && continue
  grep -Eq "^ +${required_var}: \\\$\{\{ inputs" "$action_yaml" \
    || fail "action.yml does not map ${required_var} from an action input"
done <<<"$required_vars"
# shellcheck disable=SC2016  # ${{ }} is GitHub Actions syntax to match literally, not shell expansion
grep -Fq 'CIRCLECI_ROUND_TRIP_FORMAT: ${{ inputs.format }}' "$action_yaml" \
  || fail "action.yml does not forward the format input to CIRCLECI_ROUND_TRIP_FORMAT"
grep -Eq '^  format:' "$action_yaml" \
  || fail "action.yml declares no format input"
grep -Eq '^    required: true' <<<"$(sed -n '/^  format:/,/^  [a-z]/p' "$action_yaml")" \
  || fail "the format input must be required: a default would silently pick a round-trip"

# The same contract one level up. Callers reach the action through the reusable
# workflow, so a `default:` there would let a caller omit `format` and silently
# get someone else's round-trip -- and the action.yml check above cannot see it.
# awk, not a sed range: the range's end address only matched another 6-space key,
# so if `format` ever became the LAST input the block ran to EOF and swallowed
# the secrets section -- whose CIRCLECI_API_TOKEN carries `required: true` at the
# same indent, satisfying the assertion below by accident. This stops at the
# first line indented six spaces or less, which `    secrets:` and `  round-trip:`
# both are.
workflow_format_block=$(awk '
  /^      format:/ { inblock = 1; print; next }
  inblock && /^ {0,6}[^ ]/ { exit }
  inblock { print }
' "$workflow_file")
[[ -n "$workflow_format_block" ]] || fail "the reusable workflow declares no format input"
grep -Eq '^        required: true' <<<"$workflow_format_block" \
  || fail "the reusable workflow's format input must be required: true"
if grep -Eq '^        default:' <<<"$workflow_format_block"; then
  fail "the reusable workflow's format input must have no default: one would pick a round-trip for a caller that did not say"
fi

make_curl_stub() {
  local dir=$1
  cat >"$dir/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

post=false
for arg in "$@"; do
  if [[ "$arg" == "POST" ]]; then
    post=true
  fi
done

if [[ "$post" == true ]]; then
  printf '%s\n' "$*" >>"$CURL_ARGS"
  cat "$CURL_POST_RESPONSE"
  exit "${CURL_POST_STATUS:-0}"
fi

count_file="$CURL_POLL_DIR/count"
count=0
if [[ -f "$count_file" ]]; then
  count=$(<"$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
printf '%s\n' "$*" >>"$CURL_ARGS"

response="$CURL_POLL_DIR/poll-${count}.json"
if [[ ! -f "$response" ]]; then
  response="$CURL_POLL_DIR/poll-last.json"
fi
if [[ -f "$response" ]]; then
  cat "$response"
fi
status_file="$CURL_POLL_DIR/poll-${count}.status"
if [[ -f "$status_file" ]]; then
  exit "$(<"$status_file")"
fi
exit "${CURL_POLL_STATUS:-0}"
STUB
  chmod +x "$dir/curl"
}

new_case() {
  case_dir=$(mktemp -d)
  mkdir -p "$case_dir/polls"
  : >"$case_dir/args"
  make_curl_stub "$case_dir"
  export CURL_ARGS="$case_dir/args"
  export CURL_POST_RESPONSE="$case_dir/post.json"
  export CURL_POLL_DIR="$case_dir/polls"
  export PATH="$case_dir:$real_path"
}

run_action_values() {
  local timeout=$1 poll=$2 grace=$3 transient_limit=$4 format=${5:-excel}
  local output status
  set +e
  output=$(
    CIRCLECI_API_BASE=https://circle.example/api/v2 \
      CIRCLECI_API_TOKEN=stub-token \
      CIRCLECI_PROJECT=gh/ParamountDataManagement/import-pipeline-tests \
      CIRCLECI_BRANCH=main \
      CIRCLECI_TRIGGERED_BY=pdmgolambda \
      CIRCLECI_ROUND_TRIP_FORMAT="$format" \
      CIRCLECI_UPSTREAM_SHA=deadbeef \
      CIRCLECI_TIMEOUT_SECONDS="$timeout" \
      CIRCLECI_POLL_SECONDS="$poll" \
      CIRCLECI_EMPTY_GRACE_SECONDS="$grace" \
      CIRCLECI_MAX_TRANSIENT_FAILURES="$transient_limit" \
      "$action_script" 2>&1
  )
  status=$?
  set -e
  printf '%s\n' "$status" >"$case_dir/status"
  printf '%s\n' "$output" >"$case_dir/output"
}

run_action() {
  run_action_values 5 0 0 2
}

# A passing run must send the canonical selector and attribution fields, then
# poll the pipeline returned by the POST until excel-round-trip succeeds.
new_case
printf '%s\n' '{"id":"pipeline-123"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"success"}]}' >"$CURL_POLL_DIR/poll-1.json"
run_action
[[ $(<"$case_dir/status") == 0 ]] || fail "success case exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "excel-round-trip: success"
request=$(head -1 "$CURL_ARGS")
assert_contains "$request" "/project/gh/ParamountDataManagement/import-pipeline-tests/pipeline"
assert_contains "$request" '"run-excel-round-trip":true'
assert_contains "$request" '"triggered_by":"pdmgolambda"'
assert_contains "$request" '"upstream_sha":"deadbeef"'
assert_contains "$(tail -1 "$CURL_ARGS")" "/pipeline/pipeline-123/workflow"

# A failed POST is reported as a trigger failure and never starts polling.
new_case
printf '%s\n' '{"message":"denied"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '1' >"$case_dir/post.status"
# The curl stub reads this status through CURL_POST_STATUS.
export CURL_POST_STATUS=1
run_action
unset CURL_POST_STATUS
[[ $(<"$case_dir/status") == 1 ]] || fail "POST failure exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "CircleCI round-trip not triggered"
[[ ! -f "$CURL_POLL_DIR/count" ]] || fail "POST failure unexpectedly polled workflows"

# A successful POST without a usable pipeline id is not verifiable.
new_case
printf '%s\n' '{}' >"$CURL_POST_RESPONSE"
run_action
[[ $(<"$case_dir/status") == 2 ]] || fail "missing pipeline id exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "returned no pipeline id"

# An unreadable workflow response is transient. The action must retry it and
# still report the target workflow result once CircleCI returns valid JSON.
new_case
printf '%s\n' '{"id":"pipeline-unreadable"}' >"$CURL_POST_RESPONSE"
printf '%s\n' 'not-json' >"$CURL_POLL_DIR/poll-1.json"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"success"}]}' >"$CURL_POLL_DIR/poll-2.json"
run_action
[[ $(<"$case_dir/status") == 0 ]] || fail "unreadable response case exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "CircleCI returned invalid JSON"
assert_contains "$(<"$case_dir/output")" "excel-round-trip: success"
[[ $(<"$CURL_POLL_DIR/count") == 2 ]] || fail "unreadable response was not retried"

# Consecutive curl failures must reach the explicit unverified failure path,
# rather than being mistaken for a failed CircleCI workflow.
new_case
printf '%s\n' '{"id":"pipeline-transient-failures"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '1' >"$CURL_POLL_DIR/poll-1.status"
printf '%s\n' '1' >"$CURL_POLL_DIR/poll-2.status"
run_action
[[ $(<"$case_dir/status") == 5 ]] || fail "consecutive curl failures exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "CircleCI round-trip unverified"
assert_contains "$(<"$case_dir/output")" "Too many consecutive CircleCI API failures"
[[ $(<"$CURL_POLL_DIR/count") == 2 ]] || fail "consecutive curl failures did not reach the configured limit"

# A failed target workflow must fail the calling job, rather than treating a
# successful POST as a sufficient result.
new_case
printf '%s\n' '{"id":"pipeline-failed"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"failed"}]}' >"$CURL_POLL_DIR/poll-1.json"
run_action
[[ $(<"$case_dir/status") == 1 ]] || fail "failed workflow exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "CircleCI round-trip failed"

# queued and failing are pending states. Dynamic-config setup work may be
# visible before the selected workflow, so neither state may fail the job.
new_case
printf '%s\n' '{"id":"pipeline-pending"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"setup","status":"failing"},{"name":"excel-round-trip","status":"failing"}]}' >"$CURL_POLL_DIR/poll-1.json"
printf '%s\n' '{"items":[{"name":"setup","status":"success"},{"name":"excel-round-trip","status":"queued"}]}' >"$CURL_POLL_DIR/poll-2.json"
printf '%s\n' '{"items":[{"name":"setup","status":"success"},{"name":"excel-round-trip","status":"success"}]}' >"$CURL_POLL_DIR/poll-3.json"
run_action
[[ $(<"$case_dir/status") == 0 ]] || fail "pending workflow states exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "excel-round-trip: success"

# All workflow pages must be read before making a target/mis-selection
# decision. The target is intentionally only on the second page.
new_case
printf '%s\n' '{"id":"pipeline-paginated"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"setup","status":"success"}],"next_page_token":"page-two"}' >"$CURL_POLL_DIR/poll-1.json"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"success"}]}' >"$CURL_POLL_DIR/poll-2.json"
run_action
[[ $(<"$case_dir/status") == 0 ]] || fail "paginated workflow exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "excel-round-trip: success"
assert_contains "$(tail -1 "$CURL_ARGS")" "page-token=page-two"

# A pipeline containing only other completed workflows is a mis-selection, not
# a pass and not a timeout.
new_case
printf '%s\n' '{"id":"pipeline-absent"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"lint","status":"success"}]}' >"$CURL_POLL_DIR/poll-1.json"
run_action
[[ $(<"$case_dir/status") == 3 ]] || fail "absent workflow exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "round-trip did not run"

# No workflows at all must fail only after the configured empty grace period.
new_case
printf '%s\n' '{"id":"pipeline-empty-timeout"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[]}' >"$CURL_POLL_DIR/poll-1.json"
run_action
[[ $(<"$case_dir/status") == 3 ]] || fail "empty grace timeout exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "No CircleCI workflows were created"

# A dynamic-config response with no workflows gets its configured grace
# period. The target appears on the next poll instead of being misclassified.
# The grace is 5s, not 1s: with a 1s grace the case failed whenever the first
# poll happened to cross a wall-clock second boundary.
new_case
printf '%s\n' '{"id":"pipeline-grace"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[]}' >"$CURL_POLL_DIR/poll-1.json"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"success"}]}' >"$CURL_POLL_DIR/poll-2.json"
run_action_values 5 0 5 2
[[ $(<"$case_dir/status") == 0 ]] || fail "empty grace case exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "excel-round-trip: success"

# A running target must hit the explicit timeout path rather than being
# mistaken for a CircleCI failure.
new_case
printf '%s\n' '{"id":"pipeline-timeout"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"running"}]}' >"$CURL_POLL_DIR/poll-last.json"
run_action_values 0 0 120 2
[[ $(<"$case_dir/status") == 4 ]] || fail "timeout case exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "round-trip timed out"

# The reusable workflow's documented cap is enforced before triggering
# CircleCI, so the GitHub job timeout cannot silently truncate the input.
new_case
printf '%s\n' '{"id":"pipeline-over-cap"}' >"$CURL_POST_RESPONSE"
set +e
cap_output=$(
  CIRCLECI_API_TOKEN=stub-token \
    CIRCLECI_PROJECT=project \
    CIRCLECI_BRANCH=main \
    CIRCLECI_TRIGGERED_BY=test \
    CIRCLECI_ROUND_TRIP_FORMAT=excel \
    CIRCLECI_TIMEOUT_SECONDS=1141 \
    CIRCLECI_MAX_TIMEOUT_SECONDS=1140 \
    CIRCLECI_POLL_SECONDS=0 \
    CIRCLECI_EMPTY_GRACE_SECONDS=0 \
    CIRCLECI_MAX_TRANSIENT_FAILURES=2 \
    "$action_script" 2>&1
)
cap_status=$?
set -e
[[ "$cap_status" == 2 ]] || fail "timeout cap exited $cap_status: $cap_output"
assert_contains "$cap_output" "exceeds the reusable workflow timeout cap"
[[ ! -f "$CURL_POLL_DIR/count" ]] || fail "timeout cap reached curl"

# Numeric inputs are validated before POST or arithmetic; shell expressions
# must be rejected as input, not evaluated.
for numeric_var in timeout poll grace transient; do
  new_case
  printf '%s\n' '{"id":"pipeline-numeric"}' >"$CURL_POST_RESPONSE"
  set +e
  numeric_output=$(
    CIRCLECI_API_TOKEN=stub-token \
      CIRCLECI_PROJECT=project \
      CIRCLECI_BRANCH=main \
      CIRCLECI_TRIGGERED_BY=test \
      CIRCLECI_ROUND_TRIP_FORMAT=excel \
      CIRCLECI_TIMEOUT_SECONDS=$([[ "$numeric_var" == timeout ]] && printf '1+1' || printf '5') \
      CIRCLECI_POLL_SECONDS=$([[ "$numeric_var" == poll ]] && printf '1+1' || printf '0') \
      CIRCLECI_EMPTY_GRACE_SECONDS=$([[ "$numeric_var" == grace ]] && printf '1+1' || printf '0') \
      CIRCLECI_MAX_TRANSIENT_FAILURES=$([[ "$numeric_var" == transient ]] && printf '1+1' || printf '2') \
      "$action_script" 2>&1
  )
  numeric_status=$?
  set -e
  [[ "$numeric_status" == 2 ]] || fail "$numeric_var numeric input exited $numeric_status: $numeric_output"
  assert_contains "$numeric_output" "Invalid CircleCI input"
  [[ ! -f "$CURL_POLL_DIR/count" ]] || fail "$numeric_var numeric input reached curl"
done

# A scheduled caller may omit the upstream SHA. The payload remains valid and
# does not include a misleading empty attribution value.
new_case
printf '%s\n' '{"id":"pipeline-nightly"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"success"}]}' >"$CURL_POLL_DIR/poll-1.json"
set +e
missing_sha_output=$(
  CIRCLECI_API_TOKEN=stub-token \
    CIRCLECI_PROJECT=project \
    CIRCLECI_BRANCH=development \
    CIRCLECI_TRIGGERED_BY=scheduled-nightly \
    CIRCLECI_ROUND_TRIP_FORMAT=excel \
    CIRCLECI_TIMEOUT_SECONDS=5 \
    CIRCLECI_POLL_SECONDS=0 \
    CIRCLECI_EMPTY_GRACE_SECONDS=0 \
    CIRCLECI_MAX_TRANSIENT_FAILURES=2 \
    PATH="$PATH" \
    "$action_script" 2>&1
)
missing_sha_status=$?
set -e
[[ $missing_sha_status == 0 ]] || fail "scheduled caller without upstream SHA exited $missing_sha_status: $missing_sha_output"
request=$(head -1 "$CURL_ARGS")
if [[ "$request" == *'"upstream_sha"'* ]]; then
  fail "scheduled caller sent an empty upstream_sha attribution"
fi

# The format selects BOTH the pipeline parameter and the awaited workflow, so an
# aces caller sends only run-aces-round-trip and waits on aces-round-trip.
new_case
printf '%s\n' '{"id":"pipeline-aces"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"aces-round-trip","status":"success"}]}' >"$CURL_POLL_DIR/poll-1.json"
run_action_values 5 0 0 2 aces
[[ $(<"$case_dir/status") == 0 ]] || fail "aces case exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "aces-round-trip: success"
request=$(head -1 "$CURL_ARGS")
assert_contains "$request" '"run-aces-round-trip":true'
if [[ "$request" == *'run-excel-round-trip'* ]]; then
  fail "aces caller also selected the excel round-trip"
fi

# An aces request whose pipeline only ran excel-round-trip is a mis-selection:
# another format's success must never satisfy it.
new_case
printf '%s\n' '{"id":"pipeline-aces-misselected"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"success"}]}' >"$CURL_POLL_DIR/poll-1.json"
run_action_values 5 0 0 2 aces
[[ $(<"$case_dir/status") == 3 ]] || fail "aces mis-selection exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "aces-round-trip was not visible"

# The format is required and shape-checked before CircleCI is contacted.
for bad_format in "" "Excel" "excel;true" "../aces"; do
  new_case
  printf '%s\n' '{"id":"pipeline-bad-format"}' >"$CURL_POST_RESPONSE"
  set +e
  format_output=$(
    CIRCLECI_API_TOKEN=stub-token \
      CIRCLECI_PROJECT=project \
      CIRCLECI_BRANCH=main \
      CIRCLECI_TRIGGERED_BY=test \
      CIRCLECI_ROUND_TRIP_FORMAT="$bad_format" \
      CIRCLECI_TIMEOUT_SECONDS=5 \
      CIRCLECI_POLL_SECONDS=0 \
      CIRCLECI_EMPTY_GRACE_SECONDS=0 \
      CIRCLECI_MAX_TRANSIENT_FAILURES=2 \
      "$action_script" 2>&1
  )
  format_status=$?
  set -e
  [[ "$format_status" != 0 ]] || fail "format '$bad_format' was accepted"
  assert_contains "$format_output" "CIRCLECI_ROUND_TRIP_FORMAT"
  [[ ! -s "$CURL_ARGS" ]] || fail "format '$bad_format' reached curl"
done

echo "PASS: CircleCI round-trip action tests"
