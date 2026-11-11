#!/usr/bin/env bash
# Drives every open "resolve/<tag>" PR (opened by scripts/cut-fork-tag.sh
# on a release conflict) to a merge into $FEATURE_BRANCH without a human:
# GitHub Copilot coding agent fixes the code, Copilot code review reviews
# it, and this script merges once it's clean and then reruns
# cut-fork-release.yml to cut the release.
#
# Meant to be run repeatedly (see .github/workflows/copilot-autopilot.yml);
# each run moves each PR at most one step forward:
#
#   1. Copilot is still working, or hasn't picked up our last @copilot
#      comment yet                                   -> wait
#   2. conflict markers left in the tree             -> ask @copilot to fix
#   3. $REQUIRED_CHECKS still running                -> wait
#   4. $REQUIRED_CHECKS failed                       -> ask @copilot to fix
#   5. no Copilot review of the current head yet     -> request one, wait
#   6. Copilot review left comments                  -> ask @copilot to fix
#   7. otherwise                                     -> merge, cut release
#
# After $MAX_ROUNDS @copilot requests, review comments alone no longer
# block (CI is green and the markers are gone, so the merge is sound) -
# but red CI or leftover markers do: those would ship a broken release, so
# the PR gets the $STUCK_LABEL label and is left alone. Removing the label
# makes the next run pick it up again.
#
# The same applies when the PR's history no longer contains the upstream
# tag (someone rebased or squashed the merge commit away): merging it
# wouldn't make the next cut clean.
#
# Usage: scripts/copilot-autopilot.sh
#
# Requires: GH_REPO, FEATURE_BRANCH, GH_TOKEN set to a real user PAT
# (Copilot ignores @copilot mentions from bots), run from the repo root
# with upstream tags fetched as refs/upstream-tags/* (see
# cut-fork-release.yml for why).
set -euo pipefail

: "${GH_REPO:?GH_REPO env var must be set}"
: "${FEATURE_BRANCH:?FEATURE_BRANCH env var must be set}"
max_rounds=${MAX_ROUNDS:-3}
# e2e is left out on purpose: it needs an HCLOUD_TOKEN this fork doesn't have.
required_checks=${REQUIRED_CHECKS:-build pre-commit lint unit}
# How long to wait for Copilot to react to an @copilot comment before
# asking again.
nudge_timeout=$((${NUDGE_TIMEOUT_HOURS:-3} * 3600))
stuck_label=${STUCK_LABEL:-autopilot-stuck}

marker='<!-- copilot-autopilot -->'
reviewer='copilot-pull-request-reviewer[bot]'
now=$(date -u +%s)

epoch() { date -u -d "$1" +%s; }

nudge() {
  local pr=$1 message=$2
  echo "PR #$pr: asking @copilot: $message"
  printf '%s\n@copilot %s\n' "$marker" "$message" | gh pr comment "$pr" --body-file -
}

give_up() {
  local pr=$1 reason=$2
  echo "::warning::PR #$pr: giving up, needs a human: $reason"
  gh label create "$stuck_label" --color B60205 \
    --description "copilot-autopilot gave up on this PR - remove to retry" 2> /dev/null || true
  gh pr edit "$pr" --add-label "$stuck_label"
  gh pr comment "$pr" --body "copilot-autopilot gave up on this PR: $reason. Fix it by hand and merge, or remove the \`$stuck_label\` label to let it retry."
}

