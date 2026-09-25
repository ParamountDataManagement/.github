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
# The FULL evidence line, marker list included: REGRESSION_TESTING_POLICY.md quotes it
# verbatim and guards its copy, so a wording change here must be made in both places.
grep -Fq -- "- [ ] **Regression test added** — linked bug ticket, and a test that fails without the fix, tagged per the repo convention (RSpec \`regression: 'CU-…'\` · Vitest \`tags: ['regression']\` · Playwright \`@regression\` + annotation · Go \`TestRegression…\` · pytest \`@pytest.mark.regression\`)" "$template" \
  || fail "the evidence line must read exactly as REGRESSION_TESTING_POLICY.md § Evidence quotes it (label, clauses and marker list)"
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

# Exactly ONE `Reason:` line: the check takes the first ticked exception line it
# finds, so a second Reason line anywhere in the template would be an author's
# ticked box that the check never reads.
reason_lines=$(grep -c 'Reason:' "$template" || true)
[[ "$reason_lines" == "1" ]] || fail "expected exactly one 'Reason:' line, found $reason_lines"

# The three options sit together under the heading the policy names, as one
# list — the "tick exactly one" instruction is about THIS list.
block=$(awk '/^## Regression coverage/{f=1;next} /^## /{f=0} f' "$template")
[[ -n "$block" ]] || fail "missing the '## Regression coverage' section"
for line in '- [ ] **Regression test added**' '- [ ] **Regression exception**' '- [ ] Not a bug fix'; do
  grep -Fq -- "$line" <<<"$block" || fail "'$line' must be inside the Regression coverage section"
done
grep -Fq 'Tick exactly one' <<<"$block" || fail "the Regression coverage section must say 'Tick exactly one'"


# --- TDD on GenAI-authored work (CU-86b9tr93d) -------------------------------
# The second block, beside 9.3's. A human reviewer is the only gate on
# agent-written code, so the claim they are reading has to be on the PR and has
# to be rendered — not buried in an HTML comment they never see.

grep -Fq -- '## TDD on GenAI-authored work' "$template" \
  || fail "missing the '## TDD on GenAI-authored work' section"

# Alongside 9.3's block, and after it: the regression question is asked of every
# PR, the TDD question only of agent-written ones.
awk '/^## Regression coverage/{r=NR} /^## TDD on GenAI-authored work/{t=NR} END{exit !(r && t && t > r)}' "$template" \
  || fail "'## TDD on GenAI-authored work' must follow the '## Regression coverage' section"

tdd_block=$(awk '/^## TDD on GenAI-authored work/{f=1;next} /^## /{f=0} f' "$template")
[[ -n "$tdd_block" ]] || fail "the TDD section is empty"

# The label that makes the block required, stated as prose in the template body.
# shellcheck disable=SC2016  # backticks are markdown code spans to match literally
grep -Fq -- 'Required on PRs labeled `genai-authored`. Tick exactly one.' <<<"$tdd_block" \
  || fail "the TDD section must state 'Required on PRs labeled \`genai-authored\`. Tick exactly one.'"

# The three options, verbatim. The first is the claim Story 10.3 exists to put in
# front of a reviewer; the wording is the claim, so it is pinned whole.
tdd_confirm='- [ ] **Red→Green TDD followed** — every behaviour change here was written test-first: the test ran and failed for the right reason before the implementation, then passed unchanged'
grep -Fq -- "$tdd_confirm" <<<"$tdd_block" \
  || fail "the confirmation line must read exactly: $tdd_confirm"
grep -Fq -- '- [ ] **TDD exemption** — trivial change, emergency hotfix (tests follow within 48h, ClickUp task linked), or refactor already covered by tests. Justification: <!--' <<<"$tdd_block" \
  || fail "the exemption line must name the three TESTING_STANDARDS.md exemptions and carry a 'Justification:' placeholder"
grep -Fq -- '- [ ] No GenAI-authored code in this PR' <<<"$tdd_block" \
  || fail "the third option must be '- [ ] No GenAI-authored code in this PR'"

# The policy the checkbox is a claim about.
grep -Fq 'https://github.com/ParamountDataManagement/pdm-claude-standards/blob/main/TESTING_STANDARDS.md' "$template" \
  || fail "the template must link TESTING_STANDARDS.md, where Red-Green TDD is mandated"

# Visible on a freshly-opened PR: with every HTML comment stripped — which is what
# GitHub renders — the requirement and all three boxes are still there.
rendered=$(perl -0777 -pe 's/<!--.*?-->//gs' "$template")
# shellcheck disable=SC2016  # backticks are markdown code spans to match literally
grep -Fq -- 'Required on PRs labeled `genai-authored`. Tick exactly one.' <<<"$rendered" \
  || fail "the 'genai-authored' requirement must render — it cannot live inside an HTML comment"
grep -Fq -- "$tdd_confirm" <<<"$rendered" || fail "the TDD confirmation checkbox must render"
grep -Fq -- '- [ ] **TDD exemption**' <<<"$rendered" || fail "the TDD exemption checkbox must render"
grep -Fq -- '- [ ] No GenAI-authored code in this PR' <<<"$rendered" || fail "the third TDD option must render"


echo "pull_request_template.md: regression + GenAI TDD contract lines present, nothing pre-ticked"
