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
for input in triggered-by upstream-sha timeout-seconds poll-seconds empty-grace-seconds max-transient-failures; do
  grep -Fq "          ${input}:" "$workflow_file" || fail "workflow does not pass action input ${input}"
done
grep -Fq "CIRCLECI_API_TOKEN: \${{ secrets.CIRCLECI_API_TOKEN }}" "$workflow_file" \
  || fail "workflow does not use the canonical CIRCLECI_API_TOKEN secret"

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
cat "$response"
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

run_action() {
  local output status
  set +e
  output=$(
    CIRCLECI_API_BASE=https://circle.example/api/v2 \
      CIRCLECI_API_TOKEN=stub-token \
      CIRCLECI_PROJECT=gh/ParamountDataManagement/import-pipeline-tests \
      CIRCLECI_BRANCH=main \
      CIRCLECI_TRIGGERED_BY=pdmgolambda \
      CIRCLECI_UPSTREAM_SHA=deadbeef \
      CIRCLECI_TIMEOUT_SECONDS=5 \
      CIRCLECI_POLL_SECONDS=0 \
      CIRCLECI_EMPTY_GRACE_SECONDS=0 \
      CIRCLECI_MAX_TRANSIENT_FAILURES=2 \
      "$action_script" 2>&1
  )
  status=$?
  set -e
  printf '%s\n' "$status" >"$case_dir/status"
  printf '%s\n' "$output" >"$case_dir/output"
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

# A failed target workflow must fail the calling job, rather than treating a
# successful POST as a sufficient result.
new_case
printf '%s\n' '{"id":"pipeline-failed"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"excel-round-trip","status":"failed"}]}' >"$CURL_POLL_DIR/poll-1.json"
run_action
[[ $(<"$case_dir/status") == 1 ]] || fail "failed workflow exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "CircleCI round-trip failed"

# A pipeline containing only other completed workflows is a mis-selection, not
# a pass and not a timeout.
new_case
printf '%s\n' '{"id":"pipeline-absent"}' >"$CURL_POST_RESPONSE"
printf '%s\n' '{"items":[{"name":"lint","status":"success"}]}' >"$CURL_POLL_DIR/poll-1.json"
run_action
[[ $(<"$case_dir/status") == 3 ]] || fail "absent workflow exited $(<"$case_dir/status")"
assert_contains "$(<"$case_dir/output")" "round-trip did not run"

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

echo "PASS: CircleCI round-trip action tests"
