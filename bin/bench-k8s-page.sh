#!/usr/bin/env bash
# End-to-end run on a GitHub-hosted runner: do the cache repo's Kubernetes manifests (docs/kubernetes.md at the v0.2.2 tag), which
# /gradle-build-cache-kubernetes/ points to, really work, and does the page's description of them hold?
#   - a kind cluster (Kubernetes in Docker), the four manifests applied as written (Secret, PVC, Deployment, Service), in a namespace that
#     enforces the Pod Security "restricted" profile
#   - ready, the probe on /healthz, the guide's port-forward smoke test, a Gradle build from outside through the port-forward with a server hit
#   - the volume survives a pod delete; a second replica does not share the cache (the guide says it blocks on the lock or fails to start)
#   - what the Deployment says (one replica, Recreate, ReadWriteOnce, security context, resources, probes)
#   - the guide's claim that leaving out FSCACHE_DATA_DIR "appears to work and silently loses everything on every restart"
# Run by the "bench-k8s-page" job of .github/workflows/hygiene.yml (manual dispatch only, choice "k8s-page"). Same method as the other
# bench scripts: the page's text and commands used as written, the server's own counters checked, every promise asserted, a step that fails
# or prints something else is RECORDED (FAIL) and fails the job at the end, observations that are not failures are OBS lines.
#
# No token and no secret. Every download is checked against a pinned checksum or digest: kind, kubectl, cosign, Gradle (sha256); the
# guide file itself (sha256, from the v0.2.2 tag); the kind node image and the FosterStack Cache image (digests). The cache image is
# verified with cosign by digest, then loaded into the cluster, so the cluster pulls nothing at run time (kind pulls its node image).
set -uo pipefail

VER="${BENCH_VER:-0.2.2}"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad release version: $VER" >&2; exit 2; }
LOCAL="${BENCH_LOCAL:-0}"
KIND_VER=v0.33.0
KIND_SHA=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d      # kind-linux-amd64.sha256sum of v0.33.0
KUBECTL_VER=v1.37.0
KUBECTL_SHA=6129359f4e1f3848a5572ccb0b26cf28b8ca08cef38c95a765b2f64a2c961a2f   # dl.k8s.io/release/v1.37.0/bin/linux/amd64/kubectl.sha256
NODE_IMAGE="kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"   # from the kind v0.33.0 release notes
GUIDE_URL="https://raw.githubusercontent.com/fosterstack/cache/v${VER}/docs/kubernetes.md"
GUIDE_SHA_022=9531258862058907a1ab8e1de8268a5d35c003e19d0fb4256c5fa3ff84668db0     # docs/kubernetes.md at tag v0.2.2 (commit 0ac0586dc1b2de70318b82469fa5b35bfa090068)
IMG=ghcr.io/fosterstack/cache
if [ "$VER" = 0.2.2 ]; then GUIDE_NOTE="file sha256 ${GUIDE_SHA_022} checked"; else GUIDE_NOTE="read from the v${VER} tag, its sha256 printed after the download and NOT pinned in this script"; fi
# The production image digest of the release under test comes from the release's OWN published release-manifest.json (no per-version
# digest is kept in this file). Trust does not rest on that file: the image pulled by tag must have exactly this digest, and the
# digest is then verified with cosign against the release workflow's identity for the tag, before anything runs it.
release_digest() { # VERSION -> sha256:...
  local d; d="$(gh release download "v$1" --repo fosterstack/cache -p release-manifest.json -O - 2>/dev/null | python3 -c 'import sys,json; m=json.load(sys.stdin); print([i["digest"] for i in m["images"] if i["variant"]=="production"][0])' 2>/dev/null)" || return 1
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1; printf '%s' "$d"
}
IMG_REL="$(release_digest "$VER")" || { echo "could not read the production image digest from the release manifest of v${VER}" >&2; exit 2; }
GR_VER=9.8.0
GR_URL="https://services.gradle.org/distributions/gradle-${GR_VER}-all.zip"
GR_SHA=46ac66d47f30f3dacfdf306e0b714a91a34fb94a22ba0a744b280933f47bc0cf
COSIGN_VER=3.1.3
COSIGN_SHA=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
CLUSTER=fsbench
NS=fscache-ns
PASS='k8s-test-secret-not-real'            # replaces the guide's CHANGE-ME

