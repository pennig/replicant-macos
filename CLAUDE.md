# CLAUDE.md — replicant-macos

This repo holds two codebases:

- **`app/`** — the Replicould macOS client (Swift/SwiftUI). See `app/CLAUDE.md` for its rules and design source of truth.
- **`relay/`** — the Rust relay proxy deployed to Vercel.

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature-slug>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Multi-context — a root `CONTEXT-MAP.md` points at one `CONTEXT.md` per context (`app/`, `relay/`). See `docs/agents/domain.md`.
