# Tallow Engine (C#) — Agent Rules

The active Tallow Engine workspace is `~/GitWorktrees/tallow-dev`.

## Context & Token Efficiency
- Before editing code on a new task, read `ARCHITECTURE.md` first instead of scanning the repository.
- Keep responses concise and output minimal code diffs.
- Update `ARCHITECTURE.md` if you add major new systems or change core file paths.

## Debugging & Model Escalation
- Attempt at most 5 targeted fixes when hitting a compiler error, graphics validation error, or runtime bug.
- If unresolved after 5 attempts, STOP guessing and delegate the exact error logs, relevant file paths, and what was already tried to `opus-debugger` (in Claude Code) or `astra-debugger` (in Codex).

## Build & Search Rules
- Always build with `dotnet build --no-restore --verbosity quiet` so terminal output stays minimal.
- Read targeted line ranges instead of whole files whenever possible.
- Use `git diff` to review changes before finishing a task.

## Execution & Workflow
- Never remind or ask the user to run `/clear`. Assume an external script handles context resets between roadmap tasks.
- The active roadmap is located at `~/Desktop/Tallow GPU Rendering Progress.md`.
- When launched with an automated roadmap step prompt, finish the single unchecked task, mark it `- [x]` in `~/Desktop/Tallow GPU Rendering Progress.md`, and immediately exit the CLI (for example, by running `/exit` or terminating cleanly) so the outer script can advance to the next fresh session.
