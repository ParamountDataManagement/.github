# CircleCI round-trip release contract

The reusable workflow is the public entry point. Callers must pin
`.github/workflows/circleci-round-trip.yml` to the **post-merge commit on
`main`**, never to a pull-request-only commit. A squash merge changes the
source commit SHA, so a SHA copied from a pull request is not a release
reference.

The reusable workflow and its internal composite action are pinned
independently. The workflow is pinned by callers to the post-merge commit that
contains the contract; the workflow pins the internal action to the prior
post-merge commit that contains the action files. For this release:

1. The workflow file was released at `453f0c3d6871c88428aae5b6d49c92efaf2902ad`.
2. Its internal action is pinned to that immutable commit.
3. Callers must be updated to the follow-up workflow commit that contains this
   internal pin before they merge.
4. Future releases repeat the process: merge the workflow change, then pin the
   internal action to the commit produced by that merge and update callers to
   the new workflow commit. A protected release tag may replace these SHA pins
   later.

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

This is a release like the one above: the action change merges first, then a
follow-up commit adds the `format` input to the reusable workflow and pins the
internal action to the merged commit. Callers pin that follow-up commit and pass
`format` explicitly; it has no default.
