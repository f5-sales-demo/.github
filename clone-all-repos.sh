#!/usr/bin/env bash
#
# Clone (or refresh) downstream repos from the f5-sales-demo organization.
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
# The fleet is not homogeneous, and the work in it is split by tool: content repos are
# authored with xcsh, code and plumbing repos with a coding harness. docs-control declares
# that split in `repo_classes`, so a clone can be scoped to one kind of work rather than
# dragging in every repo. Run with --help for the flags; with none, everything is cloned
# exactly as before.
#

set -euo pipefail

MANIFEST_URL="https://raw.githubusercontent.com/f5-sales-demo/docs-control/refs/heads/main/.github/config/downstream-repos.json"
GOVERNANCE_URL="https://raw.githubusercontent.com/f5-sales-demo/docs-control/refs/heads/main/.claude/governance.json"
ORG="f5-sales-demo"

# Outcome of the most recent refresh_repo/clone_repo call (read by the caller).
REPO_STATUS=""   # cloned | refreshed | healed | attention | error
REPO_DETAIL=""   # human-readable specifics for the summary

# Set by parse_args. SELECTED_CLASSES is space-delimited and space-padded when non-empty
# (" content developer "), so membership is a plain `case` match; empty means "no filter".
SELECTED_CLASSES=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: clone-all-repos.sh [CLASS FLAGS] [--dry-run]

Clone or refresh repos of the f5-sales-demo ecosystem as siblings in the current
directory. With no class flag, every repo is processed.

Class flags (repeatable; combining them clones the union):
  --content                      content repos -- docs, Terraform plans, diagrams,
                                 demo scripts. Authored with xcsh.
  --developer, --code            repos with their own build and test harness.
                                 Worked in with a coding harness.
  --scaffolding, --infrastructure
                                 fleet plumbing: CI, packaging, images, governance.
  --class <a>[,<b>...]           select classes by name, comma-separated.

Other:
  --dry-run                      print the resolved repo list and exit; touch nothing.
  -h, --help                     show this help.

'docs-control' and '.github' are bootstrap repos: they carry the manifest and this
script itself, so they are always included whatever the filter, keeping a scoped
workspace able to update itself.

The classification is read from repo_classes in docs-control/.claude/governance.json.
A repo absent from it inherits that manifest's fail-safe default, so a newly onboarded
repo is never swept into a --content clone by accident.

Examples:
  clone-all-repos.sh                     # the whole ecosystem
  clone-all-repos.sh --content           # just the content repos, for authoring
  clone-all-repos.sh --code --dry-run    # what a code-only clone would contain
EOF
}

# Add "$1" to SELECTED_CLASSES unless already present. The list is space-padded
# (" a b ") so a `case` membership test can never match a partial name. Names are
# restricted to a safe character set, which also keeps the unquoted expansions
# below free of glob surprises.
add_class() {
    case "$1" in
        "" | *[!a-z0-9_-]*)
            echo "Error: invalid class name '$1' (expected lowercase letters, digits, '-' or '_')." >&2
            exit 2
            ;;
    esac
    case "${SELECTED_CLASSES:- }" in
        *" $1 "*) return 0 ;;
    esac
    if [ -z "$SELECTED_CLASSES" ]; then
        SELECTED_CLASSES=" $1 "
    else
        SELECTED_CLASSES="${SELECTED_CLASSES}$1 "
    fi
}

# Split a comma-separated class list and add each entry. Splitting with parameter
# expansion rather than IFS avoids both word-splitting and globbing side effects.
add_class_list() {
    local rest="$1" item
    if [ -z "$rest" ]; then
        echo "Error: --class requires at least one class name." >&2
        exit 2
    fi
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*) item="${rest%%,*}"; rest="${rest#*,}" ;;
            *)   item="$rest";       rest="" ;;
        esac
        if [ -n "$item" ]; then add_class "$item"; fi
    done
}

