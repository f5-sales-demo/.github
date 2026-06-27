#!/usr/bin/env bash
#
# Clone (or refresh) all downstream repos from the f5-sales-demo organization.
# Reads the repo list from the docs-control manifest and includes docs-control and .github.
#
# Running this once gives a developer a local clone of the whole ecosystem; re-running
# pulls the freshest commits. Each existing repo is classified into exactly one outcome:
#
#   refreshed  clean and current/behind  -> fast-forward to its upstream
#   healed     clean, parked on a branch merged & deleted upstream -> drop it, return to default
#   attention  uncommitted changes and/or unpushed commits (or detached HEAD) -> left untouched
#   error      fetch/clone failed, or an unexpected non-fast-forward
#
# The guiding rule: a repo with any local work is NEVER modified — it is only reported,
# so unfinished work is impossible to lose.
#

set -euo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/f5-sales-demo/docs-control/refs/heads/main/.github/config/downstream-repos.json"
ORG="f5-sales-demo"

# Outcome of the most recent refresh_repo/clone_repo call (read by the caller).
REPO_STATUS=""   # cloned | refreshed | healed | attention | error
REPO_DETAIL=""   # human-readable specifics for the summary

# --- Dependency check ---
check_deps() {
    local cmd
    for cmd in curl jq git; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Error: '$cmd' is required but not found in PATH." >&2
            exit 1
        fi
    done
}

# Echo the repo's default branch (origin/HEAD), repairing the ref if missing.
resolve_default() {
    local dir="$1" d
    d=$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
    if [ -z "$d" ]; then
        git -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
        d=$(git -C "$dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
    fi
    echo "${d:-main}"
}

# Echo the count of commits on HEAD not yet pushed to a remote.
# Uses the configured upstream when its ref still exists; otherwise counts commits
# not contained in ANY remote branch (covers never-pushed and pruned-upstream branches).
count_unpushed() {
    local dir="$1" up
    if up=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
       && git -C "$dir" show-ref --verify --quiet "refs/remotes/$up"; then
        git -C "$dir" rev-list --count "$up..HEAD" 2>/dev/null || echo 0
    else
        git -C "$dir" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0
    fi
}

# Refresh an existing repo checkout at "$1".
# Prints indented progress and sets REPO_STATUS / REPO_DETAIL. Returns non-zero only
# for the 'error' outcome (attention is a normal developer state, not a failure).
refresh_repo() {
    local dir="$1"
    REPO_STATUS=""
    REPO_DETAIL=""

    # Refresh remote-tracking refs and prune branches deleted upstream.
    if ! git -C "$dir" fetch --prune origin 2>&1 | sed 's/^/  /'; then
        echo "  Warning: git fetch failed for $dir"
        REPO_STATUS="error"; REPO_DETAIL="fetch failed"
        return 1
    fi

    local current
    current=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)

    # --- Universal sanity check: never touch a repo that has local work. ---
    if [ "$current" = "HEAD" ]; then
        echo "  Detached HEAD — left untouched."
        REPO_STATUS="attention"; REPO_DETAIL="detached HEAD"
        return 0
    fi

    local dirty_count unpushed_count
    dirty_count=$(git -C "$dir" status --porcelain | wc -l | tr -d '[:space:]')
    unpushed_count=$(count_unpushed "$dir")

    if [ "$dirty_count" -gt 0 ] || [ "$unpushed_count" -gt 0 ]; then
        local detail=""
        if [ "$dirty_count" -gt 0 ]; then
            if [ "$dirty_count" -eq 1 ]; then detail="1 uncommitted file"; else detail="$dirty_count uncommitted files"; fi
        fi
        if [ "$unpushed_count" -gt 0 ]; then
            local u
            if [ "$unpushed_count" -eq 1 ]; then u="1 unpushed commit"; else u="$unpushed_count unpushed commits"; fi
            if [ -n "$detail" ]; then detail="$detail, $u"; else detail="$u"; fi
        fi
        echo "  Local work present on '$current' — left untouched ($detail)."
        REPO_STATUS="attention"; REPO_DETAIL="$detail on '$current'"
        return 0
    fi

    # --- Clean from here: safe to fast-forward or heal. ---
    local default
    default=$(resolve_default "$dir")

    if [ "$current" != "$default" ]; then
        if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$current"; then
            # Live feature branch: fast-forward in place and stay checked out.
            if git -C "$dir" merge --ff-only "origin/$current" 2>&1 | sed 's/^/  /'; then
                echo "  On feature branch '$current' (still on remote) — fast-forwarded, left checked out."
                REPO_STATUS="refreshed"; REPO_DETAIL="feature branch '$current'"
                return 0
            fi
            echo "  Warning: fast-forward failed for $dir on '$current'"
            REPO_STATUS="error"; REPO_DETAIL="ff failed on '$current'"
            return 1
        fi

        # Stale branch (merged & deleted upstream), nothing local to lose: drop it.
        echo "  Branch '$current' gone upstream — switching to '$default' and removing stale branch."
        if ! git -C "$dir" checkout "$default" 2>&1 | sed 's/^/  /'; then
            echo "  Warning: failed to checkout $default for $dir"
            REPO_STATUS="error"; REPO_DETAIL="checkout failed"
            return 1
        fi
        git -C "$dir" branch -D "$current" 2>&1 | sed 's/^/  /' || true
        if git -C "$dir" merge --ff-only "origin/$default" 2>&1 | sed 's/^/  /'; then
            REPO_STATUS="healed"; REPO_DETAIL="removed '$current'"
            return 0
        fi
        echo "  Warning: fast-forward failed for $dir on '$default' (diverged from origin)"
        REPO_STATUS="error"; REPO_DETAIL="ff failed on '$default'"
        return 1
    fi

    # On the default branch: fast-forward to origin.
    if git -C "$dir" merge --ff-only "origin/$default" 2>&1 | sed 's/^/  /'; then
        REPO_STATUS="refreshed"; REPO_DETAIL="$default"
        return 0
    fi
    echo "  Warning: fast-forward failed for $dir on '$default' (diverged from origin)"
    REPO_STATUS="error"; REPO_DETAIL="ff failed on '$default'"
    return 1
}

