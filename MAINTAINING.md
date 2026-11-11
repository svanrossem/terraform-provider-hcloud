# Maintaining this fork

This is a fork of [hetznercloud/terraform-provider-hcloud](https://github.com/hetznercloud/terraform-provider-hcloud)
that carries an extra feature not in upstream, developed on the
`allow-rebuilding-with-image-or-user-data` branch. This document describes
how the fork is kept in sync with upstream and how releases are versioned
and cut.

## Remotes

```
origin    git@github.com:svanrossem/terraform-provider-hcloud.git   (this fork)
upstream  https://github.com/hetznercloud/terraform-provider-hcloud.git
```

If `upstream` isn't configured:

```sh
git remote add upstream https://github.com/hetznercloud/terraform-provider-hcloud.git
```

## Syncing with upstream

`.github/workflows/sync-upstream.yml` merges `upstream/main` into `main`
automatically every day (and on manual dispatch). It opens a PR via the
GitHub CLI (`scripts/sync-branch.sh`) and tries to merge it right away;
if that's blocked (e.g. branch protection) it enables auto-merge instead,
and if even that isn't possible it just leaves the PR open - either way
it never pushes to `main` directly or drops a change silently. A merge
conflict opens an issue instead of a PR.

To do it by hand instead:

```sh
git fetch upstream --tags
git checkout main
git merge upstream/main   # or upstream/vX.Y.Z for a specific tag
```

`main` should always be a fast-forward from upstream - it never carries
the fork's own feature branch (`allow-rebuilding-with-image-or-user-data`
below); that only gets merged onto release tags, as described next.

## Cutting fork releases automatically

`.github/workflows/cut-fork-release.yml` watches upstream's tags (polled
daily, since GitHub Actions can't watch another repo's tags directly). For
every upstream release tag it hasn't seen yet, it merges the fork's
feature branch onto that tag and pushes the result as a tag with the
**same name**:

```
upstream tag: v1.69.0
fork tag:     v1.69.0
```

On first run (no fork tags exist yet), it only bootstraps from the latest
upstream tag rather than backfilling this fork's entire release history.

The merge commit is also pushed to a rolling `fork-release` branch so
it's inspectable on GitHub, but that branch is force-pushed on every run --
only the tags are permanent.

### Merge conflicts: resolved by Copilot, no human needed

A merge conflict doesn't fail or open an issue. Instead
`scripts/cut-fork-tag.sh` merges the upstream tag **into** the feature
branch on a `resolve/vX.Y.Z` branch, commits that merge with the conflict
markers still in it (so the history is always a real merge, whoever fixes
the files), opens a PR against the feature branch and asks `@copilot` to
resolve the markers.

`.github/workflows/copilot-autopilot.yml` (every 15 minutes) then drives
each such PR to a merge without a human: it waits for Copilot to finish,
marks the PR ready, waits for CI (`build`, `pre-commit`, `lint`, `unit` -
not `e2e`, which needs an `HCLOUD_TOKEN` this fork doesn't have), requests
a Copilot code review, and asks `@copilot` to fix whatever is left
(markers, failing CI, review comments). Once it's clean it merges the PR
and reruns `cut-fork-release.yml`, which now merges cleanly and cuts the
release. See `scripts/copilot-autopilot.sh` for the exact steps.

After 3 rounds of asking Copilot (`MAX_ROUNDS`), remaining review comments
no longer block the merge. Red CI or leftover markers do, since they'd
ship a broken release. The PR then gets the `autopilot-stuck` label and is
left for you: fix it by hand, or remove the label to let it retry.

To resolve one by hand instead, push the fix to the `resolve/vX.Y.Z`
branch (keeping its merge commit, so no rebase or squash) and merge the PR.

Pushing the fork tag triggers `.github/workflows/release.yml` (GoReleaser)
exactly like a real upstream tag would, publishing a GitHub Release with
the binaries, checksums, signature, and `terraform-registry-manifest.json`.
Fork builds are Linux-only (`amd64`/`arm64`) - see `.goreleaser.yml` - since
that's the only platform this fork is consumed on; adjust `goos`/`goarch`
there if that changes.

### Versioning scheme

Fork tags reuse the exact upstream tag name they're built from, e.g.
upstream `v1.69.0` becomes fork `v1.69.0` too. This is safe because the
two live in different repos and are published under different Terraform
Registry provider addresses (`hetznercloud/hcloud` vs. `svanrossem/hcloud`) --
there's no registry or tooling that would ever compare them directly,
even though the commits (and therefore checksums) differ.

The trade-off: because the name alone doesn't distinguish "the fork's
v1.69.0" from "upstream's v1.69.0", re-cutting a fork tag (e.g. after
resolving a merge conflict by hand) requires explicitly deleting and
force-pushing it rather than just bumping a number - see "Cutting a
release by hand" below. `cut-fork-tag.sh` still annotates each fork tag
(`Fork release of upstream vX.Y.Z, includes <branch>`) for a quick way to
tell a fork tag apart from a genuine upstream one when both are checked
out locally.

