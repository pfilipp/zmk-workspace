#!/usr/bin/env bash
# Rebase the layer-state-report branch onto upstream zmkfirmware/zmk:main
# and refresh the west workspace. Force-push to the fork is opt-in via --push.

set -euo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZMK_DIR="$WORKSPACE/zmk"
BRANCH="layer-state-report"
UPSTREAM_REMOTE="origin"
UPSTREAM_BRANCH="main"
FORK_REMOTE="pfilipp"

PUSH=0
RUN_WEST_UPDATE=1
REPAIR=0

usage() {
    cat <<'EOF'
Usage: ./update-zmk.sh [--push] [--no-west-update] [--repair]

  --push             After a successful rebase, force-push (with lease)
                     the rebased branch to the pfilipp fork.
  --no-west-update   Skip 'west update' at the end. Useful if you want
                     to inspect the rebased branch before syncing.
  --repair           Before fetching, clean leftover tmp packs and run
                     'git gc' in zmk/. Use after a previous interrupted
                     fetch left 'pack has unresolved deltas' garbage.
  -h, --help         Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push) PUSH=1; shift ;;
        --no-west-update) RUN_WEST_UPDATE=0; shift ;;
        --repair) REPAIR=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
err() { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "$ZMK_DIR/.git" ]] || err "Expected git repo at $ZMK_DIR (run 'just init' first?)"

git_zmk() { git -C "$ZMK_DIR" "$@"; }

log "Pre-flight checks"
[[ -z "$(git_zmk status --porcelain)" ]] || err "zmk/ working tree is dirty. Commit or stash before rebasing."

git_zmk remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || err "Missing remote '$UPSTREAM_REMOTE' in zmk/. Add with: git -C zmk remote add $UPSTREAM_REMOTE git@github.com:zmkfirmware/zmk.git"
git_zmk remote get-url "$FORK_REMOTE" >/dev/null 2>&1 || err "Missing remote '$FORK_REMOTE' in zmk/. Add with: git -C zmk remote add $FORK_REMOTE git@github.com:pfilipp/zmk.git"

# West typically leaves zmk/ at a detached HEAD pointing at manifest-rev.
# Auto-checkout the feature branch when that branch already points at HEAD.
current_branch="$(git_zmk symbolic-ref --short HEAD 2>/dev/null || echo '')"
if [[ "$current_branch" != "$BRANCH" ]]; then
    head_sha="$(git_zmk rev-parse HEAD)"
    if git_zmk show-ref --verify --quiet "refs/heads/$BRANCH" \
       && [[ "$(git_zmk rev-parse "$BRANCH")" == "$head_sha" ]]; then
        log "Detached HEAD at $BRANCH ($head_sha); switching to the branch"
        git_zmk checkout "$BRANCH"
    else
        err "zmk/ is on '$current_branch', expected '$BRANCH'. Switch with: git -C zmk checkout $BRANCH"
    fi
fi

# Detect leftover garbage from previous interrupted fetches.
garbage="$(git_zmk count-objects -v | awk '/^garbage:/ {print $2}')"
if [[ "${garbage:-0}" -gt 0 ]]; then
    if [[ "$REPAIR" -eq 1 ]]; then
        log "Cleaning $garbage leftover pack(s) and running git gc"
        find "$ZMK_DIR/.git/objects/pack" -name 'tmp_pack_*' -delete
        git_zmk gc --prune=now
    else
        err "zmk/ has $garbage leftover pack file(s) from an interrupted fetch. Re-run with --repair to clean up."
    fi
fi

old_tip="$(git_zmk rev-parse HEAD)"
old_tip_short="$(git_zmk rev-parse --short HEAD)"

log "Fetching $UPSTREAM_REMOTE and $FORK_REMOTE"
git_zmk fetch --prune "$UPSTREAM_REMOTE"
git_zmk fetch --prune "$FORK_REMOTE"

upstream_tip="$(git_zmk rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"
upstream_tip_short="$(git_zmk rev-parse --short "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")"

if git_zmk merge-base --is-ancestor "$upstream_tip" "$old_tip"; then
    log "Already up to date with $UPSTREAM_REMOTE/$UPSTREAM_BRANCH ($upstream_tip_short). Nothing to rebase."
    [[ "$RUN_WEST_UPDATE" -eq 1 ]] && { log "Running west update anyway"; (cd "$WORKSPACE" && west update --fetch-opt=--filter=blob:none); }
    exit 0
fi

backup_tag="backup/${BRANCH}/$(date -u +%Y%m%dT%H%M%SZ)"
log "Tagging current tip as $backup_tag (recover with: git -C zmk reset --hard $backup_tag)"
git_zmk tag "$backup_tag" "$old_tip"

log "Rebasing $BRANCH ($old_tip_short) onto $UPSTREAM_REMOTE/$UPSTREAM_BRANCH ($upstream_tip_short)"
if ! git_zmk rebase "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
    cat >&2 <<EOF

Rebase hit a conflict. The rebase is still in progress in zmk/.

To resolve:
  cd zmk
  # edit conflicted files, then:
  git add <files>
  git rebase --continue
  # or to give up and restore the previous tip:
  git rebase --abort
  git reset --hard $backup_tag

After a successful rebase, finish with:
  cd $WORKSPACE
  west update --fetch-opt=--filter=blob:none
EOF
    exit 1
fi

new_tip="$(git_zmk rev-parse HEAD)"
new_tip_short="$(git_zmk rev-parse --short HEAD)"

log "Rebase complete. Custom commits now on top of $upstream_tip_short:"
git_zmk log --oneline "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH..HEAD"

if [[ "$PUSH" -eq 1 ]]; then
    log "Force-pushing $BRANCH to $FORK_REMOTE (with lease)"
    git_zmk push --force-with-lease "$FORK_REMOTE" "$BRANCH"

    if [[ "$RUN_WEST_UPDATE" -eq 1 ]]; then
        log "Running west update (manifest-rev now resolves to the rebased tip on $FORK_REMOTE)"
        (cd "$WORKSPACE" && west update --fetch-opt=--filter=blob:none)
    else
        warn "Skipped 'west update' (--no-west-update)."
    fi
else
    cat <<EOF

Local rebase done. NOT running 'west update' — it would reset zmk/ HEAD to
$FORK_REMOTE/$BRANCH (still the pre-rebase tip) and clobber your rebased commits.

Next steps:
  1. Test the build:        just build splitkb_aurora_sweep
  2. When happy, push:       git -C zmk push --force-with-lease $FORK_REMOTE $BRANCH
                             (or re-run: ./update-zmk.sh --push)
  3. Then sync the workspace: west update --fetch-opt=--filter=blob:none

Recovery (rebase went wrong):
  git -C zmk reset --hard $backup_tag
EOF
fi

cat <<EOF

Summary
  branch:       $BRANCH
  old tip:      $old_tip_short
  new tip:      $new_tip_short
  upstream:     $UPSTREAM_REMOTE/$UPSTREAM_BRANCH @ $upstream_tip_short
  backup tag:   $backup_tag
EOF
