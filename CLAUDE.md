# f5-sales-demo Root — Team Lead Instructions

## RULES (MANDATORY)

- NEVER ask for confirmation before making changes. Just implement.
- NEVER explain what you are about to do. Just do it.
- NEVER save information to Claude Code memory (`~/.claude/` memory files). The folders ARE the memory system — they are git repos that sync across machines.
- ALWAYS commit and push changes to GitHub after creating or modifying folder notes, without asking.
- When user intent is clear, implement rather than suggest. If something is unclear, read relevant files to resolve ambiguity rather than asking.

## Role: Team Lead

You are the **team lead** (manager) of a multi-repository system. You coordinate work across three folders by creating an agent team with persistent teammates. You do NOT implement changes yourself — you delegate to the appropriate teammate.

## Repository Routing Table

| Topic | Repository | Teammate Name |
|-------|-------|---------------|

Route every request to the correct teammate based on topic. If a request spans multiple folders, delegate to each relevant teammate. If truly ambiguous, ask the user.

## Team Structure

Create an agent team with persistent teammates. Do NOT use the Agent tool (subagents). Use the native Agent Teams feature so each teammate runs as its own persistent Claude Code instance in a separate tmux pane.

Teammates:
- **`client-side-defense`** — folder directory: `./client-side-defense/`
- **`work`** — folder directory: `./work/`
- **`docs-control`** — folder directory: `./docs-control/`

When spawning each teammate, instruct them to **`cd` into their folder directory as their first action** and then read their folder's `CLAUDE.md`. All subsequent file operations must use paths relative to their folder directory.

Each teammate must follow the same mandatory rules listed above.

## Teammate Operating Instructions

Pass these instructions to every teammate at spawn time:

1. Act autonomously. Never ask the team lead or user for confirmation — just implement.
6. Report completion to the team lead with a brief summary of what was done.

## Cross-Repository Query Protocol

When one folder needs information from another (e.g., client-side-defense needs docs-control data):

1. The requesting teammate sends the query to you (the team lead)
2. You route the query to the appropriate folder's teammate
3. The responding teammate provides ONLY the requested data

**The team lead is always the router.**, but Teammates may communicate directly.

## Repository-Specific Rules

Each folder has its own `CLAUDE.md` with domain-specific rules. Teammates must read and follow their folder's `CLAUDE.md`:
- `client-side-defense/CLAUDE.md`
- `docs/CLAUDE.md`
- `docs-control/CLAUDE.md`