FAILS=0
now() { python3 -c 'import time;print(time.time())'; }
fail() { FAILS=$((FAILS+1)); printf 'FAIL %s\n' "$*"; }
sha_check() { if command -v sha256sum >/dev/null 2>&1; then echo "$2  $1" | sha256sum -c - >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }
  else echo "$2  $1" | shasum -a 256 -c - >/dev/null || { echo "CHECKSUM MISMATCH: $1" >&2; exit 2; }; fi; }
if [ -n "${BENCH_WORK:-}" ]; then W="$BENCH_WORK"; mkdir -p "$W"; else W="$(mktemp -d)"; fi
PF_PID=""
stop_pf() { [ -n "$PF_PID" ] && { kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; PF_PID=""; }; return 0; }
cleanup() { stop_pf; kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; [ -z "${BENCH_WORK:-}" ] && [ -n "${W:-}" ] && rm -rf "${W:?}"; }
trap cleanup EXIT

# ---------- tools ----------
mkdir -p "$W/tools/bin"; cd "$W/tools"
if [ "$LOCAL" = 1 ]; then
  command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > bin/sha256sum; chmod +x bin/sha256sum; }
  export PATH="$W/tools/bin:$PATH"
  JAVA21="${BENCH_JAVA_HOME:-$(/usr/libexec/java_home -v 21 2>/dev/null || echo "${JAVA_HOME:-}")}"
else
  unset GH_TOKEN GITHUB_TOKEN
  curl -fsSL -o kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VER}/kind-linux-amd64"; sha_check kind "$KIND_SHA"; install -m 0755 kind bin/kind
  curl -fsSL -o kubectl "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"; sha_check kubectl "$KUBECTL_SHA"; install -m 0755 kubectl bin/kubectl
  curl -fsSL -o cosign "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VER}/cosign-linux-amd64"; sha_check cosign "$COSIGN_SHA"; install -m 0755 cosign bin/cosign
  curl -fsSL -o gr.zip "$GR_URL"; sha_check gr.zip "$GR_SHA"; unzip -q gr.zip; ln -s "$W/tools/gradle-${GR_VER}/bin/gradle" bin/gradle
  export PATH="$W/tools/bin:$PATH"
  JAVA21="${BENCH_JAVA_HOME:-${JAVA_HOME_21_X64:-${JAVA_HOME:-}}}"
fi
[ -x "$JAVA21/bin/java" ] && "$JAVA21/bin/java" -version 2>&1 | head -1 | grep -q '"21\.' || { echo "no usable Java 21 (JAVA_HOME=$JAVA21)" >&2; exit 1; }
export JAVA_HOME="$JAVA21"; export PATH="$JAVA21/bin:$PATH"
for t in kind kubectl docker cosign gradle curl python3; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
export GRADLE_USER_HOME="$W/gradle-home"

echo "== DISCLOSURE"
echo "runner: $(uname -sr); cpus: $(nproc 2>/dev/null || sysctl -n hw.ncpu); image: ${ImageOS:-?} ${ImageVersion:-?}"
echo "kind: $(kind version)   kubectl: $(kubectl version --client 2>/dev/null | head -1)   docker: $(docker --version)   gradle: $(gradle --version 2>/dev/null | grep -E '^Gradle ' | head -1)   java: $(java -version 2>&1 | head -1)"
if [ "$LOCAL" = 1 ]; then echo "tools: LOCAL tools in use, nothing checked (a developer's dry run: do not quote these times)"; else
  echo "tools: kind ${KIND_VER}, kubectl ${KUBECTL_VER}, cosign ${COSIGN_VER} and Gradle ${GR_VER} are downloaded and checked against pinned sha256 values before use; the runner's own Docker and Java 21"; fi
