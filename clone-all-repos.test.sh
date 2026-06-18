#!/usr/bin/env bash
# Unit tests for refresh_repo() in clone-all-repos.sh, using local git fixtures.
# Run: ./clone-all-repos.test.sh   (or pass an explicit script path as $1)
set -uo pipefail

# Default to the script sitting next to this test; override via $1.
SCRIPT="${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/clone-all-repos.sh"}"

# shellcheck source=/dev/null
# Source functions only; the guarded main() does not run (BASH_SOURCE != $0).
source "$SCRIPT"
set +e  # the sourced script enabled errexit; disable it for assertion flow

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# chk <message> <command...>: PASS if the command succeeds, else FAIL.
chk() { local msg="$1"; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
# not <command...>: succeeds when the command fails (for negative assertions).
not() { ! "$@"; }

# Assertions against the globals refresh_repo sets.
status_is()  { [ "$REPO_STATUS" = "$1" ]; }
detail_has() { case "$REPO_DETAIL" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# Quiet, deterministic git in fixtures.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
gitc() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }

head_branch() { git -C "$1" rev-parse --abbrev-ref HEAD; }
at_ref()      { [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse "$2")" ]; }

# new_fixture <dir>: bare remote + working clone with main containing v1.
new_fixture() {
  local root="$1"
  mkdir -p "$root"
  gitc init -q --bare "$root/remote.git"
  gitc clone -q "$root/remote.git" "$root/work" 2>/dev/null
  ( cd "$root/work" || exit 1
    echo v1 > file.txt
    gitc add file.txt && gitc commit -q -m c1
    gitc push -q -u origin main )
}

# advance_main <work>: add a commit to origin/main, leaving local main behind it.
advance_main() {
  ( cd "$1" || exit 1
    gitc checkout -q main
    echo v2 >> file.txt
    gitc commit -qam c2
    gitc push -q origin main
    gitc reset -q --hard HEAD~1 )
}

RC=0
run() {
  pushd "$1" >/dev/null || return 1
  refresh_repo . >/tmp/_rr.out 2>&1; RC=$?
  popd >/dev/null || return 1
  return "$RC"
}

echo "== Scenario A: merged & deleted feature branch, clean -> healed to main =="
T=$(mktemp -d); new_fixture "$T"
( cd "$T/work" || exit 1
  gitc checkout -q -b feature/x
  echo fx >> file.txt && gitc commit -qam fx
  gitc push -q -u origin feature/x
  gitc checkout -q main && gitc merge -q feature/x
  echo more >> file.txt && gitc commit -qam c2
  gitc push -q origin main
  gitc push -q origin --delete feature/x
  gitc checkout -q feature/x )
run "$T/work"
chk "status=healed"                 status_is healed
chk "detail names removed branch"   detail_has "removed 'feature/x'"
chk "switched to main"              test "$(head_branch "$T/work")" = main
chk "stale branch deleted"          not git -C "$T/work" show-ref --verify --quiet refs/heads/feature/x
chk "fast-forwarded to origin/main" at_ref "$T/work" origin/main
rm -rf "$T"

echo "== Scenario B: live feature branch, clean & behind -> refreshed in place =="
T=$(mktemp -d); new_fixture "$T"
( cd "$T/work" || exit 1
  gitc checkout -q -b feature/y
  gitc push -q -u origin feature/y
  echo fy >> file.txt && gitc commit -qam fy
  gitc push -q origin feature/y
  gitc reset -q --hard HEAD~1 )
run "$T/work"
chk "status=refreshed"           status_is refreshed
chk "stayed on feature/y"        test "$(head_branch "$T/work")" = feature/y
chk "ff'd to origin/feature/y"   at_ref "$T/work" origin/feature/y
rm -rf "$T"

echo "== Scenario C: deleted-upstream branch but DIRTY -> attention, untouched =="
T=$(mktemp -d); new_fixture "$T"
( cd "$T/work" || exit 1
  gitc checkout -q -b feature/x
  echo fx >> file.txt && gitc commit -qam fx
  gitc push -q -u origin feature/x
  gitc checkout -q main && gitc merge -q feature/x
  gitc push -q origin main
  gitc push -q origin --delete feature/x
  gitc checkout -q feature/x
  echo dirty >> file.txt )
run "$T/work"
chk "status=attention"             status_is attention
chk "detail flags uncommitted"     detail_has "uncommitted file"
chk "returns 0 (not a failure)"    test "$RC" = 0
chk "left on feature/x"            test "$(head_branch "$T/work")" = feature/x
chk "uncommitted change preserved" grep -q dirty "$T/work/file.txt"
rm -rf "$T"

echo "== Scenario D: unpushed commits on a never-pushed branch -> attention =="
T=$(mktemp -d); new_fixture "$T"
( cd "$T/work" || exit 1
  gitc checkout -q -b feature/z
  echo fz >> file.txt && gitc commit -qam fz )
run "$T/work"
chk "status=attention"           status_is attention
chk "detail flags unpushed"      detail_has "unpushed commit"
chk "left on feature/z"          test "$(head_branch "$T/work")" = feature/z
chk "unpushed commit preserved"  git -C "$T/work" merge-base --is-ancestor HEAD feature/z
rm -rf "$T"

echo "== Scenario E: on default branch, clean & behind -> refreshed =="
T=$(mktemp -d); new_fixture "$T"; advance_main "$T/work"
run "$T/work"
chk "status=refreshed"              status_is refreshed
chk "fast-forwarded to origin/main" at_ref "$T/work" origin/main
rm -rf "$T"

echo "== Scenario F: DIRTY on default branch -> attention, not fast-forwarded =="
T=$(mktemp -d); new_fixture "$T"; advance_main "$T/work"
( cd "$T/work" || exit 1; echo dirty >> file.txt )
run "$T/work"
chk "status=attention"             status_is attention
chk "detail flags uncommitted"     detail_has "uncommitted file"
chk "still on main"                test "$(head_branch "$T/work")" = main
chk "NOT fast-forwarded"           not at_ref "$T/work" origin/main
chk "uncommitted change preserved" grep -q dirty "$T/work/file.txt"
rm -rf "$T"

echo "== Scenario G: unpushed commits on a LIVE feature branch -> attention =="
T=$(mktemp -d); new_fixture "$T"
( cd "$T/work" || exit 1
  gitc checkout -q -b feature/w
  gitc push -q -u origin feature/w
  echo w >> file.txt && gitc commit -qam w )   # local commit, not pushed
run "$T/work"
chk "status=attention"          status_is attention
chk "detail flags unpushed"     detail_has "unpushed commit"
chk "left on feature/w"         test "$(head_branch "$T/work")" = feature/w
chk "NOT fast-forwarded away"   not at_ref "$T/work" origin/feature/w
rm -rf "$T"

echo
echo "===== $PASS passed, $FAIL failed ====="
[ "$FAIL" -eq 0 ]
