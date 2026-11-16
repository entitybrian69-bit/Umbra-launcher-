#!/usr/bin/env bash
# Commit the evidence files a CI job wrote and push them to the branch that
# triggered the run.
#
# A bare `git push` at the end of a long job (the emulator runs for ~8 minutes,
# the MSYS2 build for ~5) loses the evidence whenever the branch moved meanwhile:
# run 43684262551 failed exactly there. So: stage nothing, assume the caller
# staged its files, then merge and retry.
#
# It never rebases: `git pull --rebase` from a checkout that is behind can re-root
# the branch and produce add/add conflicts -- that was D-028. A merge is boring
# and recoverable.
#
# usage: tools/commit_evidence.sh "<message>" [branch]
set -uo pipefail

msg="${1:-ci: evidence from run ${GITHUB_RUN_ID:-local} [skip ci]}"
branch="${2:-${GITHUB_REF_NAME:-}}"

# A tag-triggered run has GITHUB_REF_NAME set to the tag, and a commit cannot be pushed to
# a tag ref: core, pc and world all failed at this step on the v0.3.6-pre tag with their
# tests already green, which reads as a red release for no reason. The evidence of a tag run
# is in its artifacts and is the same code as the branch run's; say so and stop.
case "${GITHUB_REF:-}" in
    refs/tags/*)
        echo "commit_evidence: this run was triggered by ${GITHUB_REF}; a tag cannot receive"
        echo "commit_evidence: a commit, so the evidence stays in the run's artifact"
        exit 0
        ;;
esac

git config user.name "umbra ci"
git config user.email "ci@umbra.invalid"

if git diff --cached --quiet; then
    echo "commit_evidence: nothing staged, so there is nothing to push"
    if [ "${REQUIRE_EVIDENCE:-0}" = "1" ]; then
        # Callers that must always produce evidence set this: a step that
        # quietly commits nothing looks exactly like a step that worked.
        echo "commit_evidence: this step was required to commit evidence and staged none"
        exit 1
    fi
    exit 0
fi

git commit -q -m "$msg" || true

if [ -z "$branch" ]; then
    branch=$(git rev-parse --abbrev-ref HEAD)
fi

attempt=1
while [ "$attempt" -le 4 ]; do
    if git fetch -q origin "$branch" 2>/dev/null; then
        if ! git merge --no-edit -q "origin/$branch" 2>/dev/null; then
            git merge --abort 2>/dev/null || true
            # Evidence files never conflict meaningfully: this run's numbers are
            # the ones worth keeping, so resolve conflicts with our side.
            git merge --no-edit -q -X ours "origin/$branch" 2>/dev/null || {
                git merge --abort 2>/dev/null || true
                echo "commit_evidence: attempt $attempt: cannot merge origin/$branch"
                attempt=$((attempt + 1))
                sleep 5
                continue
            }
        fi
    fi
    if git push -q origin "HEAD:$branch"; then
        echo "commit_evidence: pushed to $branch on attempt $attempt"
        git --no-pager log --oneline -1
        exit 0
    fi
    echo "commit_evidence: attempt $attempt: push to $branch rejected, retrying"
    attempt=$((attempt + 1))
    sleep 5
done

echo "commit_evidence: could not push the evidence to $branch after 4 attempts"
exit 1