echo "node image (pinned by digest): ${NODE_IMAGE}"
echo "manifests: the Secret, PVC, Deployment and Service blocks of docs/kubernetes.md at the v${VER} tag of fosterstack/cache (${GUIDE_NOTE}), applied as written with two replacements: the image tag X.Y.Z becomes ${VER}, and the password CHANGE-ME becomes a test value; they are applied in the namespace ${NS} (the guide's in-cluster example uses it), which enforces the Pod Security 'restricted' profile"
echo "FosterStack Cache ${VER} image: pulled, compared with the digest the release manifest names (${IMG_REL}), verified with cosign by digest, then loaded into the cluster with 'kind load docker-image' (the cluster itself pulls nothing from the internet at run time except kind's node image, pulled by the runner's Docker)"
echo "invented by this script (the guide shows none): the Gradle project (rootProject.name, build.gradle.kts, App.java) and the build from outside through the guide's own port-forward; the variant Deployment without FSCACHE_DATA_DIR used to test the guide's warning"
echo "limits of this cluster: kind is ONE node with the default local-path StorageClass, so a second pod can mount the same ReadWriteOnce volume (on a multi-node cluster the failure would be a Multi-Attach error instead); the replica test uses 'kubectl scale'; the user ids are read from the pod spec, not from the running process; the fsGroup requirement ('without it the pod crash-loops') is NOT tested, and kind's volumes may be writable anyway"
echo "NOT tested here: a real cloud cluster, a StorageClass other than kind's default, the LoadBalancer Service, Gateway API and Ingress examples, in-cluster runners and the in-cluster DNS name, node sizing, the Kyverno policy, upgrades (Recreate rollouts)"
echo "a runner times commands, not people"

# ---------- helpers ----------
run() { local name="$1" dir="$2" t0 t1; cat > "$W/$name.sh"; t0=$(now); ( cd "$dir" && bash -o pipefail "$W/$name.sh" ) > "$W/$name.out" 2>&1; RC=$?; t1=$(now); EL=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}'); }
expect() { local name="$1"; shift; local ok=yes w; [ "${NOZERO:-0}" = 1 ] || [ "$RC" = 0 ] || ok="NO(exit $RC)"; for w in "$@"; do grep -qF -- "$w" "$W/$name.out" || ok="${ok}; missing: ${w}"; done
  printf 'STEP %-34s %7s s  exit=%s  expected=%s\n' "$name" "$EL" "$RC" "$ok"; case "$ok" in yes) ;; *) FAILS=$((FAILS+1)); sed 's/^/    | /' "$W/$name.out" | tail -14;; esac; }
absent() { local name="$1"; shift; local w; for w in "$@"; do grep -qF -- "$w" "$W/$name.out" && fail "$name: the output contains '${w}'"; done; return 0; }
jp() { kubectl get "$@" 2>/dev/null; }                      # kubectl get ... -o jsonpath=...  (the namespace is the context's default)
check_eq() { # LABEL GOT WANT
  if [ "$2" = "$3" ]; then echo "OBS $1: '$2', as the page says"; else fail "$1: expected '$3', got '$2'"; fi
}
wait_http() { local i; for i in $(seq 1 200); do curl -sf --max-time 3 "localhost:8080/healthz" >/dev/null 2>&1 && return 0; sleep 0.25; done; return 1; }
start_pf() { stop_pf; kubectl port-forward svc/fscache 8080:80 > "$W/pf.log" 2>&1 & PF_PID=$!; wait_http || { fail "the port-forward to svc/fscache did not answer on localhost:8080"; sed 's/^/    | /' "$W/pf.log" | tail -4; return 1; }; }
metric() { curl -s --max-time 10 "localhost:8080/metrics" | sed -n "s/^$1 \([0-9][0-9]*\)\$/\1/p"; }
for p in 8080; do curl -sf --max-time 3 "localhost:$p/healthz" >/dev/null 2>&1 && { echo "something already answers on port $p: not starting" >&2; exit 1; }; done

