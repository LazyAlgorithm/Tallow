# Tallow Engine (C#) — Agent Rules

The active Tallow Engine workspace is `~/GitWorktrees/tallow-dev`.

## Context & Token Efficiency
- Before editing code on a new task, read `ARCHITECTURE.md` first instead of scanning the repository.
- Keep responses concise and output minimal code diffs.
- Update `ARCHITECTURE.md` if you add major new systems or change core file paths.
- After completing a milestone or feature, remind the user to run `/clear`.

## Debugging & Model Escalation
- Attempt at most 5 targeted fixes when hitting a compiler error, graphics validation error, or runtime bug.
- If unresolved after 5 attempts, STOP guessing and delegate the exact error logs, relevant file paths, and what was already tried to `opus-debugger` (in Claude Code) or `astra-debugger` (in Codex).

## Build & Search Rules
- Always build with `dotnet build --no-restore --verbosity quiet` so terminal output stays minimal.
- Read targeted line ranges instead of whole files whenever possible.
- Use `git diff` to review changes before finishing a task.