drive() {
  local pr=$1
  local branch sha draft stuck tag
  read -r branch sha draft stuck < <(gh pr view "$pr" --json headRefName,headRefOid,isDraft,labels \
    --jq "[.headRefName, .headRefOid, .isDraft, any(.labels[]; .name == \"$stuck_label\")] | @tsv")
  if [[ "$stuck" == "true" ]]; then
    echo "PR #$pr: labelled $stuck_label, skipping."
    return
  fi
  tag=${branch#resolve/}

  # 1. Is Copilot busy, or yet to react to our last request?
  local last_event last_nudge rounds
  last_event=$(gh api --paginate "repos/$GH_REPO/issues/$pr/timeline" \
    --jq '.[] | select(.event == "copilot_work_started" or .event == "copilot_work_finished") | "\(.created_at) \(.event)"' |
    sort | tail -1)
  if [[ "$last_event" == *copilot_work_started ]]; then
    echo "PR #$pr: Copilot is still working, waiting."
    return
  fi
  local nudges
  nudges=$(gh api --paginate "repos/$GH_REPO/issues/$pr/comments" \
    --jq ".[] | select(.body | contains(\"$marker\")) | .created_at" | sort)
  rounds=$(grep -c . <<< "$nudges" || true)
  last_nudge=$(tail -1 <<< "$nudges")
  if [[ -n "$last_nudge" ]] &&
    { [[ -z "$last_event" ]] || (($(epoch "${last_event%% *}") < $(epoch "$last_nudge"))); } &&
    ((now - $(epoch "$last_nudge") < nudge_timeout)); then
    echo "PR #$pr: waiting for Copilot to pick up the last request."
    return
  fi

  git fetch origin "+refs/pull/$pr/head:refs/autopilot/$pr" --quiet
  if ! git merge-base --is-ancestor "refs/upstream-tags/$tag" "$sha"; then
    give_up "$pr" "its history no longer contains upstream \`$tag\` (was the merge commit rebased or squashed away?)"
    return
  fi

  if [[ "$draft" == "true" ]]; then
    gh pr ready "$pr"
  fi

  # 2. Leftover conflict markers.
  local markers
  markers=$(git grep -lE '^(<{7}|>{7})( |$)' "$sha" -- | sed "s/^$sha://" || true)
  if [[ -n "$markers" ]]; then
    if ((rounds >= max_rounds)); then
      give_up "$pr" "conflict markers are still left after $rounds requests to Copilot"
    else
      nudge "$pr" "Conflict markers are still left in: $(paste -sd, <<< "$markers"). Resolve them by editing the files, keeping both upstream's changes and the fork's feature. Do not rebase, squash or force-push."
    fi
    return
  fi

  # 3./4. Required checks.
  local runs name states failed=() pending=()
  runs=$(gh api --paginate "repos/$GH_REPO/commits/$sha/check-runs" \
    --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion)"')
  for name in $required_checks; do
    states=$(awk -F'\t' -v n="$name" '$1 == n { print $2 "/" $3 }' <<< "$runs")
    if [[ -z "$states" ]] || grep -qvE '^completed/' <<< "$states"; then
      pending+=("$name")
    elif grep -qvE '/(success|skipped|neutral)$' <<< "$states"; then
      failed+=("$name")
    fi
  done
  if ((${#pending[@]})); then
    echo "PR #$pr: waiting for checks: ${pending[*]}."
    # Workflow runs held for approval never create check runs, so they'd
    # look pending forever - make that visible.
    if gh api "repos/$GH_REPO/actions/runs?head_sha=$sha" \
      --jq '.workflow_runs[].conclusion' | grep -qx action_required; then
      echo "::warning::PR #$pr: CI is waiting for a human to approve it - turn off approval for Copilot's workflow runs in Settings > Copilot > Coding agent."
    fi
    return
  fi
  if ((${#failed[@]})); then
    if ((rounds >= max_rounds)); then
      give_up "$pr" "checks ${failed[*]} still fail after $rounds requests to Copilot"
    else
      nudge "$pr" "These CI checks fail on this PR: ${failed[*]}. Look at their logs and fix the code until they pass. Do not rebase, squash or force-push."
    fi
    return
  fi

  # 5. Copilot code review of the current head.
  local review_id
  review_id=$(gh api --paginate "repos/$GH_REPO/pulls/$pr/reviews" \
    --jq ".[] | select(.user.login == \"$reviewer\" and .commit_id == \"$sha\") | .id" | tail -1)
  if [[ -z "$review_id" ]]; then
    if gh api "repos/$GH_REPO/pulls/$pr/requested_reviewers" --jq '.users[].login' | grep -qxF "$reviewer"; then
      echo "PR #$pr: waiting for Copilot's review."
    else
      echo "PR #$pr: requesting a Copilot review."
      gh api --method POST "repos/$GH_REPO/pulls/$pr/requested_reviewers" \
        -f "reviewers[]=$reviewer" > /dev/null ||
        echo "::warning::PR #$pr: couldn't request a Copilot review - is Copilot code review enabled for this repo?"
    fi
    return
  fi

  # 6. Review comments.
  local comments
  comments=$(gh api --paginate "repos/$GH_REPO/pulls/$pr/reviews/$review_id/comments" --jq '.[].id' | grep -c . || true)
  if ((comments > 0)); then
    if ((rounds < max_rounds)); then
      nudge "$pr" "Address the $comments comment(s) from Copilot's latest review on this PR (fix them, or reply why not). Keep CI green. Do not rebase, squash or force-push."
      return
    fi
    echo "PR #$pr: $comments review comment(s) left after $rounds rounds, but CI is green - merging anyway."
  fi

  # 7. Land it, and cut the release now that the merge is clean.
  gh pr merge "$pr" --merge --delete-branch --match-head-commit "$sha"
  echo "PR #$pr: merged into $FEATURE_BRANCH, rerunning cut-fork-release.yml."
  gh workflow run cut-fork-release.yml --ref main
}

prs=$(gh pr list --state open --base "$FEATURE_BRANCH" --json number,headRefName \
  --jq '.[] | select(.headRefName | startswith("resolve/")) | .number')
if [[ -z "$prs" ]]; then
  echo "No resolve PRs open."
  exit 0
fi

# No `drive || ...` error handling here on purpose: that would disable
# set -e inside drive, and a failed API call must stop it rather than be
# read as e.g. "no review yet". The next scheduled run retries.
for pr in $prs; do
  echo "::group::PR #$pr"
  drive "$pr"
  echo "::endgroup::"
done
