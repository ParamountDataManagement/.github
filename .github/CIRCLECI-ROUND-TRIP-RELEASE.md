# CircleCI round-trip release contract

The reusable workflow is the public entry point. Callers must pin
`.github/workflows/circleci-round-trip.yml` to the **post-merge commit on
`main`**, never to a pull-request-only commit. A squash merge changes the
source commit SHA, so a SHA copied from a pull request is not a release
reference.

The reusable workflow and its internal composite action are pinned
independently. The workflow is pinned by callers to the post-merge commit that
contains the contract; the workflow pins the internal action to the prior
post-merge commit that contains the action files. Every release repeats the same
two steps:

1. Merge the action change. Its post-merge commit on `main` is the action
   release reference — a SHA copied from the pull request is not one.
2. Merge a follow-up commit that pins the workflow's internal action to that
   reference, together with any workflow-level contract the change adds.
   Callers are then updated to the post-merge commit of THAT follow-up.

A protected release tag may replace these SHA pins later.

## Releases

| Release | Action commit | Workflow commit callers pin |
|---|---|---|
| Initial | `453f0c3d6871c88428aae5b6d49c92efaf2902ad` | the follow-up that pinned it |
| `format` selection (#8, #9) | `b2bb89190a2f2ab2bbb9460335b04a2bbfe28376` | the commit #9 merges as |

The reusable workflow caps `timeout_seconds` at 1140 seconds. Its GitHub job
has a 20-minute timeout, leaving 60 seconds for runner setup and teardown.
Inputs are validated as decimal integers before any shell arithmetic.

## Format selection

The action takes a required `format` (`excel`, `aces`, `pies`, …). It sends the
pipeline parameter `run-<format>-round-trip` and waits on the workflow
`<format>-round-trip`, so the two names cannot drift apart. The CircleCI
project's config is the authority on which formats exist — it declares those
parameters, and CircleCI rejects an undeclared one — so the action checks only
that the value is a lowercase identifier.

Callers pass `format` explicitly; it has no default, at the action or at the
workflow. The release itself followed the two steps above — see the table.
