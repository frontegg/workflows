# CLAUDE.md

Guidance for Claude Code when working in `frontegg/workflows`.

## What this repo is

The centralized CI/CD library for every Frontegg service repo. It contains **no
application code** — no package.json, no tests, no build step. Everything ships
from `.github/`.

Because consumers reference this repo at `@master`, **anything merged to master
is live for all services immediately**. There is no staged rollout of the
workflows themselves. Treat every change to master as a production change.

## Layout

| Path | What it holds |
| --- | --- |
| `.github/workflows/*.yaml` | Reusable workflows (`on: workflow_call`), called by service repos |
| `.github/shared-actions/*/action.yaml` | Composite actions, consumed by local path |
| `.github/archive/` | Retired workflows, kept for reference — not referenced by anything |
| `.github/CODEOWNERS` | `@devops` owns everything; all PRs need their review |

Two files are dead weight and safe to ignore:
`.github/shared-actions/build-publish-image/old.yaml` and everything in
`.github/archive/`.

## The two consumption patterns

**Reusable workflows** are referenced cross-repo with a hardcoded ref:

```yaml
uses: frontegg/workflows/.github/workflows/main-with-image.yaml@master
```

**Composite actions cannot be referenced cross-repo here.** They are used by
local path, so any job that calls one must first check this repo out into
`workflows/`:

```yaml
- name: Checkout workflows
  uses: actions/checkout@v4
  with:
    repository: frontegg/workflows
    path: workflows
    ref: ${{ inputs.workflows_version }}
- uses: ./workflows/.github/shared-actions/tag-versions
```

Forgetting that checkout step is the most common failure when adding a shared
action to a job. Note the asymmetry: the checkout honors `workflows_version`,
but the `uses:` line at workflow level is pinned to `@master` — pinning a
version only affects the composite actions, not the reusable workflows.

## How deployment actually works

Nothing in this repo talks to a cluster. Deployment is GitOps:

1. `params` derives `short_sha` from `inputs.tag`, falling back to
   `git rev-parse --short HEAD` of the service repo.
2. `build-and-publish-docker` runs `docker manifest inspect` first and **skips
   the build entirely if `frontegg/<repo>:<short_sha>` already exists** — reruns
   are idempotent and cheap.
3. `tag-versions` (composite) writes `appVersion` and `workflowRunId` into
   `applications/<repo>/<environment>/values.yaml` in the **`frontegg/AppState`**
   repo via `yq`, then commits and pushes with rebase-and-retry (5 attempts,
   exponential backoff) because parallel deployments race on that repo.
4. ArgoCD reconciles AppState. The workflow never waits for the rollout.

`tag-versions` also pushes git tags into the service repo:
- `<env>-<YYYYMMDD.HHMMSS>-<short_sha>` — immutable audit tag
- `<env>` — force-moved pointer to the currently deployed commit
- `venv-latest` — force-moved, staging only

## Promotion chain

`main.yaml` is the entry point services call; it delegates to
`main-with-image.yaml`, whose jobs run strictly in order:

```
params -> build-and-publish-docker -> deploy-to-staging
       -> deploy-to-australia (also deploys production-uk in the same job)
       -> deploy-to-us -> deploy-to-global
```

Each deploy job declares a GitHub `environment:`, so protection rules and manual
approvals are configured in GitHub, not here. Note that **UK is deployed inside
the Australia job** — there is no separate `deploy-to-uk` job, and no
`deploy_uk` input to disable it.

Gates that can block a deploy:
- **Split.io** — `allow-deployments` flag is evaluated per environment via
  `frontegg/split-evaluator-action`; the job hard-fails when it is not `on`.
  This is the global deployment freeze switch.
- **Checkly** — `frontegg/pre-deploy-workflow-checks` runs against staging
  before AU. Disable with `run_checkly_validation: false`.
- **k6 stress tests** — pulled from `frontegg/stress-tests`, run before AU.
  Disable with `run_stress_tests: false`.

## venv (virtual environments)

Ephemeral full-stack environments on the dev cluster, used for PR testing.
`start-venv.yaml` composes environment files into the **`frontegg/venv`** repo
(helpers live in `frontegg/venv-actions`), builds each service image via a
generated matrix, then `wait-for-venv` logs into the in-cluster ArgoCD and waits
on `argocd app wait -l venv=<environmentId>` for sync, operation, and health.

- Lease is 1-6 hours (`leaseTime`), default 1; `terminationProtection` opts out.
- Default domain is `venv.life`; `volatileEnvironment` gives a random host.
- Outputs `apiUrl`, `portalUrl`, `environmentId` for downstream test jobs.
- On failure the workflow notifies Slack and calls the removal path, so a failed
  venv should not linger.

Test suites come in `-no-venv` and venv-provisioning pairs
(`run-api-tests`, `run-e2e-tests`, `full-test-suite`, `full-test-suite-two-venvs`,
`sdk-test-suite`, `dashboard-test-suite`, `ai-agent-test-suite`). Pick the
`-no-venv` variant when the caller already has an environment.

## Conventions

- **Branch and PR titles carry a Jira key.** `pull-request.yaml` runs
  `gajira-find-issue-key` against the PR title and fails without one. Commit
  subjects follow `FR-xxxxx <description>`. Two escape hatches are hardcoded:
  titles starting with `Update Routes Config` or `[Cycode]` map to fixed keys.
- **Commented-out code is intentional.** The `check-changes` job in `main.yaml`,
  the `main-without-image` call, and the docker manifest tagging in
  `tag-versions` are all disabled in place and get toggled during incidents. Do
  not delete them as cleanup — ask first.
- **Secret name casing is inconsistent across the boundary.** `main.yaml`
  accepts SCREAMING_CASE (`SPLIT_CHECK_DEPLOYMENT_API_KEY`, `CHECKLY_API_KEY`)
  and maps them to lowercase for `main-with-image.yaml` (`split_api_key`,
  `checkly_api_key`). Keep both sides in sync when adding a secret.
- Inputs default to permissive (`deploy_au`, `deploy_us`, `run_stress_tests`,
  `run_checkly_validation` are all `true`), so a new input that gates a step
  should default to preserving current behavior.

## Verifying a change

There is no local test suite. Options, in order of preference:

1. `actionlint` for syntax and expression errors.
2. Push the branch and call it from a consumer repo with
   `uses: frontegg/workflows/.github/workflows/<file>@<your-branch>` and
   `workflows_version: <your-branch>` so the shared-action checkout matches.
3. For venv changes, trigger `start-venv` from a service repo on your branch.

Never validate by merging to master first.

## External repos this depends on

`frontegg/AppState` (GitOps state) · `frontegg/venv` and `frontegg/venv-actions`
(ephemeral environments) · `frontegg/stress-tests` (k6) ·
`frontegg/split-evaluator-action` · `frontegg/pre-deploy-workflow-checks`
