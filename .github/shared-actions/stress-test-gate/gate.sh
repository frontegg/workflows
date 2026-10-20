#!/usr/bin/env bash
# Serializes the staging stress test across every repository deploying through
# main-with-image.yaml, and skips it when a passing run already covered this deployment.
# All state lives as tags on the AppState remote:
#
#   stress-tested/<env>  Annotated tag on the newest AppState commit a passing stress test
#                        covered. Its message records the stress-tests commit that ran, so a
#                        change to the test itself invalidates it.
#   stress-lock/<env>    Annotated tag held while a run is testing. The remote rejects a push
#                        of a tag that already exists, which makes acquiring it atomic.
#
# "Covered" means the AppState commit that put this deployment's version on <env> is an
# ancestor of stress-tested/<env>. A run only claims commits that were at least
# SETTLE_SECONDS old when it started testing: ArgoCD applies an AppState commit some time
# after it is pushed, so a younger commit may not have been running yet.
#
# Usage: gate.sh acquire | gate.sh complete  (inputs via environment, see action.yaml)
set -euo pipefail

mode=${1:?usage: gate.sh acquire|complete}
stress_tests_sha=$(git -C "${STRESS_TESTS_DIR:?}" rev-parse HEAD)
cd "${APPSTATE_DIR:?}"

marker_tag="stress-tested/${ENVIRONMENT:?}"
lock_tag="stress-lock/${ENVIRONMENT}"
marker_ref="refs/tags/$marker_tag"
lock_ref="refs/tags/$lock_tag"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0}"

output() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

# Copies remote tag $1 into local ref $2; fails when the remote has no such tag.
fetch_tag() { git fetch -q --no-tags origin "+$1:$2" 2>/dev/null; }

read_marker() {
  if fetch_tag "$marker_ref" refs/gate/marker; then
    marker_sha=$(git rev-parse refs/gate/marker)
  else
    marker_sha=""
  fi
}

# Succeeds when the last read marker covers AppState commit $1 with this stress-tests commit.
covered() {
  local my_commit=$1 tested_with
  [ -n "$my_commit" ] && [ -n "$marker_sha" ] || return 1
  tested_with=$(git for-each-ref --format='%(contents)' refs/gate/marker | sed -n 's/^stress-tests: //p')
  if [ "$tested_with" != "$stress_tests_sha" ]; then
    echo "$marker_tag was tested with stress-tests ${tested_with:-<unknown>}, this run has $stress_tests_sha."
    return 1
  fi
  git merge-base --is-ancestor "$my_commit" "refs/gate/marker^{commit}"
}

skip() {
  echo "::notice::Skipping the stress test: $marker_tag already covers AppState commit $1 ($(git for-each-ref --format='%(contents)' refs/gate/marker | sed -n 's/^run: //p'))."
  output covered true
  exit 0
}

try_lock() {
  git tag -f -a -m "run: $run_url" "$lock_tag" origin/master >/dev/null
  git push -q origin "$lock_ref" 2>/dev/null || return 1
  lock_sha=$(git rev-parse "$lock_ref")
  output lock_sha "$lock_sha"
}

release_lock() {
  [ -n "$1" ] || return 0
  git push -q --force-with-lease="$lock_ref:$1" origin ":$lock_ref" ||
    echo "::warning::Could not release $lock_tag; other deployments can take it over after ${LOCK_TTL_SECONDS:-1800}s."
}

break_stale_lock() {
  if ! fetch_tag "$lock_ref" refs/gate/lock; then
    echo "Could not push $lock_tag although nobody holds it; retrying."
    return 0
  fi
  local held_sha since holder
  held_sha=$(git rev-parse refs/gate/lock)
  since=$(git for-each-ref --format='%(taggerdate:unix)' refs/gate/lock)
  holder=$(git for-each-ref --format='%(contents)' refs/gate/lock | sed -n 's/^run: //p')
  if [ -n "$since" ] && (( $(date +%s) - since < LOCK_TTL_SECONDS )); then
    echo "Waiting for $lock_tag, held by ${holder:-<unknown>}."
    return 0
  fi
  echo "::warning::Taking over $lock_tag from ${holder:-<unknown>}: held longer than ${LOCK_TTL_SECONDS}s."
  git push -q --force-with-lease="$lock_ref:$held_sha" origin ":$lock_ref" 2>/dev/null || true
}

