#!/usr/bin/env bash
# Trigger a parameter-selected CircleCI pipeline and wait for its named workflow.
#
# CIRCLECI_ROUND_TRIP_FORMAT selects both names, so they cannot drift apart:
# the pipeline parameter run-<format>-round-trip and the workflow
# <format>-round-trip. Which formats exist is decided by the CircleCI project's
# own config, which declares those parameters; CircleCI rejects an undeclared
# one, so this script checks only that the value is a safe identifier.
set -euo pipefail

: "${CIRCLECI_API_TOKEN:?CIRCLECI_API_TOKEN must be provided by the caller}"
: "${CIRCLECI_PROJECT:?CIRCLECI_PROJECT must be provided by the caller}"
: "${CIRCLECI_BRANCH:?CIRCLECI_BRANCH must be provided by the caller}"
: "${CIRCLECI_TRIGGERED_BY:?CIRCLECI_TRIGGERED_BY must be provided by the caller}"
: "${CIRCLECI_ROUND_TRIP_FORMAT:?CIRCLECI_ROUND_TRIP_FORMAT must be provided by the caller}"
api_base="${CIRCLECI_API_BASE:-https://circleci.com/api/v2}"
timeout_s="${CIRCLECI_TIMEOUT_SECONDS:-900}"
poll_s="${CIRCLECI_POLL_SECONDS:-15}"
empty_grace_s="${CIRCLECI_EMPTY_GRACE_SECONDS:-120}"
max_transient="${CIRCLECI_MAX_TRANSIENT_FAILURES:-3}"
max_timeout_s="${CIRCLECI_MAX_TIMEOUT_SECONDS:-}"

