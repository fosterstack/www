#!/usr/bin/env bash
# Runs INSIDE a fresh debian container, started by bin/bench-verify-release.sh. It does what a reader of
# /verify-a-release/ does, with the page's commands word for word, and times every step.
#
# Environment: VER ("0.2.1", or "latest" to set it with the page's own command), PLATFORM, TOKEN_FOR_STEPS_5_TO_7.
# The token is exported as GH_TOKEN only for steps 5 to 7, because the page says only those need one.
set -u
# take the token out of the environment right away: only steps 5 to 7 may see it
TOK="${TOKEN_FOR_STEPS_5_TO_7:-}"
unset TOKEN_FOR_STEPS_5_TO_7
VER_ARG="${VER:-0.2.1}"
PLATFORM="${PLATFORM:-linux_amd64}"
OUT=/tmp/out; mkdir -p "$OUT" /work
FAILS=0
now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

# ---------- install only what the page tells you to install (timed separately, not part of the claim) ----------
T0=$(now)
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl ca-certificates jq tar >/dev/null 2>&1
COSIGN_VER=3.1.3; COSIGN_SHA=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71   # cosign_checksums.txt of v3.1.3, cosign-linux-amd64
GH_VER=2.102.0;   GH_SHA=bb766f710eef8ede859c18578c72c327597cd4c8a85b06001b1f3843c6019386        # gh_2.102.0_checksums.txt, linux_amd64 tarball
cd /tmp
curl -fsSL -o cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-linux-amd64"
echo "${COSIGN_SHA}  cosign" | sha256sum -c - >/dev/null || { echo "TOOL CHECKSUM MISMATCH: cosign"; exit 2; }
install -m 0755 cosign /usr/local/bin/cosign
curl -fsSL -o gh.tgz "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_amd64.tar.gz"
echo "${GH_SHA}  gh.tgz" | sha256sum -c - >/dev/null || { echo "TOOL CHECKSUM MISMATCH: gh"; exit 2; }
tar -xzf gh.tgz && install -m 0755 "gh_${GH_VER}_linux_amd64/bin/gh" /usr/local/bin/gh
T1=$(now)
echo "TOOLS curl=$(curl --version | head -1 | cut -d' ' -f2) jq=$(jq --version) cosign=v${COSIGN_VER} gh=${GH_VER}"
echo "INSTALL_SECONDS $(secs "$T0" "$T1")  (apt: curl ca-certificates jq tar, from Debian, not version-pinned; cosign and gh pinned and checked. NOT included in the step totals below)"

# ---------- the page, step by step ----------
cd /work
ROWS=""
run_step() { # name, expected-substring-file-or-text ; command comes from $OUT/cmd
  local name="$1" t0 t1 rc ok el
  t0=$(now)
  bash -o pipefail -c "cd /work && $(cat "$OUT/cmd")" >"$OUT/$name.out" 2>&1; rc=$?
  t1=$(now); el=$(secs "$t0" "$t1")
  ok=yes
  shift
  for want in "$@"; do grep -qF -- "$want" "$OUT/$name.out" || { ok="NO(missing: $want)"; }; done
  [ "$rc" = 0 ] || ok="NO(exit $rc; ${ok})"
  case "$ok" in yes) ;; *) FAILS=$((FAILS+1)); sed 's/^/    | /' "$OUT/$name.out" | head -8 ;; esac
  printf 'STEP %-22s %7s s  exit=%s  expected=%s\n' "$name" "$el" "$rc" "$ok"
  eval "SEC_${name//-/_}=$el"
}

if [ "$VER_ARG" = latest ]; then
  cat >"$OUT/cmd" <<'EOF'