# ---------- the guide, checked, and its four manifests ----------
curl -fsSL -o "$W/kubernetes.md" "$GUIDE_URL"
if [ "$VER" = 0.2.2 ]; then sha_check "$W/kubernetes.md" "$GUIDE_SHA_022"; else echo "guide of v${VER}: sha256 $(sha256sum "$W/kubernetes.md" | cut -d' ' -f1) (read from the tag, not pinned)"; fi
python3 - "$W/kubernetes.md" "$W/manifests.yaml" "$VER" "$PASS" <<'PYEOF'
import re,sys
md=open(sys.argv[1]).read(); out=sys.argv[2]; ver=sys.argv[3]; pw=sys.argv[4]
blocks=re.findall(r'```yaml\n(.*?)```',md,re.S)
def pick(kind,name):
    for b in blocks:
        if re.search(r'^kind: %s$'%kind,b,re.M) and re.search(r'^  name: %s$'%name,b,re.M): return b
    raise SystemExit('block not found: %s %s'%(kind,name))
parts=[pick('Secret','fscache-auth'),pick('PersistentVolumeClaim','fscache-data'),pick('Deployment','fscache'),pick('Service','fscache')]
text='---\n'.join(p if p.endswith('\n') else p+'\n' for p in parts)
assert text.count('X.Y.Z')==1 and text.count('CHANGE-ME')==1,(text.count('X.Y.Z'),text.count('CHANGE-ME'))
text=text.replace('X.Y.Z',ver).replace('CHANGE-ME',pw)
open(out,'w').write(text)
print('manifests: %d lines, 4 documents'%text.count('\n'))
PYEOF
[ -s "$W/manifests.yaml" ] || { fail "could not extract the four manifests from the guide"; echo "FAILURES $FAILS"; exit 1; }

# ---------- the image: manifest digest, cosign, then into the cluster ----------
pull() { local n; for n in 1 2 3; do docker pull -q "$1" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
pull "$IMG:${VER}" || { fail "could not pull $IMG:${VER}"; echo "FAILURES $FAILS"; exit 1; }
got="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMG:${VER}")"
[ "${got#*@}" = "$IMG_REL" ] || { fail "$IMG:${VER} is ${got#*@}, not the digest the release manifest names (${IMG_REL}): no image is loaded"; echo "FAILURES $FAILS"; exit 1; }
run k-cosign "$W" <<EOF
cosign verify ${IMG}@${IMG_REL} --certificate-identity-regexp="^https://github.com/fosterstack/cache/.github/workflows/stage-promote.yml@refs/tags/v${VER}\$" --certificate-oidc-issuer='https://token.actions.githubusercontent.com'
EOF
expect k-cosign "${IMG_REL}"; [ "$RC" = 0 ] || { fail "the image signature did not verify: nothing is loaded"; echo "FAILURES $FAILS"; exit 1; }

# ---------- the cluster ----------
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
run k-cluster "$W" <<EOF
kind create cluster --name ${CLUSTER} --image '${NODE_IMAGE}' --wait 180s
EOF
expect k-cluster "Set kubectl context to \"kind-${CLUSTER}\""
[ "$RC" = 0 ] || { echo "FAILURES $FAILS"; exit 1; }
kubectl config use-context "kind-${CLUSTER}" >/dev/null
run k-load "$W" <<EOF
kind load docker-image ${IMG}:${VER} --name ${CLUSTER} || { docker save ${IMG}:${VER} -o ${W}/cache-image.tar && kind load image-archive ${W}/cache-image.tar --name ${CLUSTER}; }
EOF
expect k-load
[ "$RC" = 0 ] || { fail "the verified image could not be loaded into the cluster: nothing is applied (the cluster would pull the tag from the registry, unverified)"; echo "FAILURES $FAILS"; exit 1; }
kubectl create namespace "$NS" >/dev/null && kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest >/dev/null
kubectl config set-context --current --namespace="$NS" >/dev/null     # so the guide's commands run as written (no -n)