# Clone "$1" (org/name) into the current directory.
clone_repo() {
    local full_name="$1"
    REPO_STATUS=""
    REPO_DETAIL=""
    if git clone "https://github.com/${full_name}.git" 2>&1 | sed 's/^/  /'; then
        REPO_STATUS="cloned"
        return 0
    fi
    echo "  Warning: git clone failed for $full_name"
    REPO_STATUS="error"; REPO_DETAIL="clone failed"
    return 1
}

main() {
    check_deps

    # --- Fetch manifest ---
    echo "Fetching repo manifest..."
    local json
    json=$(curl -fsSL "$MANIFEST_URL") || {
        echo "Error: failed to fetch manifest from $MANIFEST_URL" >&2
        exit 1
    }

    # --- Build repo list (extra repos first, then manifest entries) ---
    local repos=("$ORG/docs-control" "$ORG/.github")
    local repo
    while IFS= read -r repo; do
        # Manifest entries are short names; prepend org if no slash present.
        if [[ "$repo" != */* ]]; then
            repo="$ORG/$repo"
        fi
        repos+=("$repo")
    done < <(echo "$json" | jq -r '.[]')

    echo "Found ${#repos[@]} repos to process."
    echo

    # --- Clone or refresh each repo ---
    local cloned=0 refreshed=0
    local healed=() attention=() errors=()
    local full_name dir

    for full_name in "${repos[@]}"; do
        dir="${full_name##*/}"
        echo "--- $full_name ---"

        if [ -d "$dir" ]; then
            echo "  Directory exists, refreshing..."
            refresh_repo "$dir" || true
        else
            echo "  Cloning..."
            clone_repo "$full_name" || true
        fi

        case "$REPO_STATUS" in
            cloned)    (( cloned++ )) || true ;;
            refreshed) (( refreshed++ )) || true ;;
            healed)    healed+=("$full_name: $REPO_DETAIL") ;;
            attention) attention+=("$full_name: $REPO_DETAIL") ;;
            *)         errors+=("$full_name: $REPO_DETAIL") ;;
        esac
        echo
    done

    # --- Summary ---
    # Optional sections print only when non-empty; the for loops are reached only
    # when the array has elements, keeping them safe under `set -u` on bash 3.2.
    echo "===== Summary ====="
    echo "Cloned:    $cloned"
    echo "Refreshed: $refreshed"

    if [ "${#healed[@]}" -gt 0 ]; then
        echo "Healed:    ${#healed[@]}   (stale branch removed, switched to default)"
        local h
        for h in "${healed[@]}"; do echo "  - $h"; done
    fi

    if [ "${#attention[@]}" -gt 0 ]; then
        echo
        echo "⚠️  Needs your attention (${#attention[@]})"
        local a
        for a in "${attention[@]}"; do echo "  - $a"; done
    fi

    if [ "${#errors[@]}" -gt 0 ]; then
        echo
        echo "❌ Errors (${#errors[@]})"
        local e
        for e in "${errors[@]}"; do echo "  - $e"; done
    fi

    # Exit non-zero only on genuine errors; unfinished work does not fail the run.
    [ "${#errors[@]}" -eq 0 ]
}

# Only run when executed directly, so the functions can be sourced for testing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
