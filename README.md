# GitHub Status

Not a notification inbox — a status-bar dashboard for a solo maintainer's own
repos: activity, own open PRs with CI/review state, review requests,
alongside notifications.

<!-- TODO: preview.png screenshot goes here once the panel UI (stage S3) exists. -->

From the bar you can see, at a glance and in one click:

- Unread GitHub notifications — count in the bar, list in the panel.
- Your own open PRs, with CI status and review decision.
- PRs waiting on your review.
- Activity across your own repos: latest commit, open issues/PRs, latest
  release.
- Click any item to open it on github.com in your browser.

## Features

- **Bar glyph + count pill** for unread notifications, recoloring when any of
  your own open PRs has failing CI or you have a pending review request.
- **Inbox** — unread notifications with repo, title, reason, and relative
  time.
- **Review requests** — PRs waiting on you, shown ahead of your own PRs
  because someone else is blocked on you.
- **My open PRs** — title, repo, draft flag, CI rollup, and review decision
  for every open PR you have across every repo you can access, not just one
  repo at a time.
- **Repo activity** — your own repos ordered by most recently pushed, with
  open issue/PR counts and the latest release tag where one exists.
- **Graceful degradation** — if `gh` isn't installed, isn't signed in, the
  network is down, or you're rate-limited, the panel says so plainly and
  keeps showing your last-known-good data instead of going blank.

## Requirements

This plugin never touches a credential of its own. Every GitHub call goes
through the GitHub CLI (`gh`), using whichever account you've already
authenticated it with — the plugin reads and displays only what `gh` is
already allowed to see. Install and sign in to the GitHub CLI first; see
[cli.github.com](https://cli.github.com/) for instructions for your system,
then run its sign-in flow once from a terminal. If `gh` is missing or not
signed in, the bar tells you so instead of failing silently.

## Install

```bash
omarchy plugin add https://github.com/HalmyLyseas/omarchy-github-status
```

The plugin installs disabled so you can review the code first. Enable it
from Omarchy's plugin settings, or:

```bash
omarchy plugin enable halmylyseas.github-status
```

The GitHub glyph appears in the bar's right section.

## Usage

Click the bar icon to open the panel. It refreshes automatically in the
background; the hero row also has a manual refresh button for "check right
now." Click any notification, PR, review request, or repo row to open it on
github.com in your default browser.

## Settings

Available from Omarchy's own bar-widget settings form (no in-panel settings
UI in this version):

| Setting | Default | Range | Meaning |
|---|---|---|---|
| Dashboard refresh interval | 180s | 60–3600s | How often PRs, review requests, and repo activity refresh. |
| Notifications poll interval | 60s | 60–600s | How often the notifications inbox polls. Matches GitHub's own guidance; conditional requests mean an unchanged inbox costs nothing. |
| Repos shown in activity list | 10 | 3–30 | How many of your repos appear in the activity section. |

## Security & privacy

- **The plugin never sees a credential.** All GitHub access goes through
  your own `gh` CLI session; the plugin never reads, logs, or stores a
  token, and never runs any `gh auth` command that could change or expose
  one.
- **Read-only.** Every GitHub call is a `gh api` GET or a GraphQL `query` —
  never a mutation. This plugin cannot star, comment, merge, close, or
  change anything on your behalf.
- **No disk cache.** All state lives in memory for the life of the shell
  session; nothing about your notifications, PRs, or repos is written to
  disk by this plugin.
- **Only github.com opens.** Every clickable item is checked against a
  strict `https://github.com/` prefix before your browser is asked to open
  it, and that open never goes through a shell — no other host or scheme is
  ever launched.

## License

[MIT](LICENSE)