# ---------- apply, ready ----------
run k-apply "$W" <<EOF
kubectl apply -f ${W}/manifests.yaml
EOF
expect k-apply "secret/fscache-auth created" "persistentvolumeclaim/fscache-data created" "deployment.apps/fscache created" "service/fscache created"
absent k-apply "violate" "Warning"
echo "OBS the four manifests were admitted by a namespace that enforces the Pod Security 'restricted' profile, with no warning"
run k-ready "$W" <<'EOF'
kubectl rollout status deploy/fscache --timeout=240s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=fscache --timeout=60s
kubectl get pods -l app.kubernetes.io/name=fscache
EOF
expect k-ready "successfully rolled out" "condition met" "1/1"
kubectl get events --field-selector reason=FailedCreate 2>/dev/null | grep -qi "PodSecurity" && fail "a PodSecurity admission event was recorded"
# the node used the image that was loaded (verified), not one pulled from the registry
if kubectl get events --field-selector reason=Pulling 2>/dev/null | grep -qi "fosterstack/cache"; then fail "the cluster PULLED the cache image from the registry instead of using the loaded, verified one"; fi
kubectl get events --field-selector reason=Pulled 2>/dev/null | grep -qi "already present on machine" && echo "OBS the node used the cache image that was loaded into it ('already present on machine'), not one pulled from the registry" || fail "no 'already present on machine' event: cannot show that the loaded image was used"
# the PVC is bound
check_eq "PVC phase" "$(jp pvc fscache-data -o jsonpath='{.status.phase}')" "Bound"

# ---------- what the Deployment says ----------
check_eq "replicas" "$(jp deploy fscache -o jsonpath='{.spec.replicas}')" "1"
check_eq "update strategy" "$(jp deploy fscache -o jsonpath='{.spec.strategy.type}')" "Recreate"
check_eq "PVC access mode" "$(jp pvc fscache-data -o jsonpath='{.spec.accessModes[0]}')" "ReadWriteOnce"
check_eq "pod runAsNonRoot" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}')" "true"
check_eq "pod runAsUser" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.securityContext.runAsUser}')" "65532"
check_eq "pod fsGroup" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.securityContext.fsGroup}')" "65532"
check_eq "seccomp profile" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.securityContext.seccompProfile.type}')" "RuntimeDefault"
check_eq "readOnlyRootFilesystem" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}')" "true"
check_eq "allowPrivilegeEscalation" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}')" "false"
check_eq "capabilities drop" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].securityContext.capabilities.drop[0]}')" "ALL"
check_eq "CPU request" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')" "100m"
check_eq "memory request" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}')" "128Mi"
check_eq "memory limit" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')" "512Mi"
check_eq "CPU limit (none, on purpose)" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}')" ""
check_eq "liveness probe path" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}')" "/healthz"
check_eq "readiness probe path" "$(jp deploy fscache -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}')" "/healthz"
for f in privileged hostNetwork hostPID hostIPC hostPath; do
  kubectl get deploy fscache -o yaml 2>/dev/null | grep -qi "$f" && fail "the live Deployment contains '$f', but the page says there is no privileged mode, host networking or host path"
  grep -qi "$f" "$W/manifests.yaml" && fail "the manifests contain '$f'"
done
echo "OBS the live Deployment and the four manifests contain no privileged, hostNetwork, hostPID, hostIPC or hostPath"
# the pod spec the kubelet runs (user and group ids come from the spec; the process itself is not inspected: the image has no shell)
run k-pod-spec "$W" <<'EOF'
kubectl get pod -l app.kubernetes.io/name=fscache -o jsonpath='{.items[0].spec.securityContext.runAsUser}:{.items[0].spec.securityContext.fsGroup}'
EOF
expect k-pod-spec "65532:65532"

# ---------- the guide's port-forward smoke test, as written ----------
start_pf || { echo "FAILURES $FAILS"; exit 1; }
run k-smoke "$W" <<EOF
curl -s localhost:8080/healthz                                   # -> ok
curl -s localhost:8080/metrics | grep fscache_cache
curl -s -u gradle:${PASS} -X PUT --data-binary 'hello' \\
  localhost:8080/testkey123                                      # stores it
curl -s -u gradle:${PASS} localhost:8080/testkey123            # -> hello
curl -s -o /dev/null -w '%{http_code}\\n' localhost:8080/testkey123  # -> 401 without them
EOF
S="$(curl -s --max-time 10 localhost:8080/healthz)"; [ "$S" = ok ] && echo "OBS /healthz answers exactly 'ok' (liveness: it says the process is up, nothing about the disk; the PUT and GET below are what show the volume works)" || fail "/healthz answered '${S}', not exactly ok"
expect k-smoke "ok" "fscache_cache_hits_total" "fscache_cache_misses_total" "hello" "401"
echo "OBS the guide's smoke-test block printed (| = end of line): $(tr '\n' '|' < "$W/k-smoke.out" | cut -c1-200)"

