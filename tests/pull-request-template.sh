#!/usr/bin/env bash
# Focused executable tests for the org default pull request template.
#
# The template is a three-way contract: pdm-claude-standards
# REGRESSION_TESTING_POLICY.md quotes its checkbox lines, and pdm-ci-tools'
# regression-evidence check parses the exception line by its exact label and
# `Reason:` token. A wording change here that nobody propagated would make the
# check stop recognising every exception, silently. These pins are the coupling
# a reviewer will not catch.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
template="$root_dir/.github/pull_request_template.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$template" ]] || fail "missing $template"

# The exception line, exactly as check-regression-evidence.sh parses it:
# an unticked box, the bold label, and `Reason:` followed by the placeholder
# comment (stripped by the check, so an untouched template is not a reason).
grep -Fq -- '- [ ] **Regression exception** — no practical automated test surface. Reason: <!--' "$template" \
  || fail "the exception line must read '- [ ] **Regression exception** — no practical automated test surface. Reason: <!-- … -->'"
grep -Fq -- '- [ ] **Regression test added**' "$template" \
  || fail "the evidence checkbox must be '- [ ] **Regression test added**'"
grep -Fq -- '- [ ] Not a bug fix' "$template" \
  || fail "the third option must be '- [ ] Not a bug fix'"

# Every box ships UNTICKED. A pre-ticked exception would satisfy the check on
# every bug-fix PR that left the template alone.
if grep -Eq -- '^\s*-\s*\[[xX]\]' "$template"; then
  fail "no checkbox may ship ticked"
fi

# The policy link, so the checkbox text and the doc it cites stay together.
grep -Fq 'https://github.com/ParamountDataManagement/pdm-claude-standards/blob/main/REGRESSION_TESTING_POLICY.md' "$template" \
  || fail "the template must link REGRESSION_TESTING_POLICY.md"

# The check's name, so an author reading a red check finds the block that feeds it.
grep -Fq 'regression-evidence' "$template" || fail "the template must name the regression-evidence check"

echo "pull_request_template.md: contract lines present, nothing pre-ticked"