# True when "$1" passes the active filter. No filter selects everything.
class_selected() {
    if [ -z "$SELECTED_CLASSES" ]; then return 0; fi
    case "$SELECTED_CLASSES" in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# The selected classes as a human-readable string ("all" when unfiltered).
classes_label() {
    if [ -z "$SELECTED_CLASSES" ]; then
        echo "all"
        return 0
    fi
    local c out=""
    for c in $SELECTED_CLASSES; do
        if [ -z "$out" ]; then out="$c"; else out="$out, $c"; fi
    done
    echo "$out"
}

# Populate SELECTED_CLASSES and DRY_RUN from the command line. Exits directly on
# --help (0) and on a bad invocation (2); every other path returns so the globals
# can be inspected by the caller and by the tests.
parse_args() {
    SELECTED_CLASSES=""
    DRY_RUN=0
    local arg
    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --content)                      add_class content ;;
            --developer | --code)           add_class developer ;;
            --scaffolding | --infrastructure) add_class scaffolding ;;
            --class)
                if [ "$#" -lt 2 ]; then
                    echo "Error: --class requires a value." >&2
                    exit 2
                fi
                shift
                add_class_list "$1"
                ;;
            --class=*) add_class_list "${arg#--class=}" ;;
            --dry-run) DRY_RUN=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                echo "Error: unknown option '$arg'." >&2
                echo >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
    return 0
}

# Reject any selected class the manifest does not define. A typo would otherwise
# resolve to an empty repo list and look like a fleet with nothing in it.
validate_classes() {
    local gov="$1" known unknown="" c
    known=$(echo "$gov" | jq -r '.repo_classes.classes | keys[]' 2>/dev/null || true)
    if [ -z "$known" ]; then
        echo "Error: the governance manifest declares no repo_classes.classes." >&2
        return 1
    fi
    for c in $SELECTED_CLASSES; do
        if ! echo "$known" | grep -qxF "$c"; then
            unknown="${unknown} ${c}"
        fi
    done
    if [ -n "$unknown" ]; then
        echo "Error: unknown repository class:${unknown}" >&2
        echo "Valid classes: $(echo "$known" | tr '\n' ' ')" >&2
        return 1
    fi
    return 0
}