# ---------- a Gradle build from outside through the port-forward, with a server hit ----------
P="$W/proj"; mkdir -p "$P/src/main/java/demo"
cat > "$P/settings.gradle.kts" <<EOF
rootProject.name = "demo"
// FosterStack Cache — remote Gradle build cache.
// https://github.com/fosterstack/cache
buildCache {
    local { isEnabled = false } // so a hit can only come from the remote
    remote<HttpBuildCache> {
        url = uri("http://127.0.0.1:8080/")
        isPush = true
        credentials {
            username = System.getenv("FSCACHE_USERNAME")
            password = System.getenv("FSCACHE_PASSWORD")
        }
    }
}
EOF
printf 'plugins { java }\n' > "$P/build.gradle.kts"; printf 'org.gradle.caching=true\n' > "$P/gradle.properties"
printf 'package demo;\n\npublic class App {\n    public static void main(String[] args) {\n        System.out.println("hello");\n    }\n}\n' > "$P/src/main/java/demo/App.java"
gb() { # NAME  (the project through the port-forward, with the credentials in the environment as the guide's runner example does)
  run "$1" "$P" <<EOF
export FSCACHE_USERNAME=gradle FSCACHE_PASSWORD='${PASS}'
gradle build --build-cache
gradle clean
gradle build --build-cache
EOF
}
H0="$(metric fscache_cache_hits_total)"
gb k-gradle1
expect k-gradle1 "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
H1="$(metric fscache_cache_hits_total)"
echo "OBS the cache's hit counter through the port-forward: ${H0} -> ${H1}"
[ "$H1" -gt "$H0" ] 2>/dev/null || fail "Gradle printed FROM-CACHE but the server's hit counter did not move (${H0} -> ${H1})"

# ---------- the volume survives a pod delete ----------
stop_pf
run k-delete-pod "$W" <<'EOF'
kubectl delete pod -l app.kubernetes.io/name=fscache --wait=true
kubectl rollout status deploy/fscache --timeout=240s
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=fscache --timeout=120s
EOF
expect k-delete-pod "condition met"
start_pf || { echo "FAILURES $FAILS"; exit 1; }
S="$(curl -s --max-time 10 -u "gradle:${PASS}" localhost:8080/testkey123)"; [ "$S" = hello ] && echo "OBS after deleting the pod, the stored key 'testkey123' is still there (the volume survived)" || fail "after deleting the pod, testkey123 reads '${S}', not hello: the volume did not survive"
H0="$(metric fscache_cache_hits_total)"
run k-gradle2 "$P" <<EOF
export FSCACHE_USERNAME=gradle FSCACHE_PASSWORD='${PASS}'
gradle clean
gradle build --build-cache
EOF
expect k-gradle2 "BUILD SUCCESSFUL" "> Task :compileJava FROM-CACHE"
H1="$(metric fscache_cache_hits_total)"; echo "OBS after the pod was replaced, a build still restored from the server (hit counter ${H0} -> ${H1}; the counter itself restarts with the pod)"
[ "$H1" -gt "$H0" ] 2>/dev/null || fail "after the pod delete, FROM-CACHE was printed but the new pod's hit counter did not move (${H0} -> ${H1})"
gradle --stop >/dev/null 2>&1 || true

