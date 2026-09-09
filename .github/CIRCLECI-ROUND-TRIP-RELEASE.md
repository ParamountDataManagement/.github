# CircleCI round-trip release contract

The reusable workflow is the public entry point. Callers must pin
`.github/workflows/circleci-round-trip.yml` to the **post-merge commit on
`main`**, never to a pull-request-only commit. A squash merge changes the
source commit SHA, so a SHA copied from a pull request is not a release
reference.

There is no stable release tag for this workflow yet. Until the merge commit
exists, the central workflow uses `@main` for its internal action reference so
that the action remains reachable after squash merge. As a post-merge release
step:

1. Replace that internal `@main` reference with the resulting immutable `main`
   commit SHA.
2. Update every caller to the same post-merge `main` commit SHA.
3. In a later release, a maintained release tag may replace the SHA only after
   the tag is created and protected according to the repository's release
   policy.

The reusable workflow caps `timeout_seconds` at 1140 seconds. Its GitHub job
has a 20-minute timeout, leaving 60 seconds for runner setup and teardown.
Inputs are validated as decimal integers before any shell arithmetic.
