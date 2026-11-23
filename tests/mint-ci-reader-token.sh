#!/usr/bin/env bash
# Behaviour tests for the pdm-ci-reader token check in
# .github/scripts/mint-ci-reader-token.sh, and the wiring that runs it.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root_dir/.github/scripts/mint-ci-reader-token.sh"
workflow_file="$root_dir/.github/workflows/validate-workflows.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# shellcheck source=.github/scripts/mint-ci-reader-token.sh disable=SC1091  # checked on its own in the same shellcheck call
source "$script"

# A read-only token passes and is printed.
got=$(verify_installation_token '{"token":"ghs_ok","permissions":{"contents":"read","metadata":"read"}}') \
  || fail "a contents:read token was refused"
[ "$got" = ghs_ok ] || fail "expected the token printed, got: $got"

# No token: refused.
if verify_installation_token '{"permissions":{"contents":"read"}}' >/dev/null 2>&1; then
  fail "a response with no token was accepted"
fi

# An empty token string: refused.
if verify_installation_token '{"token":"","permissions":{"contents":"read"}}' >/dev/null 2>&1; then
  fail "an empty token was accepted"
fi

# A token wider than contents:read: refused.
if verify_installation_token '{"token":"ghs_wide","permissions":{"contents":"write"}}' >/dev/null 2>&1; then
  fail "a contents:write token was accepted"
fi

# A token with no contents permission at all: refused.
if verify_installation_token '{"token":"ghs_none","permissions":{"metadata":"read"}}' >/dev/null 2>&1; then
  fail "a token without contents:read was accepted"
fi

# The workflow runs this script (not an inline copy) and holds no stored App key.
grep -Fq 'run: bash .github/scripts/mint-ci-reader-token.sh' "$workflow_file" \
  || fail "validate-workflows.yml does not run .github/scripts/mint-ci-reader-token.sh"
if grep -Eq 'create-github-app-token|PDM_FLEET_AUTOMATION' "$workflow_file"; then
  fail "validate-workflows.yml still mints from a stored App key"
fi

echo "mint-ci-reader-token: all checks passed"