# Bash arithmetic treats untrusted strings as expressions. Validate and
# normalize every numeric input before using it in arithmetic or sleep.
parse_uint() {
  local name=$1 value=$2 normalized

  if [[ ! $value =~ ^[0-9]+$ ]]; then
    echo "::error title=Invalid CircleCI input::${name} must be a non-negative integer." >&2
    return 1
  fi
  normalized=$(printf '%s' "$value" | sed 's/^0*//')
  [[ -n "$normalized" ]] || normalized=0
  # Keep arithmetic within the portable signed 32-bit range used by the
  # reusable workflow's documented timeout cap.
  if (( ${#normalized} > 10 )) ||
    { (( ${#normalized} == 10 )) && (( 10#$normalized > 2147483647 )); }; then
    echo "::error title=Invalid CircleCI input::${name} is too large." >&2
    return 1
  fi
  printf '%s\n' "$((10#$normalized))"
}

if ! timeout_s=$(parse_uint CIRCLECI_TIMEOUT_SECONDS "$timeout_s") ||
  ! poll_s=$(parse_uint CIRCLECI_POLL_SECONDS "$poll_s") ||
  ! empty_grace_s=$(parse_uint CIRCLECI_EMPTY_GRACE_SECONDS "$empty_grace_s") ||
  ! max_transient=$(parse_uint CIRCLECI_MAX_TRANSIENT_FAILURES "$max_transient"); then
  exit 2
fi
if (( max_transient < 1 )); then
  echo "::error title=Invalid CircleCI input::CIRCLECI_MAX_TRANSIENT_FAILURES must be at least 1." >&2
  exit 2
fi
if [[ -n "$max_timeout_s" ]]; then
  if ! max_timeout_s=$(parse_uint CIRCLECI_MAX_TIMEOUT_SECONDS "$max_timeout_s"); then
    exit 2
  fi
  if (( timeout_s > max_timeout_s )); then
    echo "::error title=Invalid CircleCI input::CIRCLECI_TIMEOUT_SECONDS exceeds the reusable workflow timeout cap." >&2
    exit 2
  fi
fi

if [[ ! $CIRCLECI_ROUND_TRIP_FORMAT =~ ^[a-z][a-z0-9]*$ ]]; then
  echo "::error title=Invalid CircleCI input::CIRCLECI_ROUND_TRIP_FORMAT must be a lowercase identifier such as excel, aces or pies." >&2
  exit 2
fi
workflow_name="${CIRCLECI_ROUND_TRIP_FORMAT}-round-trip"
selector="run-${CIRCLECI_ROUND_TRIP_FORMAT}-round-trip"

payload=$(jq -cn \
  --arg selector "$selector" \
  --arg branch "$CIRCLECI_BRANCH" \
  --arg triggered_by "$CIRCLECI_TRIGGERED_BY" \
  --arg upstream_sha "${CIRCLECI_UPSTREAM_SHA:-}" \
  '{branch: $branch, parameters: ({($selector): true, triggered_by: $triggered_by} + (if $upstream_sha == "" then {} else {upstream_sha: $upstream_sha} end))}')

if ! response=$(curl --fail --silent --show-error --max-time 30 \
  -X POST \
  -H "Circle-Token: ${CIRCLECI_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "$api_base/project/$CIRCLECI_PROJECT/pipeline" 2>&1); then
  echo "::error title=CircleCI round-trip not triggered::CircleCI rejected the pipeline request." >&2
  exit 1
fi

if ! pipeline_id=$(printf '%s' "$response" | jq -er '
  if (.id? | type) == "string" and (.id | length) > 0 then .id
  else error("pipeline id must be a non-empty string")
  end
'); then
  echo "::error title=CircleCI round-trip not verifiable::CircleCI returned no pipeline id." >&2
  exit 2
fi

echo "Created CircleCI pipeline $pipeline_id"

started=$(date +%s)
deadline=$((started + timeout_s))
transient=0

while :; do
  # CircleCI paginates this endpoint. Aggregate every page before deciding
  # whether the selected workflow is absent or terminal.
  workflow_items='[]'
  next_page_token=''
  page_failed=false
  page_error_kind=unreadable
  while :; do
    workflow_url="$api_base/pipeline/$pipeline_id/workflow"
    if [[ -n "$next_page_token" ]]; then
      encoded_token=$(jq -nr --arg token "$next_page_token" '$token | @uri')
      workflow_url+="?page-token=${encoded_token}"
    fi

    if ! page=$(curl --fail --silent --show-error --max-time 30 \
      -H "Circle-Token: ${CIRCLECI_API_TOKEN}" \
      "$workflow_url" 2>&1); then
      page_failed=true
      page_error_kind=api
      break
    fi

    if ! page_items=$(printf '%s' "$page" | jq -er '
      if (.items? == null) then []
      elif (.items | type) == "array" then .items
      else error("items must be an array")
      end
    ' 2>/dev/null) ||
      ! page_token=$(printf '%s' "$page" | jq -r '
        if (.next_page_token? == null) then ""
        elif (.next_page_token | type) == "string" then .next_page_token
        else error("next_page_token must be a string")
        end
      ' 2>/dev/null) ||
      ! workflow_items=$(jq -cn --argjson all "$workflow_items" --argjson page "$page_items" '$all + $page'); then
      page_failed=true
      page_error_kind=json
      break
    fi

    next_page_token=$page_token
    [[ -n "$next_page_token" ]] || break
  done

  if [[ "$page_failed" == true ]]; then
    transient=$((transient + 1))
    if [[ "$page_error_kind" == api ]]; then
      echo "::warning title=CircleCI poll failed::CircleCI API call failed ($transient/$max_transient)"
    else
      echo "::warning title=CircleCI poll unreadable::CircleCI returned invalid JSON ($transient/$max_transient)"
    fi
    if (( transient >= max_transient )); then
      if [[ "$page_error_kind" == api ]]; then
        echo "::error title=CircleCI round-trip unverified::Too many consecutive CircleCI API failures." >&2
      else
        echo "::error title=CircleCI round-trip unverified::Too many consecutive unreadable CircleCI responses." >&2
      fi
      exit 5
    fi
    sleep "$poll_s"
    continue
  fi
  transient=0

  total=$(jq -er 'length' <<<"$workflow_items")
  status=$(jq -r --arg name "$workflow_name" '[.[] | select(.name == $name) | .status] | last // empty' <<<"$workflow_items")

  case "$status" in
    success)
      echo "${workflow_name}: success"
      exit 0
      ;;
    queued|running|on_hold|failing|"")
      # These states, including CircleCI's transient `failing` state, remain
      # pending. A dynamic-config setup workflow may also precede the target.
      ;;
    failed|error|canceled|unauthorized|infrastructure_fail|not_run|no_tests)
      echo "::error title=CircleCI round-trip failed::${workflow_name} ended in '$status'." >&2
      exit 1
      ;;
    *)
      # Unknown statuses are safer to wait on than to misclassify as failure;
      # the overall timeout remains the final guard.
      echo "::warning title=CircleCI workflow pending::${workflow_name} is in unrecognized state '$status'; continuing to poll."
      ;;
  esac

  now=$(date +%s)
  elapsed=$((now - started))
  if (( now >= deadline )); then
    echo "::error title=CircleCI round-trip timed out::${workflow_name} did not finish within ${timeout_s}s." >&2
    exit 4
  fi
  if [[ -z "$status" && $elapsed -ge $empty_grace_s ]]; then
    if (( total == 0 )); then
      echo "::error title=CircleCI round-trip did not run::No CircleCI workflows were created within ${empty_grace_s}s." >&2
    else
      echo "::error title=CircleCI round-trip did not run::The pipeline ran workflows but ${workflow_name} was not visible within ${empty_grace_s}s." >&2
    fi
    exit 3
  fi

  sleep "$poll_s"
done
