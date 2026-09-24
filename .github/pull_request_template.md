<!-- PDM pull request template — the org default from ParamountDataManagement/.github.
     A repository with its own .github/pull_request_template.md overrides this file;
     carry the "Regression coverage" block into it verbatim. -->

## Summary

<!-- What changed and why, in a paragraph. The diff says how. -->

## ClickUp

- Task: CU-

## Regression coverage

<!-- Required on bug-fix PRs: title `fix:` / `fix(scope):` / `fix!:`, or the `bug` label.
     Tick exactly one. The `regression-evidence` check reads the title, the labels, the diff
     and the exception line below. Policy, markers and the exception rules:
     https://github.com/ParamountDataManagement/pdm-claude-standards/blob/main/REGRESSION_TESTING_POLICY.md -->

- [ ] **Regression test added** — linked bug ticket, and a test that fails without the fix, tagged per the repo convention (RSpec `regression: 'CU-…'` · Vitest `tags: ['regression']` · Playwright `@regression` + annotation · Go `TestRegression…` · pytest `@pytest.mark.regression`)
- [ ] **Regression exception** — no practical automated test surface. Reason: <!-- replace this comment with the reason; the CI check reads this line -->
- [ ] Not a bug fix

## TDD on GenAI-authored work

Required on PRs labeled `genai-authored`. Tick exactly one.

<!-- The reviewer is the final gate on agent-written code, so a ticked box here is a claim
     you are making to them. Red->Green means the test was RUN and seen to fail for the
     right reason before the implementation existed - not written afterwards to match it.
     Policy:
     https://github.com/ParamountDataManagement/pdm-claude-standards/blob/main/TESTING_STANDARDS.md -->

- [ ] **Red→Green TDD followed** — every behaviour change here was written test-first: the test ran and failed for the right reason before the implementation, then passed unchanged
- [ ] **TDD exemption** — trivial change, emergency hotfix (tests follow within 48h, ClickUp task linked), or refactor already covered by tests. Justification: <!-- replace this comment with which exemption applies and why -->
- [ ] No GenAI-authored code in this PR

## Validation

<!-- Commands run and their results, or the CI jobs that prove the change. -->
