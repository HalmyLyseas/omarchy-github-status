# GitHub Status

Not a notification inbox — a status-bar dashboard for a solo maintainer's own
repos: activity, own open PRs with CI/review state, review requests,
alongside notifications.

![GitHub Status bar widget and panel](preview.png)

From the bar you can see, at a glance and in one click:

- Unread GitHub notifications — count in the bar, list in the panel.
- Your own open PRs, with CI status and review decision.
- PRs waiting on your review.
- Open issues you yourself authored, across every repo — with a
  **Subscribed** toggle so unsubscribed clutter stays out of your way by
  default.
- Activity across your own repos: latest commit, open issues/PRs, latest
  release, most-recently-pushed first, with an archived/fork/private status
  pill.
- A live search field at the top of the panel filters every section as you
  type.
- Hover a PR or issue row to see who commented last and when.
- Click any populated section header to fold it out of the way.
- Click any item to open it on github.com in your browser.

## Features

- **Bar glyph + count pill** for unread notifications, recoloring when any of
  your own open PRs has failing CI or you have a pending review request.
- **Inbox** — unread notifications with repo, title, reason, and relative
  reception age.
- **Review requests** — PRs waiting on you, shown ahead of your own PRs
  because someone else is blocked on you.
- **My open PRs** — title, repo, draft flag, CI rollup, review decision, and
  relative last-activity age for every open PR you have across every repo
  you can access, not just one repo at a time.
- **My open issues** — every issue you yourself opened and is still open,
  across every repo, with a relative last-activity age. A **Subscribed**
  toggle chip in the section header (active by default) hides issues you've
  unsubscribed from, so old clutter you no longer care about doesn't linger
  in the panel — toggle it off to see every open issue again.
- **Repositories** — your own repos with open issue/PR counts and the latest
  release tag where one exists, most-recently-pushed first.
- **Search** — a live filter field at the top of the panel. Type anything
  and every section (notifications, PRs, review requests, issues, repos)
  narrows to matching title/repo/owner/name in place; count pills reflect
  what's actually shown while you search. Esc clears the query first, then
  closes the panel on a second press; a clear (✕) button is always
  available too.
- **Last commenter on hover** — hover a PR, review-request, or issue row to
  see who commented last and how long ago, when there's a comment to show.
- **Fold sections you don't need** — click any populated section header to
  collapse it to just its title and count for the rest of the session (it
  reopens the next time you open the panel). A small chevron next to the
  header text tells you it's collapsible; empty sections have no chevron
  since they're already as compact as they get.
- **Status pills everywhere** — every section header carries a right-aligned
  count pill (unread count for Inbox, rendered/filtered-list length
  elsewhere), and a section with nothing in it folds to just that header
  row — no empty-state filler text. Repo rows get an archived/fork/private
  pill (archived wins when more than one applies); PR/issue/inbox rows for a
  repo you don't own get a small pill naming the external owner.
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
| Dashboard refresh interval | 180s | 60–3600s | How often PRs, review requests, and repositories refresh. |
| Notifications poll interval | 60s | 60–600s | How often the notifications inbox polls. Matches GitHub's own guidance; conditional requests mean an unchanged inbox costs nothing. |
| Repos shown in repositories list | 10 | 3–30 | How many of your repos appear in the Repositories section, most-recently-pushed first. |
| Subscribed only | Focus | Focus / All | Whether My open issues shows only issues you're still subscribed to (Focus) or every open issue you authored (All) — also toggleable from the panel's **Subscribed** chip in the My open issues section header. |

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

## Removal

```bash
omarchy plugin remove halmylyseas.github-status
```

This disables the plugin and deletes its folder. Since nothing here is
written to disk in the first place (no disk cache, no settings UI beyond
Omarchy's own bar-widget form), there's nothing else to clean up — removal
just stops the bar glyph and its background polling.

## License

[MIT](LICENSE)