# ---------- a second replica does not share the cache ----------
stop_pf
run k-scale2 "$W" <<'EOF'
kubectl scale deploy/fscache --replicas=2
sleep 45
kubectl get pods -l app.kubernetes.io/name=fscache
EOF
expect k-scale2
READY2="$(kubectl get pods -l app.kubernetes.io/name=fscache -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$')"
SECOND="$(kubectl get pods -l app.kubernetes.io/name=fscache -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | awk '$2!="true"{print $1}' | head -1)"
if [ "$READY2" = 1 ] && [ -n "$SECOND" ]; then echo "OBS with replicas: 2 exactly 1 of 2 pods is Ready after 45 s, as the page says (the second blocks on the lock or fails to start)"; else fail "with replicas: 2 the page says the second pod does not share the cache; expected exactly 1 pod Ready, found ${READY2} ready (second pod: '${SECOND}')"; fi
if [ -n "$SECOND" ]; then
  PH2="$(kubectl get pod "$SECOND" -o jsonpath='{.status.phase}' 2>/dev/null)"
  [ "$PH2" = Running ] || fail "the second pod is not Ready because of something other than the lock: its phase is '${PH2}' (Pending, an image error or no room would not be the lock)"
  L2="$( { kubectl logs "$SECOND" 2>&1; kubectl logs "$SECOND" --previous 2>&1; } | tr '\n' '|' | cut -c1-400)"
  case "$L2" in *"open: timeout"*) echo "OBS the second pod ($SECOND) failed on the metadata lock: ${L2}";; *) fail "the second pod is not Ready, but its log does not show the metadata lock timeout (${L2})";; esac
fi
kubectl scale deploy/fscache --replicas=1 >/dev/null; kubectl rollout status deploy/fscache --timeout=180s >/dev/null 2>&1

# ---------- the guide's warning: without FSCACHE_DATA_DIR ----------
python3 - "$W/manifests.yaml" "$W/no-datadir.yaml" <<'PYEOF'
import sys,re
t=open(sys.argv[1]).read()
n=t.count('            - name: FSCACHE_DATA_DIR\n              value: /data        # required — see "The data directory"\n')
assert n==1,n
t=t.replace('            - name: FSCACHE_DATA_DIR\n              value: /data        # required — see "The data directory"\n','')
open(sys.argv[2],'w').write(t)
PYEOF
run k-nodatadir "$W" <<EOF
kubectl apply -f ${W}/no-datadir.yaml
sleep 40
kubectl get pods -l app.kubernetes.io/name=fscache
EOF
expect k-nodatadir "deployment.apps/fscache configured"
ND_READY="$(kubectl get pods -l app.kubernetes.io/name=fscache -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$')"
ND_POD="$(kubectl get pods -l app.kubernetes.io/name=fscache --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
echo "OBS without FSCACHE_DATA_DIR: ${ND_READY} pod(s) Ready; the newest pod ${ND_POD} says: $(kubectl logs "$ND_POD" 2>&1 | tail -3 | tr '\n' '|' | cut -c1-320)"
if [ "$ND_READY" -ge 1 ]; then
  fail "without FSCACHE_DATA_DIR and with the guide's readOnlyRootFilesystem the pod became Ready; the previous run showed it does not start (this run's assertion follows that observation)"
  start_pf && { curl -s --max-time 10 -u "gradle:${PASS}" -X PUT --data-binary 'gone' localhost:8080/lostkey >/dev/null; stop_pf; kubectl delete pod -l app.kubernetes.io/name=fscache --wait=true >/dev/null 2>&1; kubectl rollout status deploy/fscache --timeout=180s >/dev/null 2>&1; start_pf && echo "OBS without FSCACHE_DATA_DIR, after a pod delete 'lostkey' reads: HTTP $(curl -s -o /dev/null -w '%{http_code}' -u "gradle:${PASS}" localhost:8080/lostkey)"; }
else
  kubectl logs "$ND_POD" 2>&1 | grep -q "read-only file system" || fail "without FSCACHE_DATA_DIR the pod is not Ready, but its log does not show the read-only file system error"
  echo "OBS FINDING? the guide says that without FSCACHE_DATA_DIR the server 'appears to work and silently loses everything on every restart' (the data goes to the pod's writable layer); with the guide's own readOnlyRootFilesystem: true the pod is not Ready instead (above), so it does not appear to work"
fi
stop_pf
echo
echo "FAILURES $FAILS"
[ "$FAILS" = 0 ] && echo "== ALL STEPS PASSED" || echo "== AT LEAST ONE STEP FAILED (see FAIL, STEP and OBS lines above)"
[ "$FAILS" = 0 ]
