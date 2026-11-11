#!/usr/bin/env bash
# Cuts a fork release for a given upstream tag: merges the fork's feature
# branch ($FEATURE_BRANCH) onto that tag and pushes the result as a tag
# with the SAME name as the upstream tag, e.g. upstream v1.69.0 -> fork
# v1.69.0. The two are different commits in different repos (this fork
# vs. upstream) published under different Terraform Registry provider
# addresses, so there's no collision - see MAINTAINING.md for the
# reasoning and trade-offs.
#
# The merge commit is also pushed to a rolling branch ($RELEASE_BRANCH
# below, default "fork-release") so it's inspectable on GitHub, but that
# branch is reset (force-pushed) on every run - only the tags are
# permanent history.
#
# Pushing the tag triggers .github/workflows/release.yml (GoReleaser),
# which builds and publishes it exactly like an upstream release, just
# with the fork's feature merged in.
#
# On a merge conflict, cuts nothing. Instead it merges the upstream tag
# INTO $FEATURE_BRANCH on a "resolve/<tag>" branch and commits that merge
# with the conflict markers still in it - so the history is a real
# two-parent merge no matter who fixes the files - opens a PR for it
# against $FEATURE_BRANCH and asks GitHub Copilot coding agent (@copilot)
# to resolve the markers. .github/workflows/copilot-autopilot.yml then
# drives that PR to a merge without a human and reruns this workflow; with
# the tag now in $FEATURE_BRANCH the merge is clean and the release is
# cut. GH_TOKEN must be a real user PAT with Copilot coding agent access:
# Copilot ignores @copilot mentions from bots and GitHub App tokens.
#
# Idempotent: safe to rerun - does nothing if the tag already
# exists (re-cutting one, e.g. after resolving a conflict by hand,
# requires explicitly deleting/force-pushing it first - see
# MAINTAINING.md).
#
# Usage: scripts/cut-fork-tag.sh <upstream-tag>
#
# Requires: git identity configured, GH_TOKEN/gh auth set up, run from the
# repo root with <upstream-tag> and $FEATURE_BRANCH already fetched
# locally (as refs/upstream-tags/<upstream-tag> or a plain tag - see
# cut-fork-release.yml for why the workflow uses the former).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <upstream-tag>" >&2
  exit 1
fi

upstream_tag=$1
: "${FEATURE_BRANCH:?FEATURE_BRANCH env var must be set}"
release_branch=${RELEASE_BRANCH:-fork-release}
fork_tag=$upstream_tag

if [[ ! "$upstream_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: $upstream_tag doesn't look like a plain vX.Y.Z tag" >&2
  exit 1
fi

if git rev-parse -q --verify "refs/upstream-tags/$upstream_tag" > /dev/null; then
  base_ref="refs/upstream-tags/$upstream_tag"
elif git rev-parse -q --verify "refs/tags/$upstream_tag" > /dev/null; then
  base_ref="refs/tags/$upstream_tag"
else
  echo "error: tag $upstream_tag not found (did you fetch upstream --tags?)" >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$fork_tag" > /dev/null; then
  echo "$fork_tag already exists, skipping."
  exit 0
fi

git checkout -B "$release_branch" "$base_ref"

if ! git merge "origin/$FEATURE_BRANCH" --no-edit; then
  git merge --abort

  resolve_branch="resolve/$upstream_tag"
  existing_pr=$(gh pr list --state open --head "$resolve_branch" --json number --jq 'length')
  if [[ "$existing_pr" != "0" ]]; then
    echo "A resolve PR is already open for $upstream_tag, skipping."
    exit 0
  fi

  # Merge the tag INTO the feature branch (the opposite direction of the
  # cut above), so that once this lands the cut is a clean fast-forward.
  # Expected to conflict - that's why we're here.
  git checkout -B "$resolve_branch" "origin/$FEATURE_BRANCH"
  git merge --no-ff --no-commit "$base_ref" || true
  conflicted=$(git diff --name-only --diff-filter=U)
  git add -u  # not -A: the workflow leaves candidates.txt in the worktree
  git commit --no-verify \
    -m "Merge upstream $upstream_tag into $FEATURE_BRANCH" \
    -m "Committed with unresolved conflict markers, to be resolved in the PR."
  git push origin "$resolve_branch" --force

  body_file=$(mktemp)
  {
    echo "Cutting the fork release for upstream \`$upstream_tag\` conflicted with \`$FEATURE_BRANCH\`."
    echo
    echo "This branch is a real merge of \`$upstream_tag\` into \`$FEATURE_BRANCH\`, committed with the conflict markers still in it. Once they're resolved and this PR is merged, \`cut-fork-release.yml\` cuts the release cleanly."
    echo
    echo 'Conflicted files:'
    echo
    while IFS= read -r file; do echo "- \`$file\`"; done <<< "$conflicted"
    echo
    echo "Driven to merge without a human by \`.github/workflows/copilot-autopilot.yml\`."
  } > "$body_file"

  pr_url=$(gh pr create \
    --base "$FEATURE_BRANCH" \
    --head "$resolve_branch" \
    --title "Resolve conflicts: merge upstream $upstream_tag into $FEATURE_BRANCH" \
    --body-file "$body_file")

  # Must be posted with a user PAT - Copilot ignores mentions from bots.
  # The marker lets copilot-autopilot.yml count its nudges.
  nudge_file=$(mktemp)
  {
    echo '<!-- copilot-autopilot -->'
    echo "@copilot Resolve every merge conflict marker in this branch by editing the files. Keep upstream's changes AND this fork's feature (the server rebuild action). Do not rebase, squash, reset or force-push: the existing merge commit must stay in the history. Make sure \`go build ./...\` and \`go test ./...\` pass."
  } > "$nudge_file"
  gh pr comment "$pr_url" --body-file "$nudge_file"
  exit 0
fi

git push origin "$release_branch" --force-with-lease
git tag -a "$fork_tag" -m "Fork release of upstream $upstream_tag, includes $FEATURE_BRANCH"
git push origin "$fork_tag"

echo "Cut fork release $fork_tag."