# Echo "<owner>/<name><TAB><class>" for every manifest entry that passes the filter.
# The manifest-to-class join is a single jq pass, so bash only has to filter -- no
# associative array, which macOS bash 3.2 does not have.
#
# $1 = downstream-repos.json contents, $2 = governance.json contents.
select_repos() {
    local manifest="$1" gov="$2" pairs full class
    pairs=$(jq -rn --argjson m "$manifest" --argjson g "$gov" --arg org "$ORG" '
        ($g.repo_classes // {})       as $rc |
        ($rc._default // "developer") as $dflt |
        $m[]
        | (if test("/") then . else "\($org)/\(.)" end) as $full
        | ($full | split("/") | last)                   as $name
        | "\($full)\t\($rc.repos[$name] // $dflt)"
    ') || return 1

    while IFS=$'\t' read -r full class; do
        if [ -z "$full" ]; then continue; fi
        if class_selected "$class"; then
            printf '%s\t%s\n' "$full" "$class"
        fi
    done <<EOF
$pairs
EOF
}

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

# Ensure "$1"'s origin points at the canonical "$2" ("<owner>/<name>").
#
# An org rename leaves existing clones on the old owner indefinitely: GitHub
# redirects both fetch and push, so nothing ever fails loudly and refresh_repo
# would keep using the stale URL forever. Heal it here, before the fetch, so
# the fetch itself goes to the canonical location.
#
# Only an owner change on a matching repo name is healed, and the existing
# transport is preserved -- an SSH remote stays SSH. A remote whose repo name
# differs is a deliberate choice by whoever set it: report it, never guess.
#
# Sets ORIGIN_STATUS to one of: ok | healed | mismatch | missing
reconcile_origin() {
    local dir="$1" full_name="$2"
    local want_owner="${full_name%/*}" want_name="${full_name##*/}"
    ORIGIN_STATUS="ok"
    ORIGIN_DETAIL=""

    local url
    if ! url=$(git -C "$dir" remote get-url origin 2>/dev/null) || [ -z "$url" ]; then
        echo "  Warning: no 'origin' remote -- left untouched."
        ORIGIN_STATUS="missing"; ORIGIN_DETAIL="no 'origin' remote"
        return 1
    fi

    # Split "<prefix><owner>/<name>[.git]" without assuming a transport.
    local path="${url%.git}"
    local name="${path##*/}"
    local rest="${path%/*}"
    local owner="${rest##*[:/]}"

    if [ "$owner" = "$want_owner" ] && [ "$name" = "$want_name" ]; then
        return 0
    fi

    if [ "$name" != "$want_name" ]; then
        echo "  Warning: origin is '$owner/$name', expected '$full_name' -- left untouched."
        ORIGIN_STATUS="mismatch"; ORIGIN_DETAIL="origin is '$owner/$name'"
        return 1
    fi

    # Same repo, different owner: an org rename. Rebuild only the owner segment
    # so the transport (ssh / https / filesystem path) survives untouched.
    local suffix="$owner/$name"
    local prefix="${path%"$suffix"}"
    local new_url="${prefix}${want_owner}/${want_name}"
    case "$url" in *.git) new_url="${new_url}.git" ;; esac

    if ! git -C "$dir" remote set-url origin "$new_url"; then
        echo "  Warning: failed to update origin for $dir"
        ORIGIN_STATUS="mismatch"; ORIGIN_DETAIL="could not set origin"
        return 1
    fi

    echo "  Origin owner corrected: '$owner' -> '$want_owner'"
    ORIGIN_STATUS="healed"; ORIGIN_DETAIL="origin owner '$owner' -> '$want_owner'"
    return 0
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
    parse_args "$@"
    check_deps

    # --- Fetch manifest ---
    echo "Fetching repo manifest..."
    local json
    json=$(curl -fsSL "$MANIFEST_URL") || {
        echo "Error: failed to fetch manifest from $MANIFEST_URL" >&2
        exit 1
    }

    # --- Fetch the classification ---
    # Best-effort when unfiltered: it only labels the output there, and a run that
    # never asked for a filter must not start failing because of it. Required when
    # filtered: without the classification, cloning everything ignores what was asked
    # and cloning nothing is baffling, so say so and stop.
    local gov
    gov=$(curl -fsSL "$GOVERNANCE_URL" 2>/dev/null) || gov=""
    if [ -z "$gov" ] || ! echo "$gov" | jq -e '.repo_classes.repos' >/dev/null 2>&1; then
        if [ -n "$SELECTED_CLASSES" ]; then
            echo "Error: could not read repo_classes from $GOVERNANCE_URL," >&2
            echo "so the requested filter ($(classes_label)) cannot be resolved." >&2
            echo >&2
            echo "Read the classification manually with:" >&2
            echo "  gh api repos/$ORG/docs-control/contents/.claude/governance.json \\" >&2
            echo "    --jq .content | base64 -d | jq .repo_classes" >&2
            exit 1
        fi
        # Unfiltered, so the run continues -- but label the repos 'unclassified' rather
        # than letting them fall through to the built-in default. We did not read a
        # classification, and printing one we guessed would assert something untrue.
        echo "Note: classification unavailable; repos are labelled 'unclassified'."
        gov='{"repo_classes":{"_default":"unclassified","classes":{}}}'
    elif [ -n "$SELECTED_CLASSES" ]; then
        validate_classes "$gov" || exit 2
    fi

    # --- Build the work list: bootstrap repos first, then the filtered manifest ---
    # Entries are "<owner>/<name><TAB><class>". docs-control and .github carry the
    # manifest and this script, so they are in every run regardless of the filter.
    local entries=("$ORG/docs-control"$'\t'"bootstrap" "$ORG/.github"$'\t'"bootstrap")
    local selected line
    selected=$(select_repos "$json" "$gov") || {
        echo "Error: failed to resolve the repo list from the manifest." >&2
        exit 1
    }
    while IFS= read -r line; do
        if [ -n "$line" ]; then entries+=("$line"); fi
    done <<EOF
$selected
EOF

    local full_name class dir
    echo "Filter: $(classes_label) — found ${#entries[@]} repos to process (2 bootstrap)."
    echo

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "===== Dry run — nothing is cloned, fetched or modified ====="
        for line in "${entries[@]}"; do
            printf '  %-44s %s\n' "${line%%$'\t'*}" "${line#*$'\t'}"
        done
        echo
        echo "Total: ${#entries[@]} repos"
        return 0
    fi

    # --- Clone or refresh each repo ---
    local cloned=0 refreshed=0
    local healed=() attention=() errors=()

    for line in "${entries[@]}"; do
        full_name="${line%%$'\t'*}"
        class="${line#*$'\t'}"
        dir="${full_name##*/}"
        echo "--- $full_name [$class] ---"

        if [ -d "$dir" ]; then
            echo "  Directory exists, refreshing..."
            if reconcile_origin "$dir" "$full_name"; then
                if [ "$ORIGIN_STATUS" = "healed" ]; then
                    healed+=("$full_name: $ORIGIN_DETAIL")
                fi
                refresh_repo "$dir" || true
            else
                # Origin is absent or points at a different repo entirely;
                # refreshing would fetch from the wrong place.
                REPO_STATUS="attention"; REPO_DETAIL="$ORIGIN_DETAIL"
            fi
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
    echo "Filter:    $(classes_label)   (${#entries[@]} repos)"
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
