# omarchy-github-status (`halmylyseas.github-status`)

An Omarchy shell plugin: a status-bar dashboard for a solo maintainer's own
GitHub repos — notifications inbox, own open PRs with CI/review state,
review requests, own open issues, and per-repo activity — powered entirely
by the user's own authenticated `gh` CLI.

## The outcome this project must achieve

From the bar, the user can see at a glance and in one click:

1. Unread GitHub notifications (count in the bar, list in the panel).
2. Their own open PRs with CI and review status.
3. PRs waiting on their review.
4. Their own open issues, with a Subscribed/All toggle.
5. Activity across their own repos: latest commit, open issues/PRs, latest
   release.
6. Click any item → it opens on github.com and closes the popup.

Done means: all six work live on this machine, `omarchy plugin validate`
passes, `bash test/all` passes, and the repo is submission-ready for the
Omarchy plugin marketplace — **submission itself is gated on explicit
human approval and is never performed by an agent.**

## Hard rules

1. **The plugin never sees a credential.** All GitHub access is through the
   user's `gh` CLI. Never read, log, or store a token; never run
   `gh auth login/logout/refresh/token`.
2. **Read-only GitHub.** Only `gh api` GET and `gh api graphql` queries —
   never a mutation, never `-X POST/PATCH/PUT/DELETE`, never any gh
   subcommand that changes remote state.
3. **`gh` is a direct Quickshell `Process` child, never a shell wrapper.**
   Its path is resolved once via `bash -lc "type -P gh"` (the only shell
   invocation anywhere); every fetch after that is a fixed argv array plus
   at most a sanitised ETag as its own element.
4. **Security invariants are non-negotiable**: no disk cache of GitHub data
   (settings persist through `shell.updateEntryInline`, nothing else does);
   `Text.PlainText` on every remote-derived `Text{}` sink; URL opens
   allowlisted to `https://github.com/` and spawned as an argument array (no
   shell); no package-manager or service-manager command strings anywhere in
   this plugin; fixed command strings only — remote data is never
   interpolated into a shell string.
5. **Never modify anything under `/usr/share/omarchy/`** (reading is
   encouraged). Never run `omarchy refresh`/`omarchy reinstall`.
6. See `docs/threat-model.md` for the full asset/boundary model this plugin
   is held to.

## Working agreement

- Develop in a separate clone (`~/git/omarchy-github-status-plugin/work`),
  commit there, then deploy in one burst:
  `git -C ~/.config/omarchy/plugins/halmylyseas.github-status pull
  <work-clone> <branch>`, followed by `omarchy restart shell`.
- `bash test/all` before every deploy; `omarchy plugin validate .` and
  qmllint (0 errors) before every commit that touches `.qml`.
- Installs and updates track the installed folder's branch **HEAD**, not a
  specific reviewed commit — so `master` is release-only; work happens on a
  feature/hardening branch and only lands on `master` when ready to ship.
- Marketplace submission is a human-approved step only, never filed by an
  agent. See `docs/developers.md` "Releasing".
