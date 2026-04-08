#!/usr/bin/env bash
# Local smoke test for the Verdaccio + selective publish flow used in start-venv.yaml.
# Mirrors: .github/workflows/start-venv.yaml (Write Verdaccio config through Publish changed packages)
#
# Required env:
#   NPM_TOKEN              npm token for uplink proxy to registry.npmjs.org
#   GH_TOKEN               GitHub PAT with repo read for frontegg/template-and-libs
#   TEMPLATE_LIBS_BRANCH   branch or ref to clone (e.g. master or your PR branch)
#
# Optional:
#   PROXY_CHECK_PACKAGE    @frontegg package name to verify npmjs proxy (default: skip if unset)
#   SKIP_PUBLISH           if set to "1", stop after lerna changed (no version/publish)
#   WORKDIR                temp root (default: mktemp)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${NPM_TOKEN:-}" ]]; then
  echo "ERROR: NPM_TOKEN is required"
  exit 1
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "ERROR: GH_TOKEN is required (read access to frontegg/template-and-libs)"
  exit 1
fi
if [[ -z "${TEMPLATE_LIBS_BRANCH:-}" ]]; then
  echo "ERROR: TEMPLATE_LIBS_BRANCH is required"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  echo "ERROR: docker is required"
  exit 1
fi

WORKDIR="${WORKDIR:-$(mktemp -d -t verdaccio-test-XXXXXX)}"
CONFIG_DIR="${WORKDIR}/verdaccio"
SHADOW_LIBS="${WORKDIR}/_shadow-libs"
RUN_ID="${RUN_ID:-$(date +%s)}"

cleanup() {
  docker rm -f verdaccio-test 2>/dev/null || true
  if [[ "${KEEP_WORKDIR:-}" != "1" ]]; then
    rm -rf "${WORKDIR}"
  fi
}
trap cleanup EXIT

mkdir -p "${CONFIG_DIR}"

write_verdaccio_config() {
  cat > "${CONFIG_DIR}/config.yaml" <<EOF
storage: /verdaccio/storage/data
auth:
  htpasswd:
    file: /verdaccio/storage/htpasswd
uplinks:
  npmjs:
    url: https://registry.npmjs.org/
    auth:
      type: bearer
      token: ${NPM_TOKEN}
packages:
  '@frontegg/*':
    access: \$all
    publish: \$all
    proxy: npmjs
  '**':
    access: \$all
    publish: \$all
    proxy: npmjs
listen: 0.0.0.0:4873
EOF
}

echo "==> Workdir: ${WORKDIR}"
write_verdaccio_config
echo "==> Starting Verdaccio (matches CI config shape)"
docker rm -f verdaccio-test 2>/dev/null || true
docker run -d --name verdaccio-test -p 4873:4873 \
  -v "${CONFIG_DIR}/config.yaml:/verdaccio/conf/config.yaml" \
  verdaccio/verdaccio

for i in $(seq 1 40); do
  if curl -sf http://localhost:4873/-/ping >/dev/null; then
    break
  fi
  if [[ "${i}" -eq 40 ]]; then
    echo "ERROR: Verdaccio did not become ready"
    exit 1
  fi
  sleep 1
done
echo "==> Verdaccio is up"

echo "==> Registering Verdaccio user (npm registry API, non-interactive)"
REG_BODY="$(curl -sf -X PUT "http://localhost:4873/-/user/org.couchdb.user:shadow" \
  -H "Content-Type: application/json" \
  -d '{"name":"shadow","password":"shadow","email":"shadow@frontegg.com","type":"user"}')"
VERDACCIO_NPM_TOKEN="$(echo "${REG_BODY}" | node -p "JSON.parse(require('fs').readFileSync(0,'utf8')).token")"
export VERDACCIO_NPM_TOKEN
echo "==> Verdaccio npm token acquired for publish"

echo "==> Cloning template-and-libs @ ${TEMPLATE_LIBS_BRANCH}"
rm -rf "${SHADOW_LIBS}"
git clone --depth 1 -b "${TEMPLATE_LIBS_BRANCH}" \
  "https://x-access-token:${GH_TOKEN}@github.com/frontegg/template-and-libs.git" \
  "${SHADOW_LIBS}"

cd "${SHADOW_LIBS}"
export YARN_NPM_AUTH_TOKEN="${NPM_TOKEN}"

echo "==> yarn install"
yarn install --immutable || YARN_ENABLE_IMMUTABLE_INSTALLS=false yarn install

echo "==> yarn build:no-cache"
yarn build:no-cache

git config user.email "shadow@frontegg.com"
git config user.name "shadow-agent"

echo "==> lerna changed (json)"
CHANGED_JSON="$(npx lerna changed --json 2>/dev/null || echo "[]")"
echo "${CHANGED_JSON}"

if [[ "${CHANGED_JSON}" = "[]" ]]; then
  echo "==> No changed packages — CI would skip publish; Verdaccio proxies all @frontegg/* from npmjs"
else
  if [[ "${SKIP_PUBLISH:-}" = "1" ]]; then
    echo "==> SKIP_PUBLISH=1 — stopping before version/publish"
    exit 0
  fi
  echo "//localhost:4873/:_authToken=${VERDACCIO_NPM_TOKEN}" >> "${SHADOW_LIBS}/.npmrc"

  echo "==> lerna version + publish (no --force-publish)"
  npx lerna version prerelease \
    --no-push \
    --no-git-tag-version \
    --preid "local.${RUN_ID}" \
    --yes

  npx lerna publish from-git \
    --registry http://localhost:4873 \
    --no-verify-access \
    --yes
fi

echo "==> Smoke: registry responds"
curl -sf "http://localhost:4873/-/ping" | head -c 200 || true
echo

if [[ -n "${PROXY_CHECK_PACKAGE:-}" ]]; then
  echo "==> Proxy check: npm view ${PROXY_CHECK_PACKAGE} via Verdaccio"
  npm view "${PROXY_CHECK_PACKAGE}" version --registry http://localhost:4873
fi

echo "==> OK — Verdaccio config, clone, build, and publish/proxy path succeeded"
echo "    Repo root reference: ${REPO_ROOT}"
