#!/bin/bash
# windows-sign-gate.sh — the spec 34 §4 enablement gate for the windows
# legs (the factory mirror of tebako-runtime-ruby's ci/windows-sign-gate.sh,
# itself tamatebako/tebako PR #566's). The repo variable
# WINDOWS_SIGNING_ENABLED=true arms Azure Trusted Signing (Authenticode)
# for the leg's shipped PE artifact (the wrapper exe —
# tebako-runtime-launcher — fetch-staged at .packager/wrapper/ and copied
# to sign-staging/ for the extension-enumerated signing pass; the release
# ships no DLL today, and the windows env image omits the preload shim);
# anything else ships unsigned BY DESIGN (spec 00 invariant 7: unsigned
# stays first-class) and this step is a loud notice. Armed but a
# secret/variable unresolved is a FAST named failure BEFORE any signing
# call — never a partial release (spec 34 §7.5).
#
# Emits armed=<true|false> to GITHUB_OUTPUT; the leg's PE-staging,
# azure/login, artifact-signing and signtool-verify steps all gate on
# it. No re-hash step exists here: the sign block runs BEFORE tools/build
# pairs the wrapper into out/ and computes the .sha256 sidecar + the
# release shard's digest, so every published hash anchors the SIGNED
# bytes by construction (spec 34 §1.3 sign-then-hash; the wrapper smoke
# inside tools/build then exercises exactly the shipped bytes).
#
# Required env when armed (spec 34 §3): AZURE_CLIENT_ID,
# AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID (org secrets — the OIDC
# identity; no AZURE_CLIENT_SECRET exists anywhere), AZURE_ENDPOINT,
# AZURE_SIGNING_ACCOUNT_NAME, AZURE_SIGNING_CERT_PROFILE (org
# variables). Runner env: WINDOWS_SIGNING_ENABLED (from vars.),
# GITHUB_OUTPUT.
set -euo pipefail

if [ "${WINDOWS_SIGNING_ENABLED:-false}" != "true" ]; then
  echo "::notice::spec 34: WINDOWS_SIGNING_ENABLED != true — this leg ships UNSIGNED (spec 00 invariant 7)"
  echo "armed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

missing=""
for v in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID \
         AZURE_ENDPOINT AZURE_SIGNING_ACCOUNT_NAME AZURE_SIGNING_CERT_PROFILE; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "::error::WINDOWS_SIGNING_ENABLED=true but unset:$missing — spec 34 §7.5: fast failure before any signing call, never a partial release"
  exit 1
fi

echo "armed=true" >> "$GITHUB_OUTPUT"
echo "spec 34: signing armed — Artifact Signing account $AZURE_SIGNING_ACCOUNT_NAME / profile $AZURE_SIGNING_CERT_PROFILE ($AZURE_ENDPOINT)"