### Cutting a release by hand

```sh
git fetch upstream --tags
git fetch origin allow-rebuilding-with-image-or-user-data
scripts/cut-fork-tag.sh v1.69.0   # replace with the upstream tag to build on
```

To re-cut a fork tag that already exists (e.g. after fixing a conflict
that previously opened an issue), delete it first - locally and on
`origin` - then run the command above again:

```sh
git tag -d v1.69.0
git push origin :refs/tags/v1.69.0
scripts/cut-fork-tag.sh v1.69.0
```

This merges the feature branch onto the given upstream tag, and pushes
both the `fork-release` branch and the resulting offset-patch tag - the
same thing the workflow above does automatically.

Add a short entry to `FORK_CHANGELOG.md` before tagging, summarizing what
changed since the last fork release (upstream's own `CHANGELOG.md` is left
untouched by upstream merges and continues to describe upstream's
history).

## One-time setup still needed (not automatable from here)

- **`SYNC_PAT` secret**: both `sync-upstream.yml` and
  `cut-fork-release.yml` fall back to the default `GITHUB_TOKEN` if this
  isn't set, but GitHub deliberately does not run other workflows off of
  pushes/tags made with the default token (to avoid recursive workflow
  chains). That's merely inconvenient for `sync-upstream.yml` (the sync
  PR's own CI checks won't run), but it's a hard blocker for
  `cut-fork-release.yml`: the fork release tag it pushes would silently
  never trigger `release.yml`/GoReleaser. Add a personal access token
  (classic, `repo` scope, or a fine-grained token scoped to this repo with
  contents/pull-requests/issues read-write) as the `SYNC_PAT` secret so
  tag pushes actually trigger releases. This must be a real user PAT
  belonging to an account with Copilot coding agent access - Copilot
  ignores `@copilot` requests (see "Merge conflicts" above) from the
  default `GITHUB_TOKEN` or a GitHub App token, since Copilot usage is
  billed to a human account. `copilot-autopilot.yml` requires it outright.
- **Copilot settings** for the conflict autopilot above: enable Copilot
  coding agent and Copilot code review for this repo, and turn **off**
  "require approval for workflow runs" for Copilot (Settings → Copilot →
  Coding agent). Otherwise CI never runs on Copilot's pushes and the
  autopilot waits forever (it logs a warning when that's the case).
- **GPG signing key**: generate a key dedicated to this fork and add it as
  the `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE` secrets on this repo (Settings →
  Secrets and variables → Actions). Upstream's key is Hetzner's and isn't
  usable here.
- **Terraform Registry publishing**: sign in to
  [registry.terraform.io](https://registry.terraform.io) with GitHub and
  publish this repo as a provider. `main.go`'s registry address is already
  set to `registry.terraform.io/svanrossem/hcloud` (update both together
  if you ever rename). The registry picks up new tags automatically after
  that; no further action needed per release. Note that only Linux
  binaries are published (see "Cutting fork releases automatically"
  above), so this provider is only installable on Linux.
- `.github/workflows/releaser-pleaser.yml` is upstream's automated
  changelog/version-bump bot; it's gated to only run on
  `hetznercloud/terraform-provider-hcloud` and is a no-op here on purpose
  since it doesn't know about the fork's versioning scheme. Leave it
  disabled rather than re-enabling it.