acquire() {
  git config user.name "${GITHUB_ACTOR:-stress-test-gate}"
  git config user.email "${GITHUB_ACTOR:-stress-test-gate}@users.noreply.github.com"
  git fetch -q --no-tags origin master

  local file="applications/${REPOSITORY_NAME:?}/$ENVIRONMENT/values.yaml" staged my_commit=""
  staged=$(git show "origin/master:$file" 2>/dev/null | yq '.appVersion' 2>/dev/null || true)
  if [ "$staged" = "${APP_VERSION:?}" ]; then
    my_commit=$(git log -1 --format=%H origin/master -- "$file")
  else
    echo "::warning::$file has appVersion '$staged', not '$APP_VERSION'; running the stress test without reusing earlier results."
  fi

  read_marker
  if covered "$my_commit"; then skip "$my_commit"; fi

  if [ -n "$my_commit" ]; then
    local settle_wait=$(( $(git log -1 --format=%ct "$my_commit") + SETTLE_SECONDS - $(date +%s) ))
    if (( settle_wait > 0 )); then
      echo "Waiting ${settle_wait}s for $ENVIRONMENT to roll out AppState commit $my_commit."
      sleep "$settle_wait"
    fi
  fi

  local deadline=$(( $(date +%s) + LOCK_TIMEOUT_SECONDS ))
  until try_lock; do
    read_marker
    if covered "$my_commit"; then skip "$my_commit"; fi
    if (( $(date +%s) >= deadline )); then
      echo "::error::Timed out after ${LOCK_TIMEOUT_SECONDS}s waiting for $lock_tag."
      exit 1
    fi
    break_stale_lock
    sleep "$POLL_SECONDS"
  done

  # A run holding the lock may have finished and covered us between the last check and our push.
  read_marker
  if covered "$my_commit"; then
    release_lock "$lock_sha"
    output lock_sha ""
    skip "$my_commit"
  fi

  git fetch -q --no-tags origin master
  local tested
  tested=$(git rev-list -1 --before="@$(( $(date +%s) - SETTLE_SECONDS ))" origin/master)
  if [ -n "$my_commit" ] && { [ -z "$tested" ] || ! git merge-base --is-ancestor "$my_commit" "$tested"; }; then
    echo "::warning::AppState commit $my_commit is not yet ${SETTLE_SECONDS}s old; this run's pass will not be recorded for it."
  fi
  echo "Stress testing $ENVIRONMENT as of AppState commit ${tested:-<none>}."
  output covered false
  output tested_sha "$tested"
  output marker_sha "$marker_sha"
}

record_pass() {
  if [ -n "${MARKER_SHA:-}" ] && ! git merge-base --is-ancestor "$MARKER_SHA^{commit}" "$TESTED_SHA"; then
    echo "$marker_tag already covers a newer AppState commit; leaving it."
    return 0
  fi
  git tag -f -a -m "stress-tests: $stress_tests_sha" -m "run: $run_url" "$marker_tag" "$TESTED_SHA" >/dev/null &&
    git push -q --force-with-lease="$marker_ref:${MARKER_SHA:-}" origin "$marker_ref" &&
    echo "Recorded $marker_tag at AppState commit $TESTED_SHA."
}

complete() {
  if [ "${TEST_OUTCOME:-}" = success ] && [ -n "${TESTED_SHA:-}" ]; then
    record_pass || echo "::warning::Could not update $marker_tag; the next deployment will run the stress test again."
  fi
  release_lock "${LOCK_SHA:-}"
}

case "$mode" in
  acquire) acquire ;;
  complete) complete ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac
