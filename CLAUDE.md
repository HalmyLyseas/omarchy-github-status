# omarchy-github-status (`halmylyseas.github-status`)

An Omarchy shell plugin: a status-bar dashboard for a solo maintainer's own
GitHub repos — notifications inbox, own open PRs with CI/review state,
review requests, and per-repo activity — powered entirely by the user's own
authenticated `gh` CLI.

This file is the project charter. The PM workspace is
`~/git/omarchy-github-status-plugin/` — its `exchange/` holds the numbered
handoff docs. Read the **highest-numbered** doc first; `06-design.md` is the
binding spec, `03/04/05` are the live-verified research it rests on. On a
fresh clone without `exchange/`, this file + README + `docs/developers.md`
are enough to build and maintain the plugin.

## The outcome this project must achieve

From the bar, the user can see at a glance and in one click:

1. Unread GitHub notifications (count in the bar, list in the panel).
2. Their own open PRs with CI and review status.
3. PRs waiting on their review.
4. Activity across their own repos: latest commit, open issues/PRs, latest
   release.
5. Click any item → it opens on github.com in the browser.

Done means: all five work live on this machine, `omarchy plugin validate`
passes, tests pass, and the repo is submission-ready for the Omarchy plugin
marketplace — **submission itself is gated on explicit human approval and
is never performed by an agent.**

## Hard rules

1. **The plugin never sees a credential.** All GitHub access is through the
   user's `gh` CLI. Never read, log, or store a token; never run
   `gh auth login/logout/refresh/token`.
2. **Read-only GitHub.** Only `gh api` GET and `gh api graphql` queries —
   never a mutation, never `-X POST/PATCH/PUT/DELETE`, never any gh
   subcommand that changes remote state.
3. **Security invariants of `exchange/06-design.md` are non-negotiable**:
   no disk cache / no FileView; `Text.PlainText` on all remote strings;
   URL opens allowlisted to `https://github.com/` and spawned as an
   argument array (no shell); no package-manager command strings in any
   shipped doc; no service-manager invocations or unit files; fixed
   command strings only — remote data is never interpolated into a shell
   string.
4. **Never modify anything under `/usr/share/omarchy/`** (reading is
   encouraged). Never `omarchy plugin clone` a first-party plugin. Never
   run `omarchy refresh` / `omarchy reinstall`.
5. Working repo is `~/git/omarchy-github-status-plugin/plugin/`; live
   testing goes through the rsync install step in `06-design.md` ("Dev
   workflow") to spare the user's bar from per-save reload flashes. At
   release the installed folder becomes the canonical clone.

## Environment (measured 2026-08-27 on the author's machine)

Omarchy 4.0.1-1 · Quickshell 0.3.1-1 · Hyprland 0.56.2-1 · gh 2.98.0 (via
mise). See `exchange/03-shell-api.md` §12 and its traps checklist (§13) —
every trap there is measured fact, not hypothesis.

## Working agreement

- `exchange/` is the handoff log: numbered docs, written for zero-context
  readers, absolute paths, `file:line`, exact commands, evidence per claim.
- Measure, don't assume — probe the live system; probe output to files,
  never pipes.
- Scope before code; deviations from `06-design.md` need a numbered doc.
