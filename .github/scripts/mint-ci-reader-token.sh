#!/usr/bin/env bash
# Mint a pdm-ci-reader installation token (contents: read, the App's whole
# ceiling) with NO stored key: sign the App JWT with kms:Sign on
# alias/pdm-ci-reader-app and exchange it with GitHub. The steps of
# pdm-ci-tools' actions/mint-ci-reader-token, kept here because that action is
# private and this repository is public.
#
# Needs AWS credentials for /ci-cd/pdm-ci-reader-signer in the environment and
# APP_ID, INSTALLATION_ID, KMS_KEY, GITHUB_OUTPUT. Writes `token=` to
# GITHUB_OUTPUT. Sourcing the file defines the functions and runs nothing, which
# is how tests/mint-ci-reader-token.sh exercises verify_installation_token.
set -euo pipefail

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# verify_installation_token <response-json>: print the token when GitHub's answer
# carries one AND grants exactly contents: read; otherwise fail. Nothing falls
# back to an unverified token.
verify_installation_token() {
  local response=$1 token contents
  token="$(jq -r '.token // empty' <<<"$response")"
  contents="$(jq -r '.permissions.contents // empty' <<<"$response")"
  if [ -z "$token" ]; then
    echo "::error title=pdm-ci-reader mint::GitHub returned no installation token" >&2
    return 1
  fi
  if [ "$contents" != read ]; then
    echo "::error title=pdm-ci-reader mint::installation token grants contents=${contents:-none}, want exactly read" >&2
    return 1
  fi
  printf '%s' "$token"
}

main() {
  : "${APP_ID:?}" "${INSTALLATION_ID:?}" "${KMS_KEY:?}" "${GITHUB_OUTPUT:?}"
  local now header payload signing_input signature response token
  now="$(date +%s)"
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
  signing_input="${header}.${payload}"
  signature="$(aws kms sign --key-id "$KMS_KEY" --message-type RAW \
    --signing-algorithm RSASSA_PKCS1_V1_5_SHA_256 \
    --message "$(printf '%s' "$signing_input" | openssl base64 -A)" \
    --query Signature --output text | openssl base64 -d -A | b64url)"
  response="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${signing_input}.${signature}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")"
  token="$(verify_installation_token "$response")"
  echo "::add-mask::${token}"
  printf 'token=%s\n' "$token" >> "$GITHUB_OUTPUT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
