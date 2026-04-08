# Local Verdaccio flow test

Runs the same Verdaccio config, user registration, clone, build, and selective `lerna publish` flow as [`.github/workflows/start-venv.yaml`](../.github/workflows/start-venv.yaml) (when `useVerdaccio` is true).

## Prerequisites

- Docker
- Node.js / npm (for `curl` JSON parsing and `npx lerna`)
- `NPM_TOKEN` with access to private `@frontegg/*` on npmjs (for `yarn install` in template-and-libs and for Verdaccio uplink auth in the generated config)
- `GH_TOKEN` with read access to `frontegg/template-and-libs`

## Run

```bash
cd /path/to/workflows
export NPM_TOKEN='...'
export GH_TOKEN='...'   # or: export GH_TOKEN="$(gh auth token)"
export TEMPLATE_LIBS_BRANCH='master'   # or your PR branch

# Optional: verify npmjs proxy for a specific package through Verdaccio
export PROXY_CHECK_PACKAGE='@frontegg/some-package'

# Optional: only run through lerna changed, skip version/publish
# export SKIP_PUBLISH=1

bash scripts/test-verdaccio-flow.sh
```

## What it checks

- Verdaccio starts with the explicit `config.yaml` (scoped `@frontegg/*` + `proxy: npmjs`, uplink bearer token).
- User registration via the npm registry HTTP API (non-interactive).
- Clone + `yarn install` + `yarn build:no-cache` on template-and-libs.
- `lerna changed` / publish only when there are changes (no `--force-publish`).
- Optional: `npm view $PROXY_CHECK_PACKAGE --registry http://localhost:4873` exercises the proxy path.

The temp workdir is removed on exit unless you set `KEEP_WORKDIR=1` for debugging.
