# `clone-all-repos.sh` — design & reference

One script to clone, and keep fresh, a local copy of every repo in the
`f5-sales-demo` ecosystem.

## Purpose

1. **Clone everything once.** A developer runs it in an empty folder and gets a local
   checkout of every repo listed in the [downstream-repos manifest][manifest], plus
   `docs-control` and `.github`.
2. **Clone only the work you actually do.** The fleet is not homogeneous — content repos
   are authored with xcsh, code and plumbing repos with a coding harness. A class flag
   scopes the clone to one kind of work instead of dragging in the rest.
3. **Stay fresh, idempotently.** Re-running pulls the latest commits everyone has pushed.
   Running it ten times in a row is safe.
4. **Sanity-check the developer's working tree and act correctly.** The guiding rule: a
   repo with any local work is **never modified** — it is only reported, so unfinished
   work is impossible to lose.

## Usage

```bash
# From the folder that should contain the clones (repos are created as siblings):
/path/to/.github/clone-all-repos.sh
```

Requires `curl`, `jq`, and `git` on `PATH`. The repo list is read at runtime from the
manifest, so onboarding a new repo there is picked up automatically on the next run.

## Filtering by repository class

`docs-control` classifies every governed repo in [`repo_classes`][repo_classes], inside
`.claude/governance.json`. That file is a managed file synced byte-identically across the
fleet, so it is the same classification xcsh reads for `xcsh://fleet`. The script fetches
it and filters on it.

| Flag | Class | What it holds |
|---|---|---|
| `--content` | `content` | Docs, Terraform plans, network diagrams, demo scripts — authored with **xcsh** |
| `--developer`, `--code` | `developer` | Code with its own build and test harness — worked in with **Claude Code / Codex** |
| `--scaffolding`, `--infrastructure` | `scaffolding` | Fleet plumbing: CI, packaging, images, governance |
| `--class <a>[,<b>]` | any | Select by name; comma-separated, repeatable |
| *(no flag)* | all | Every repo — the original behavior, unchanged |

Flags combine as a union, and `--dry-run` resolves the list and prints it without touching
anything:

```bash
clone-all-repos.sh --content              # an authoring workspace
clone-all-repos.sh --code --dry-run       # what a code-only clone would contain
clone-all-repos.sh --content --code       # both, minus the scaffolding
```

Three behaviors worth knowing:

- **`docs-control` and `.github` are bootstrap repos** and are cloned under every filter.
  They carry the manifest and this script, so a scoped workspace can still update itself.
- **An unclassified repo inherits the manifest's `_default`** (`developer`), the same
  fail-closed rule the rest of the fleet uses. A repo onboarded to
  `downstream-repos.json` but not yet classified is therefore never swept into a
  `--content` clone by accident — it shows up as `developer` until someone classifies it.
- **A filter that cannot be resolved is a hard error.** If `governance.json` is
  unreachable the script exits non-zero and prints the `gh api` command to read the
  classification by hand, rather than silently cloning everything. Without a filter the
  fetch is best-effort: it only labels the output, so an unfiltered run never gains a new
  way to fail — and every repo is then labelled `unclassified`, never a guessed class.

An unknown class name is rejected up front (`--class contnet` exits `2` and lists the
valid names) instead of quietly resolving to an empty repo list.

## Per-repo outcomes

After `git fetch --prune`, every existing repo is classified into exactly one outcome.
A **universal preflight** runs first: if the working tree is dirty or has unpushed
commits (or HEAD is detached), the repo is `attention` and is left exactly as found —
**before** any fast-forward or branch switch is considered. Only genuinely clean repos
proceed to be fast-forwarded or healed.

| Status | Condition | Action |
|---|---|---|
| `cloned` | directory absent | `git clone` |
| `refreshed` | clean; on the default branch **or** a live feature branch | fast-forward to its upstream (or already current) |
| `healed` | clean; parked on a branch that was merged & deleted upstream | delete the stale branch, switch to the default branch, fast-forward |
| `attention` | uncommitted changes and/or unpushed commits, or detached HEAD | **fetch only — never modified** |
| `error` | `fetch`/`clone` failed, or an unexpected non-fast-forward | reported as a hard failure |

Notes:
- A clean feature branch that still exists upstream is **fast-forwarded in place**; you
  stay checked out on it.
- "Unpushed commits" means commits on `HEAD` not present on the configured upstream
  (or, for a never-pushed/pruned branch, not contained in any remote branch).

## End-of-run summary

`Cloned` and `Refreshed` are always shown; the other sections appear only when non-empty:

```
===== Summary =====
Filter:    all   (40 repos)
Cloned:    0
Refreshed: 33
Healed:    1   (stale branch removed, switched to default)
  - docs-control: removed 'feat/require-translation-audit'

⚠️  Needs your attention (2)
  - console: 1 uncommitted file on 'main'
  - marketplace: 2 unpushed commits on 'chore/example-naming-convention'

❌ Errors (1)
  - xcsh: fetch failed
```

**Exit code** is non-zero only when there are `error` repos. `attention` is a normal
developer state, not a failure, so it does not fail the run — automation can still gate
on real errors.

## Tests

`clone-all-repos.test.sh` sources the script (its `main` is guarded by a `BASH_SOURCE`
check, so sourcing runs no network calls) and drives `refresh_repo` against local git
fixtures — a bare "remote" plus a working clone built in a temp dir per scenario. It
covers each outcome including the universal checks (dirty on `main`, unpushed commits on
a live feature branch).

The filtering scenarios (M–P) need neither git nor the network: `parse_args` is exercised
on argv alone, and `select_repos` / `validate_classes` are handed both manifests as
literals. The fixture manifest deliberately does not resemble the real fleet, so a passing
test can never be an accident of the live classification.

Run it directly:

```bash
./clone-all-repos.test.sh        # 79 assertions across 12 scenarios; exits non-zero on failure
shellcheck clone-all-repos.sh clone-all-repos.test.sh
```

[manifest]: https://raw.githubusercontent.com/f5-sales-demo/docs-control/refs/heads/main/.github/config/downstream-repos.json
[repo_classes]: https://raw.githubusercontent.com/f5-sales-demo/docs-control/refs/heads/main/.claude/governance.json
