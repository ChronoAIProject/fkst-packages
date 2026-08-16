# Machine fkst Home Layout

Use `~/.fkst` as the single authoritative user-scope root for all machine-local
fkst state. A single root makes the installation discoverable, backupable, and
relocatable without mixing fkst state with unrelated home-directory content.

This convention extends two existing precedents rather than introducing a new
resolver:

- fkst-substrate documents `~/.fkst/rate-pools` as the default
  `FKST_RATE_POOL_ROOT`.
- The [workflow orchestration design](../superpowers/specs/2026-07-02-workflow-orchestration-layer-design.md)
  assigns user-authored workflow contracts to `~/.fkst/workflow/`.

## Canonical Layout

```text
~/.fkst/
  rate-pools/                 # Engine rate-pool ledgers; existing contract
  workflow/                   # User-authored workflow contracts; existing spec
  dogfood/                    # Dogfood run checkouts, durable state, logs, and runtime scratch
  src/fkst-packages/          # Platform source checkout
  src/fkst-substrate/         # Engine source checkout and BIN build root
  worktrees/<repo>/<topic>/   # Future work worktrees
```

The `worktrees/` location applies to newly created worktrees. Do not relocate
stale legacy worktrees into it. Preserve each unique tip and then delete each
stale worktree individually under the proof rules below.

## Retire Proven-Stale Duplicate Checkouts

Run the following block independently for each standalone duplicate checkout.
Set `IGNORED_POLICY=archive` to preserve ignored files, or set
`IGNORED_POLICY=accept-loss` and `ACCEPT_IGNORED_LOSS=yes` to state explicitly
that ignored files will be lost. A Git bundle preserves commits only; it does
not preserve dirty, untracked, ignored, or stashed state.

Expected result: the checkout is clean, the shared stash is empty, ignored
files are either archived or explicitly accepted-lost, no process holds the
tree, and every local branch is reachable from a remote ref or a verified
bundle. Any failed assertion aborts deletion.

```sh
set -eu
CHECKOUT=/absolute/path/to/duplicate
BACKUP_DIR="$HOME/.fkst/backups"
IGNORED_POLICY=archive                 # archive | accept-loss
ACCEPT_IGNORED_LOSS=no                # set yes only with accept-loss

git -C "$CHECKOUT" fetch --all --prune
test -d "$CHECKOUT/.git"              # abort: this is a linked worktree
test -z "$(git -C "$CHECKOUT" status --porcelain)"
test -z "$(git -C "$CHECKOUT" stash list)"

mkdir -p "$BACKUP_DIR"
ignored_list=$(mktemp)
git -C "$CHECKOUT" ls-files --others --ignored --exclude-standard -z >"$ignored_list"
if test -s "$ignored_list"; then
  case "$IGNORED_POLICY" in
    archive)
      ignored_tar="$BACKUP_DIR/$(basename "$CHECKOUT")-ignored-$(date +%Y%m%dT%H%M%S).tar"
      tar -C "$CHECKOUT" --null -T "$ignored_list" -cf "$ignored_tar"
      tar -tf "$ignored_tar" >/dev/null
      ;;
    accept-loss)
      test "$ACCEPT_IGNORED_LOSS" = yes
      ;;
    *) exit 1 ;;
  esac
fi
rm -f "$ignored_list"

held=$(mktemp)
lsof +D "$CHECKOUT" >"$held" 2>/dev/null || true
test ! -s "$held"
rm -f "$held"

unreachable=0
while IFS= read -r ref; do
  if test -z "$(git -C "$CHECKOUT" for-each-ref --contains="$ref" --format='%(refname)' refs/remotes)"; then
    printf 'UNREACHABLE %s %s\n' "$ref" "$(git -C "$CHECKOUT" rev-parse "$ref")"
    unreachable=1
  fi
done <<EOF
$(git -C "$CHECKOUT" for-each-ref --format='%(refname)' refs/heads)
EOF

if test "$unreachable" -ne 0; then
  bundle="$BACKUP_DIR/$(basename "$CHECKOUT")-$(date +%Y%m%dT%H%M%S).bundle"
  git -C "$CHECKOUT" bundle create "$bundle" --branches
  git bundle verify "$bundle"
fi
```

Only after the block exits zero may the operator remove that one checkout.

## Retire Legacy Worktree Directories

Audit each legacy worktree separately. A bundle cannot carry working-tree or
stash state, so use the same archive-or-explicit-loss rule as above before
removing the worktree. Expected result: clean tracked/untracked state, an empty
shared stash, ignored files archived or explicitly accepted-lost, no process
holding the worktree, and a verified bundle of the worktree tip. Any failure
aborts `git worktree remove`.

```sh
set -eu
OWNER=/absolute/path/to/main/checkout
WORKTREE=/absolute/path/to/legacy/worktree
BACKUP_DIR="$HOME/.fkst/backups"
IGNORED_POLICY=archive                 # archive | accept-loss
ACCEPT_IGNORED_LOSS=no                # set yes only with accept-loss

git -C "$OWNER" fetch --all --prune
git -C "$OWNER" -c core.quotePath=false worktree list --porcelain |
  awk '/^worktree / {print substr($0,10)}' | grep -Fx -- "$WORKTREE"
test -z "$(git -C "$WORKTREE" status --porcelain)"
test -z "$(git -C "$WORKTREE" stash list)"

mkdir -p "$BACKUP_DIR"
ignored_list=$(mktemp)
git -C "$WORKTREE" ls-files --others --ignored --exclude-standard -z >"$ignored_list"
if test -s "$ignored_list"; then
  case "$IGNORED_POLICY" in
    archive)
      ignored_tar="$BACKUP_DIR/$(basename "$WORKTREE")-ignored-$(date +%Y%m%dT%H%M%S).tar"
      tar -C "$WORKTREE" --null -T "$ignored_list" -cf "$ignored_tar"
      tar -tf "$ignored_tar" >/dev/null
      ;;
    accept-loss)
      test "$ACCEPT_IGNORED_LOSS" = yes
      ;;
    *) exit 1 ;;
  esac
fi
rm -f "$ignored_list"

held=$(mktemp)
lsof +D "$WORKTREE" >"$held" 2>/dev/null || true
test ! -s "$held"
rm -f "$held"

bundle="$BACKUP_DIR/$(basename "$WORKTREE")-tip-$(date +%Y%m%dT%H%M%S).bundle"
git -C "$WORKTREE" bundle create "$bundle" HEAD
git bundle verify "$bundle"
git -C "$OWNER" worktree remove "$WORKTREE"
test ! -e "$WORKTREE"
```

## Operational Facts

Linked Git worktrees store absolute paths in both directions: the linked
worktree's `.git` file points to the parent repository metadata, and the parent
repository's `.git/worktrees/<name>/gitdir` points back to the linked worktree.
Moving either side breaks those links. `git worktree repair` is Git's supported
mechanism for repairing them after a move.

redb durable roots are plain directories and are safe to move while all users
are stopped, followed by restart from the moved path. They are not disposable
runtime scratch. Recreating a durable root at a fresh path abandons its pending
and dead-letter records and can strand in-flight events; always stop, move the
existing directory, update configuration, explicitly start stopped targets,
and compare counts from the authoritative `observe --json` output.

⟦AI:FKST⟧