VER=$(curl -fsSL https://api.github.com/repos/fosterstack/cache/releases/latest \
 | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p')
echo "$VER" > /tmp/ver
EOF
  run_step 0-latest-version
  VER=$(cat /tmp/ver)
else
  VER="$VER_ARG"
fi
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION NOT A VERSION NUMBER: refusing to continue"; exit 2; }
export VER PLATFORM
TAR="fscache_${VER}_${PLATFORM}.tar.gz"
echo "VERSION_UNDER_TEST $VER $PLATFORM (asked for: $VER_ARG)"

cat >"$OUT/cmd" <<'EOF'
gh release download v${VER} --repo fosterstack/cache \
 -p checksums.txt -p checksums.txt.bundle \
 -p "fscache_${VER}_${PLATFORM}.tar.gz" \
 -p "fscache_${VER}_${PLATFORM}.tar.gz.sbom.json" \
 -p fosterstack-cache.openvex.json -p release-manifest.json
ls -1
EOF
run_step 1-download "$TAR" release-manifest.json checksums.txt.bundle

cat >"$OUT/cmd" <<'EOF'
cosign verify-blob \
 --bundle checksums.txt.bundle \
 --certificate-identity-regexp='^https://github.com/fosterstack/cache/' \
 --certificate-oidc-issuer='https://token.actions.githubusercontent.com' \
 checksums.txt
EOF
run_step 2-checksums-signature "Verified OK"

cat >"$OUT/cmd" <<'EOF'
sha256sum -c <(grep "fscache_${VER}_${PLATFORM}.tar.gz" checksums.txt | grep -v sbom)
EOF
run_step 3-checksum-match "${TAR}: OK"

PROD=$(jq -r '.images[] | select(.variant=="production") | .digest' release-manifest.json 2>/dev/null || true)
if [[ ! "$PROD" =~ ^sha256:[0-9a-f]{64}$ ]]; then echo "NO PRODUCTION DIGEST in release-manifest.json (step 1 failed?): the digest checks below will fail"; FAILS=$((FAILS+1)); PROD="sha256:MISSING"; fi
cat >"$OUT/cmd" <<'EOF'
cosign verify ghcr.io/fosterstack/cache:${VER} \
 --certificate-identity-regexp="^https://github.com/fosterstack/cache/.github/workflows/stage-promote.yml@refs/tags/v${VER}$" \
 --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
EOF
run_step 4-image-signature "The cosign claims were validated" "$PROD"
cat >"$OUT/cmd" <<'EOF'
cosign verify docker.io/fosterstack/cache:${VER} \
 --certificate-identity-regexp="^https://github.com/fosterstack/cache/.github/workflows/stage-promote.yml@refs/tags/v${VER}$" \
 --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
EOF
run_step 4b-image-signature-dockerio "The cosign claims were validated" "$PROD"

# steps 5 to 7: the page says these need a token (GH_TOKEN or gh auth login)
export GH_TOKEN="$TOK"
cat >"$OUT/cmd" <<'EOF'
gh attestation verify oci://ghcr.io/fosterstack/cache:${VER} \
 --repo fosterstack/cache \
 --signer-workflow fosterstack/cache/.github/workflows/stage-image.yml \
 --source-ref "refs/tags/v${VER}" \
 --format json | jq '.[0].verificationResult | {statement: .statement.predicateType, image: .statement.subject[0].digest, signer: .signature.certificate.subjectAlternativeName, run: .signature.certificate.runInvocationURI}'
EOF
run_step 5-image-provenance "https://slsa.dev/provenance/v1" "stage-image.yml@refs/tags/v${VER}" "${PROD#sha256:}"

cat >"$OUT/cmd" <<'EOF'
gh attestation verify "fscache_${VER}_${PLATFORM}.tar.gz" --repo fosterstack/cache \
 --format json | jq -r '.[0].verificationResult.statement.subject[].name, .[0].verificationResult.signature.certificate.subjectAlternativeName'
EOF
run_step 6-download-provenance "$TAR" "stage-build.yml@refs/tags/v${VER}"

cat >"$OUT/cmd" <<'EOF'
gh attestation verify oci://ghcr.io/fosterstack/cache:${VER} \
 --repo fosterstack/cache \
 --signer-workflow fosterstack/cache/.github/workflows/stage-authorize.yml \
 --predicate-type https://fosterstack.com/attestations/release-authorization/v1 \
 --format json | jq '.[0].verificationResult | {predicateType: .statement.predicateType, signer: .signature.certificate.subjectAlternativeName}'
EOF
run_step 7-release-authorization "release-authorization/v1" "stage-authorize.yml@refs/tags/v${VER}"
unset GH_TOKEN

cat >"$OUT/cmd" <<'EOF'
jq '{spdxVersion, name, packages: (.packages | length)}' "fscache_${VER}_${PLATFORM}.tar.gz.sbom.json"
jq -r '.packages[0:4][] | "\(.name) \(.versionInfo)"' "fscache_${VER}_${PLATFORM}.tar.gz.sbom.json"
EOF
run_step 8-sbom "SPDX-2.3" "github.com/fosterstack/cache v${VER}"

cat >"$OUT/cmd" <<'EOF'
jq -r '.statements[] | "\(.vulnerability.name) \(.status) \(.justification)"' fosterstack-cache.openvex.json
EOF
run_step 9-vex "not_affected"

cat >"$OUT/cmd" <<'EOF'
jq -r '.images[] | "\(.variant) \(.digest)"' release-manifest.json
jq -c '.images[0].refs' release-manifest.json
jq '.verified_statements | length' release-manifest.json
EOF
run_step 10-manifest "production ${PROD}" "docker.io/fosterstack/cache@${PROD}"

# for the page's own release, also check every literal value the page prints
if [ "$VER" = 0.2.1 ]; then
  echo "PAGE_VALUES (the numbers the page prints for 0.2.1):"
  chk() { grep -qF -- "$2" "$OUT/$1.out" && echo "  ok   $3" || { echo "  DIFF $3 (page says: $2)"; FAILS=$((FAILS+1)); }; }
  chk 4-image-signature   "sha256:8df991b5febdf5b4a177325b8af95b6bb6c321059e1715c06cb659c659f5a4f0" "step 4 digest"
  chk 5-image-provenance  "runs/35554556056/attempts/1" "step 5 run link"
  chk 8-sbom              '"packages": 13' "step 8 package count"
  chk 8-sbom              "github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822" "step 8 fourth package"
  chk 9-vex               "CVE-2025-46394 not_affected vulnerable_code_not_in_execute_path" "step 9 statements"
  chk 10-manifest         "debug sha256:e2e502f44d8bd9e6967cb160aabeb012e8520ebba0faa88e130143fe534f282e" "step 10 debug digest"
  chk 10-manifest         "fips sha256:e125fe3f6ed2c18c478453300ba2b787a42999edf66a39403877efb39865ab1b" "step 10 fips digest"
  grep -qx "43" "$OUT/10-manifest.out" && echo "  ok   step 10 statements: 43" || { echo "  DIFF step 10 statements (page says 43)"; FAILS=$((FAILS+1)); }
else
  echo "VALUES for $VER (what the page would print): production $PROD; statements $(jq '.verified_statements | length' release-manifest.json); packages $(jq '.packages | length' "fscache_${VER}_${PLATFORM}.tar.gz.sbom.json"); vex lines $(jq '.statements | length' fosterstack-cache.openvex.json)"
fi

V=$(awk -v a="${SEC_1_download:-0}" -v b="${SEC_2_checksums_signature:-0}" -v c="${SEC_3_checksum_match:-0}" -v d="${SEC_4_image_signature:-0}" -v e="${SEC_5_image_provenance:-0}" -v f="${SEC_6_download_provenance:-0}" -v g="${SEC_7_release_authorization:-0}" 'BEGIN{printf "%.2f", a+b+c+d+e+f+g}')
ALL=$(awk -v v="$V" -v a="${SEC_4b_image_signature_dockerio:-0}" -v b="${SEC_8_sbom:-0}" -v c="${SEC_9_vex:-0}" -v d="${SEC_10_manifest:-0}" 'BEGIN{printf "%.2f", v+a+b+c+d}')
echo "TOTAL_STEPS_1_TO_7_SECONDS $V"
echo "TOTAL_ALL_STEPS_SECONDS $ALL"
echo "STEP_FAILURES $FAILS"
[ "$FAILS" = 0 ]
