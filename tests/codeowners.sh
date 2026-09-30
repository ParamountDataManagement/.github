#!/usr/bin/env bash
# Focused executable tests for the repository CODEOWNERS.
#
# The org promotion rulesets (org-qa-branch-baseline, org-release-branch-baseline,
# org-beta-branch-baseline) require a code owner's approval. GitHub silently
# ignores a CODEOWNERS file it cannot use, and a line it cannot parse, so an edit
# that breaks the syntax or drops the catch-all rule would turn that requirement
# back into a no-op without failing anything. These pins are that failure.
#
# The file is written by pdm-ci-tools rulesets/sync-codeowners.sh. A change to the
# owners belongs there, and lands here as a pull request that must update this pin.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
codeowners="$root_dir/.github/CODEOWNERS"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$codeowners" ]] || fail "missing $codeowners"

# GitHub reads the first CODEOWNERS it finds in .github/, the root, then docs/.
# A second copy is a file someone will edit believing it is the live one.
for shadow in "$root_dir/CODEOWNERS" "$root_dir/docs/CODEOWNERS"; do
  [[ ! -e "$shadow" ]] || fail "$shadow must not exist — .github/CODEOWNERS is the only owners file"
done

# The managed-file header, so an editor learns the sweep overwrites local edits.
head -n 1 "$codeowners" | grep -Fqx '# Managed by pdm-ci-tools rulesets/sync-codeowners.sh. Edits here are overwritten.' \
  || fail "the first line must be the pdm-ci-tools sync-codeowners.sh managed-file header"

# Exactly one rule: the whole repository, owned by the reviewers team. Every
# non-blank, non-comment line is a rule, so this also rejects a stray or
# malformed line that GitHub would skip.
rules=$(grep -Ev '^[[:space:]]*(#|$)' "$codeowners")
[[ "$rules" == '* @ParamountDataManagement/pdm-reviewers' ]] \
  || fail "the only rule must be '* @ParamountDataManagement/pdm-reviewers', found: $rules"

echo "CODEOWNERS: single catch-all rule owned by @ParamountDataManagement/pdm-reviewers"
