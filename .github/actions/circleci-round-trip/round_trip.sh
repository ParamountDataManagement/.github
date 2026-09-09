#!/usr/bin/env bash
# Trigger a parameter-selected CircleCI pipeline and wait for its named workflow.
set -euo pipefail

: "${CIRCLECI_API_TOKEN:?CIRCLECI_API_TOKEN must be provided by the caller}"
: "${CIRCLECI_PROJECT:?CIRCLECI_PROJECT must be provided by the caller}"
: "${CIRCLECI_BRANCH:?CIRCLECI_BRANCH must be provided by the caller}"
: "${CIRCLECI_TRIGGERED_BY:?CIRCLECI_TRIGGERED_BY must be provided by the caller}"
: "${CIRCLECI_UPSTREAM_SHA:?CIRCLECI_UPSTREAM_SHA must be provided by the caller}"

api_base="${CIRCLECI_API_BASE:-https://circleci.com/api/v2}"
timeout_s="${CIRCLECI_TIMEOUT_SECONDS:-900}"
poll_s="${CIRCLECI_POLL_SECONDS:-15}"
empty_grace_s="${CIRCLECI_EMPTY_GRACE_SECONDS:-120}"
max_transient="${CIRCLECI_MAX_TRANSIENT_FAILURES:-3}"

payload=$(jq -cn \
  --arg branch "$CIRCLECI_BRANCH" \
  --arg triggered_by "$CIRCLECI_TRIGGERED_BY" \
  --arg upstream_sha "$CIRCLECI_UPSTREAM_SHA" \
  '{branch: $branch, parameters: {"run-excel-round-trip": true, triggered_by: $triggered_by, upstream_sha: $upstream_sha}}')

if ! response=$(curl --fail --silent --show-error --max-time 30 \
  -X POST \
  -H "Circle-Token: ${CIRCLECI_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "$api_base/project/$CIRCLECI_PROJECT/pipeline" 2>&1); then
  echo "::error title=CircleCI round-trip not triggered::CircleCI rejected the pipeline request: $response" >&2
  exit 1
fi

pipeline_id=$(printf '%s' "$response" | jq -er '.id') || {
  echo "::error title=CircleCI round-trip not verifiable::CircleCI returned no pipeline id." >&2
  exit 2
}

echo "Created CircleCI pipeline $pipeline_id"

started=$(date +%s)
deadline=$((started + timeout_s))
transient=0

while :; do
  if ! body=$(curl --fail --silent --show-error --max-time 30 \
    -H "Circle-Token: ${CIRCLECI_API_TOKEN}" \
    "$api_base/pipeline/$pipeline_id/workflow" 2>&1); then
    transient=$((transient + 1))
    echo "::warning title=CircleCI poll failed::CircleCI API call failed ($transient/$max_transient): $body"
    if (( transient >= max_transient )); then
      echo "::error title=CircleCI round-trip unverified::Too many consecutive CircleCI API failures." >&2
      exit 5
    fi
    sleep "$poll_s"
    continue
  fi

  if ! total=$(printf '%s' "$body" | jq -er '
    if (.items? == null) then 0
    elif (.items | type) == "array" then (.items | length)
    else error("items must be an array")
    end
  ' 2>/dev/null); then
    transient=$((transient + 1))
    echo "::warning title=CircleCI poll unreadable::CircleCI returned invalid JSON ($transient/$max_transient)"
    if (( transient >= max_transient )); then
      echo "::error title=CircleCI round-trip unverified::Too many consecutive unreadable CircleCI responses." >&2
      exit 5
    fi
    sleep "$poll_s"
    continue
  fi
  transient=0

  status=$(printf '%s' "$body" | jq -r '[(.items // [])[] | select(.name == "excel-round-trip")] | .[0].status // empty')
  pending=$(printf '%s' "$body" | jq -r '[(.items // [])[] | select(.status == "running" or .status == "on_hold")] | length')

  case "$status" in
    success)
      echo "excel-round-trip: success"
      exit 0
      ;;
    running|on_hold|"") ;;
    *)
      echo "::error title=CircleCI round-trip failed::excel-round-trip ended in '$status'." >&2
      exit 1
      ;;
  esac

  now=$(date +%s)
  elapsed=$((now - started))
  if [[ -z "$status" && "$total" -gt 0 && "$pending" -eq 0 ]]; then
    echo "::error title=CircleCI round-trip did not run::The pipeline ran workflows but excel-round-trip was not among them." >&2
    exit 3
  fi
  if [[ "$total" -eq 0 && "$elapsed" -ge "$empty_grace_s" ]]; then
    echo "::error title=CircleCI round-trip did not run::No CircleCI workflows were created within ${empty_grace_s}s." >&2
    exit 3
  fi
  if [[ "$now" -ge "$deadline" ]]; then
    echo "::error title=CircleCI round-trip timed out::excel-round-trip did not finish within ${timeout_s}s." >&2
    exit 4
  fi

  sleep "$poll_s"
done
