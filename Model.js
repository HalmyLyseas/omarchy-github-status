// Model.js -- pure data-mapping library for halmylyseas.github-status.
//
// No Quickshell imports, no QML types, no mutable module-level state that
// depends on a shared-singleton instance -- every exported symbol here is a
// plain function of its arguments. That is what makes this file loadable
// two different ways:
//   1. As a QML JS module: `import "Model.js" as Model` from Service.qml,
//      BarWidget.qml, Panel.qml. `.pragma library` is deliberately omitted
//      (see ~/.config/omarchy/plugins/halmylyseas.ristretto/Model.js for the
//      precedent that DOES need it, because it holds shared read-only
//      constant tables referenced identically from multiple importers --
//      this file has no such state, so each importer getting its own copy
//      of these functions is harmless).
//   2. As a Node CommonJS module via the guarded `module.exports` block at
//      the end of this file, so `test/model.test.js` can `require()` it
//      directly with plain Node, no QML runtime involved.
//
// Every mapper here is defensive: null/missing/malformed input produces an
// empty result (never a thrown exception), and every list output is capped
// per the security invariant in exchange/06-design.md #8 (a pathological
// account -- thousands of notifications, repos, etc. -- must not be able to
// blow up the panel). Mappers never sanitize/mutate string content (that is
// the UI's job via Text.PlainText); they only ever produce plain JS
// objects/strings, never eval or execute anything.

var CAP_NOTIFICATIONS = 50
var CAP_PRS = 20
var CAP_REVIEW_REQUESTS = 20
var CAP_REPOS = 30
var CAP_MY_ISSUES = 20  // exchange/19-feedback-delta-spec.md F3 -- same cap shape as reviewRequests

// Per-field string-length caps (exchange/11-s5a-security-review.md F2): list
// LENGTH is already capped above; this bounds individual field length too,
// so a pathological/compromised remote field (title, headline, url, ...)
// can't grow the panel's memory/re-render cost unboundedly. Real GitHub API
// data never approaches these (issue/PR titles are server-capped ~256
// chars); this is defense-in-depth against a future API change, a
// misconfigured `gh` host, or a new field added later without the same
// care -- not a response to an observed real-world payload.
var FIELD_CAP_TEXT = 300    // titles / commit headlines
var FIELD_CAP_TAG = 100     // reasons / repo identifiers / release tags / timestamps
var FIELD_CAP_URL = 2048    // urls
// exchange/26-feedback2-delta-spec.md G2/G1: lastCommenter login cap (a
// GitHub login is already server-capped well under this); the search query
// cap is generous enough for any real typed query while still bounding a
// pathological/huge query string's cost in matchesQuery's per-item scan.
var FIELD_CAP_COMMENTER = 40
var QUERY_CAP = 100

var MONTH_NAMES = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
]

// --------------------------------------------------------------- utilities

function isArray(v) {
  return Object.prototype.toString.call(v) === "[object Array]"
}

function isString(v) {
  return typeof v === "string"
}

function isObject(v) {
  return v !== null && typeof v === "object" && !isArray(v)
}

function safeStr(v, fallback) {
  return isString(v) ? v : (fallback === undefined ? "" : fallback)
}

function safeNum(v, fallback) {
  return typeof v === "number" && !isNaN(v) ? v : (fallback === undefined ? 0 : fallback)
}

function truncate(v, maxLen, fallback) {
  var s = safeStr(v, fallback)
  return s.length > maxLen ? s.slice(0, maxLen) : s
}

// ------------------------------------------------------------- own vs external (F6)

// "owner/repo" (GraphQL nameWithOwner, or REST full_name -- same shape) ->
// just the owner segment. "" on anything that doesn't contain a "/" with
// content before it (missing/malformed repo identifier).
function ownerFromNameWithOwner(nameWithOwner) {
  var s = safeStr(nameWithOwner, "")
  var idx = s.indexOf("/")
  return idx > 0 ? s.slice(0, idx) : ""
}

// exchange/19-feedback-delta-spec.md F6: a row is "external" when its repo's
// owner segment differs from the viewer's own login, compared
// case-insensitively (GitHub logins/org names are case-insensitive; "Foo"
// and "foo" are the same account). Defensively conservative when either side
// is missing/unknown: an owner or login we can't determine is never flagged
// external (no pill is safer than a wrong pill from a false positive).
function isExternalOwner(owner, login) {
  var o = safeStr(owner, "")
  var l = safeStr(login, "")
  if (!o || !l) return false
  return o.toLowerCase() !== l.toLowerCase()
}

// ----------------------------------------------------- URL translation

// api.github.com REST subject -> a github.com web URL, string-rewrite only
// (never an extra network call -- see exchange/04-github-data.md #2).
// `subject` is the {type, url} shape the notifications API and our own
// mapped list items use. Returns "" when the subject type/url doesn't match
// a known pattern -- the caller is expected to fall back to the containing
// repository's html_url in that case.
//
// Hardened per exchange/11-s5a-security-review.md F1: owner/repo are
// restricted to the real GitHub identifier charset ([A-Za-z0-9_.-]+, no
// slash/control chars/whitespace can sneak through), and the trailing ID
// segment is captured loosely only long enough to be validated below
// against a charset specific to its API segment (numeric ID for
// issues/pulls/releases/discussions, hex SHA for commits) -- never the
// unbounded/unfiltered `(.+)$` the finding flagged. A crafted
// `.../pulls/1; rm -rf /` (the finding's own example) already fails to
// match at all (the embedded "/" breaks the `[^\/]+` rest capture before ID
// validation even runs).
var API_URL_RE = /^https:\/\/api\.github\.com\/repos\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/(issues|pulls|releases|discussions|commits)\/([^\/]+)$/
var SEGMENT_TO_WEB = {
  issues: "issues",
  pulls: "pull",       // the one real gotcha: plural API segment, singular web segment
  releases: "releases",
  discussions: "discussions",
  commits: "commit"    // also irregular: plural API segment, singular web segment
}
var SEGMENT_ID_RE = {
  issues: /^\d+$/,
  pulls: /^\d+$/,
  releases: /^\d+$/,
  discussions: /^\d+$/,
  commits: /^[0-9a-fA-F]{4,40}$/   // abbreviated-to-full commit SHA
}

function apiUrlToWebUrl(subject) {
  if (!isObject(subject)) return ""
  var url = subject.url
  if (!isString(url) || url.length === 0 || url.length > FIELD_CAP_URL) return ""
  var m = API_URL_RE.exec(url)
  if (!m) return ""
  var owner = m[1]
  var repo = m[2]
  var apiSegment = m[3]
  var rest = m[4]
  var webSegment = SEGMENT_TO_WEB[apiSegment]
  var idRe = SEGMENT_ID_RE[apiSegment]
  if (!webSegment || !idRe || !idRe.test(rest)) return ""
  return "https://github.com/" + owner + "/" + repo + "/" + webSegment + "/" + rest
}

// ----------------------------------------------------------- notifications

// Raw shape: array of { id, unread, reason, subject: {title, url, type},
// repository: {full_name, html_url}, updated_at }. See
// exchange/samples/notifications.json.
//
// `login` (exchange/19-feedback-delta-spec.md F6): the REST notifications
// API has no `viewer`-shaped field to read the account's own login from --
// unlike mapDashboard's GraphQL envelope, which carries `viewer.login`
// alongside the data it maps -- so the caller (Service.qml) passes in the
// login it separately learned from scripts/probe-auth's stdout. Optional:
// omitting it (or passing anything falsy) makes every item non-external
// (isExternalOwner's conservative default), never a thrown error.
function mapNotifications(json, login) {
  if (!isArray(json)) return []
  var out = []
  for (var i = 0; i < json.length && out.length < CAP_NOTIFICATIONS; i++) {
    var n = json[i]
    if (!isObject(n)) continue
    var subject = isObject(n.subject) ? n.subject : {}
    var repository = isObject(n.repository) ? n.repository : {}
    var repo = truncate(repository.full_name, FIELD_CAP_TAG)
    var owner = ownerFromNameWithOwner(repo)
    var webUrl = apiUrlToWebUrl(subject)
    if (!webUrl) webUrl = truncate(repository.html_url, FIELD_CAP_URL)
    out.push({
      id: truncate(n.id, FIELD_CAP_TAG, String(i)),
      unread: n.unread === true,
      reason: truncate(n.reason, FIELD_CAP_TAG),
      title: truncate(subject.title, FIELD_CAP_TEXT),
      repo: repo,
      webUrl: truncate(webUrl, FIELD_CAP_URL),
      updatedAt: truncate(n.updated_at, FIELD_CAP_TAG),
      isExternal: isExternalOwner(owner, login),
      owner: owner
    })
  }
  return out
}

// exchange/23-s11-delta-review.md F2: re-derives `isExternal` for an
// already-mapped notifications array without re-fetching or re-parsing the
// raw REST payload (Service.qml never retains that past
// handleNotificationsExit -- only the mapped list survives in
// internal.notifications). Every mapped item already carries its own
// `owner` field (computed independent of `login`, straight off the repo's
// nameWithOwner), so this is a pure, cheap re-derivation over data already
// in memory -- used once, the moment internal.login transitions from
// unknown to known via the opportunistic dashboard-response capture (see
// Service.qml's handleDashboardExit), so already-fetched inbox rows don't
// have to wait out a full notificationsIntervalSec poll to gain a correct
// owner pill. Manual field copy, not Object.assign -- this file stays
// ES5-compatible (see header comment) so plain Node can require() it.
function remapNotificationsExternal(list, login) {
  if (!isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    if (!isObject(item)) { out.push(item); continue }
    out.push({
      id: item.id,
      unread: item.unread,
      reason: item.reason,
      title: item.title,
      repo: item.repo,
      webUrl: item.webUrl,
      updatedAt: item.updatedAt,
      isExternal: isExternalOwner(item.owner, login),
      owner: item.owner
    })
  }
  return out
}

// ------------------------------------------------------------- CI rollup

// Accepts either a bare rollup state string ("SUCCESS"/"FAILURE"/...) or an
// object shaped like GraphQL's `statusCheckRollup` ({ state: "SUCCESS" }).
// null/undefined/anything else -> "none".
function ciRollupToState(rollup) {
  var state = rollup
  if (isObject(rollup)) state = rollup.state
  if (!isString(state)) return "none"
  switch (state.toUpperCase()) {
    case "SUCCESS": return "success"
    case "FAILURE":
    case "ERROR": return "failure"
    case "PENDING":
    case "EXPECTED": return "pending"
    default: return "none"
  }
}

// -------------------------------------------------------- last comment (G2)

// `comments(last: 1)` GraphQL connection -> { commenter, commentAt }, both
// "" when there is no comment at all, OR when the most recent comment's
// `author` is null. A null author is a genuine, documented GraphQL shape --
// a comment left by a since-deleted GitHub account -- not a malformed
// response (exchange/26-feedback2-delta-spec.md G2's explicit "handle it"
// note). Returned as one paired result rather than two independently-
// defensive fields: showing an age with no attributable login ("last
// comment: · 3d") would misrepresent who commented, and the UI's own
// contract (omit the tooltip line entirely when lastCommenter is "")
// already treats the two as a single unit -- so commentAt collapses to ""
// right alongside commenter whenever there's nothing attributable to show.
function lastComment(commentsConn) {
  var empty = { commenter: "", commentAt: "" }
  if (!isObject(commentsConn) || !isArray(commentsConn.nodes) || commentsConn.nodes.length === 0) return empty
  var node = commentsConn.nodes[commentsConn.nodes.length - 1]
  if (!isObject(node)) return empty
  var author = isObject(node.author) ? node.author : null
  var login = author ? safeStr(author.login, "") : ""
  if (!login) return empty
  return {
    commenter: truncate(login, FIELD_CAP_COMMENTER),
    commentAt: truncate(node.updatedAt, FIELD_CAP_TAG)
  }
}

// ---------------------------------------------------------- subscribed (G4)

// GraphQL's `viewerSubscription` enum on an Issue: "SUBSCRIBED" |
// "UNSUBSCRIBED" | "IGNORED" (a repo-level "mute", rare from this account's
// own issues but defended the same as UNSUBSCRIBED -- neither means "I want
// to keep seeing this by default"). exchange/26-feedback2-delta-spec.md G4:
// fail OPEN (true) on a missing/null field specifically -- a schema hiccup
// or an older/partial response must never silently hide the user's own
// issues -- but a field that resolved to anything other than exactly
// "SUBSCRIBED" is trusted as a real "not subscribed" signal.
function subscribedFromViewerSubscription(viewerSubscription) {
  if (viewerSubscription === undefined || viewerSubscription === null) return true
  return viewerSubscription === "SUBSCRIBED"
}

// ------------------------------------------------------------------ dashboard

function mapOpenPRs(login, nodes) {
  var arr = isArray(nodes) ? nodes : []
  var openPRs = []
  for (var i = 0; i < arr.length && openPRs.length < CAP_PRS; i++) {
    var pr = arr[i]
    if (!isObject(pr)) continue
    var prRepo = isObject(pr.repository) ? truncate(pr.repository.nameWithOwner, FIELD_CAP_TAG) : ""
    var prOwner = ownerFromNameWithOwner(prRepo)
    var rollup = null
    if (isObject(pr.commits) && isArray(pr.commits.nodes) && pr.commits.nodes.length > 0) {
      var lastCommitNode = pr.commits.nodes[pr.commits.nodes.length - 1]
      if (isObject(lastCommitNode) && isObject(lastCommitNode.commit)) {
        rollup = lastCommitNode.commit.statusCheckRollup
      }
    }
    var prComment = lastComment(pr.comments)
    openPRs.push({
      title: truncate(pr.title, FIELD_CAP_TEXT),
      repo: prRepo,
      number: safeNum(pr.number, 0),
      webUrl: truncate(pr.url, FIELD_CAP_URL),
      updatedAt: truncate(pr.updatedAt, FIELD_CAP_TAG),
      isDraft: pr.isDraft === true,
      ciState: ciRollupToState(rollup),
      reviewDecision: truncate(isString(pr.reviewDecision) ? pr.reviewDecision : "", FIELD_CAP_TAG),
      isExternal: isExternalOwner(prOwner, login),
      owner: prOwner,
      lastCommenter: prComment.commenter,
      lastCommentAt: prComment.commentAt
    })
  }
  return openPRs
}

function mapReviewRequests(login, nodes) {
  var arr = isArray(nodes) ? nodes : []
  var reviewRequests = []
  for (var j = 0; j < arr.length && reviewRequests.length < CAP_REVIEW_REQUESTS; j++) {
    var rr = arr[j]
    if (!isObject(rr)) continue
    var rrRepo = isObject(rr.repository) ? truncate(rr.repository.nameWithOwner, FIELD_CAP_TAG) : ""
    var rrOwner = ownerFromNameWithOwner(rrRepo)
    var rrComment = lastComment(rr.comments)
    reviewRequests.push({
      title: truncate(rr.title, FIELD_CAP_TEXT),
      repo: rrRepo,
      number: safeNum(rr.number, 0),
      webUrl: truncate(rr.url, FIELD_CAP_URL),
      updatedAt: truncate(rr.updatedAt, FIELD_CAP_TAG),
      isExternal: isExternalOwner(rrOwner, login),
      owner: rrOwner,
      lastCommenter: rrComment.commenter,
      lastCommentAt: rrComment.commentAt
    })
  }
  return reviewRequests
}

// exchange/19-feedback-delta-spec.md F3: issues the viewer opened, any repo,
// open state -- same shape/cap/truncation discipline as mapReviewRequests,
// plus the F6 isExternal/owner marking every other row type gets.
//
// exchange/26-feedback2-delta-spec.md G2/G4: also gains lastCommenter/
// lastCommentAt (see lastComment() above) and `subscribed` (see
// subscribedFromViewerSubscription() above) -- the field the G4 Focus/All
// toggle filters on (filterIssues()).
function mapMyIssues(login, nodes) {
  var arr = isArray(nodes) ? nodes : []
  var myIssues = []
  for (var m = 0; m < arr.length && myIssues.length < CAP_MY_ISSUES; m++) {
    var issue = arr[m]
    if (!isObject(issue)) continue
    var issueRepo = isObject(issue.repository) ? truncate(issue.repository.nameWithOwner, FIELD_CAP_TAG) : ""
    var issueOwner = ownerFromNameWithOwner(issueRepo)
    var issueComment = lastComment(issue.comments)
    myIssues.push({
      title: truncate(issue.title, FIELD_CAP_TEXT),
      repo: issueRepo,
      number: safeNum(issue.number, 0),
      webUrl: truncate(issue.url, FIELD_CAP_URL),
      updatedAt: truncate(issue.updatedAt, FIELD_CAP_TAG),
      isExternal: isExternalOwner(issueOwner, login),
      owner: issueOwner,
      lastCommenter: issueComment.commenter,
      lastCommentAt: issueComment.commentAt,
      subscribed: subscribedFromViewerSubscription(issue.viewerSubscription)
    })
  }
  return myIssues
}

function mapRepos(login, nodes) {
  var arr = isArray(nodes) ? nodes : []
  var repos = []
  for (var k = 0; k < arr.length && repos.length < CAP_REPOS; k++) {
    var r = arr[k]
    if (!isObject(r)) continue
    var release = isObject(r.latestRelease) ? r.latestRelease : null
    var branchTarget = isObject(r.defaultBranchRef) && isObject(r.defaultBranchRef.target) ? r.defaultBranchRef.target : null
    var name = truncate(r.name, FIELD_CAP_TAG)
    repos.push({
      name: name,
      url: truncate(repoWebUrl(login, name), FIELD_CAP_URL),
      pushedAt: truncate(r.pushedAt, FIELD_CAP_TAG),
      openIssues: isObject(r.openIssues) ? safeNum(r.openIssues.totalCount, 0) : 0,
      openPRs: isObject(r.openPRCount) ? safeNum(r.openPRCount.totalCount, 0) : 0,
      releaseTag: release ? truncate(release.tagName, FIELD_CAP_TAG) : "",
      releaseUrl: release ? truncate(release.url, FIELD_CAP_URL) : "",
      lastCommitHeadline: branchTarget ? truncate(branchTarget.messageHeadline, FIELD_CAP_TEXT) : "",
      // F1/F2 (exchange/19-feedback-delta-spec.md): stars is a bare int, no
      // string cap needed (it can never grow the panel's memory/render cost
      // the way a string field could -- it renders as at most a handful of
      // digits regardless of magnitude); isArchived/isFork/isPrivate are
      // already fetched by the query (unused, until now) and only ever
      // GraphQL-typed booleans, so a strict `=== true` check is enough
      // defense against a malformed/partial node.
      stars: safeNum(r.stargazerCount, 0),
      isArchived: r.isArchived === true,
      isFork: r.isFork === true,
      isPrivate: r.isPrivate === true
    })
  }
  return repos
}

// F2: one status pill per repo row, priority archived > fork > private (an
// archived fork of a private-visibility... well, archived still wins if
// several happen to be true at once -- "Public archive" is the state GitHub
// itself foregrounds first on a repo's own page). "" means no pill.
function repoPill(repo) {
  if (!isObject(repo)) return ""
  if (repo.isArchived === true) return "archived"
  if (repo.isFork === true) return "fork"
  if (repo.isPrivate === true) return "private"
  return ""
}

// F1: client-side sort over the already-fetched repos window (first: 20 in
// the query -- fine at this scale, see docs/developers.md). Returns a NEW
// array (never mutates the input) so a caller holding the previous array as
// "last-good" data is unaffected. Unrecognized/missing mode falls back to
// "activity" (pushedAt desc) -- the default and the query's own natural
// order. "stars" mode ties-break on pushedAt desc too, so two zero-star (or
// equal-star) repos still land in a stable, sensible order rather than
// whatever order Array.sort's comparator happens to leave them in.
function sortRepos(repos, mode) {
  var arr = isArray(repos) ? repos.slice() : []
  var m = mode === "stars" ? "stars" : "activity"
  function pushedAtMs(r) {
    var t = isObject(r) ? Date.parse(safeStr(r.pushedAt, "")) : NaN
    return isNaN(t) ? 0 : t
  }
  if (m === "stars") {
    arr.sort(function (a, b) {
      var diff = safeNum(b && b.stars, 0) - safeNum(a && a.stars, 0)
      return diff !== 0 ? diff : pushedAtMs(b) - pushedAtMs(a)
    })
  } else {
    arr.sort(function (a, b) { return pushedAtMs(b) - pushedAtMs(a) })
  }
  return arr
}

// ------------------------------------------------------- search + filter (G1/G4)

// exchange/26-feedback2-delta-spec.md G1: case-insensitive substring match
// used by the panel-side search field to live-filter every section's already
// -rendered rows -- pure and generic over whichever of `title`/`repo`/
// `owner`/`name` a given item shape actually carries (PR/review-request/
// issue rows have title+repo+owner; repo-activity rows have name only; a
// field the item doesn't have is simply skipped, never a thrown error).
// Empty/whitespace-only query matches everything (the "no filter active"
// state). `query` is capped to QUERY_CAP *characters* (not bytes) before
// comparison -- generous for any real typed input, but keeps a pathological
// huge query string from turning every row's substring scan into needless
// work; slicing a JS string mid-surrogate-pair is a real edge case for exotic
// unicode (emoji, some CJK extension characters) but a mid-cap slice search
// still resolves to a defensible substring match, never a throw.
function matchesQuery(item, query) {
  var q = isString(query) ? query.slice(0, QUERY_CAP).trim().toLowerCase() : ""
  if (!q) return true
  if (!isObject(item)) return false
  var fields = [item.title, item.repo, item.owner, item.name]
  for (var i = 0; i < fields.length; i++) {
    var f = fields[i]
    if (isString(f) && f.toLowerCase().indexOf(q) >= 0) return true
  }
  return false
}

// exchange/26-feedback2-delta-spec.md G4: "focus" (default) keeps only
// myIssues rows the viewer is still subscribed to (`subscribed !== false` --
// deliberately not `=== true`, so a hand-built/older item missing the field
// entirely fails open the same way mapMyIssues's own
// subscribedFromViewerSubscription() does, rather than being silently
// dropped by a stricter equality check); "all" is a pass-through copy.
// Any mode other than exactly "all" (including missing/garbage) is treated
// as "focus" -- same permissive-default-on-garbage-input shape as
// sortRepos()'s own mode handling above. Always returns a NEW array, never
// mutates `issues`.
function filterIssues(issues, mode) {
  var arr = isArray(issues) ? issues : []
  if (mode === "all") return arr.slice()
  return arr.filter(function (i) { return isObject(i) && i.subscribed !== false })
}

// Raw shape: the parsed body of the mega GraphQL query
// (exchange/04-github-data.md #6 / exchange/samples/mega-graphql.json):
// { data: { viewer: { openPRs: {nodes:[...]}, repositories: {nodes:[...]},
//           myIssues: {nodes:[...]} }, reviewRequests: { nodes: [...] } } }
//
// Per-section contract (exchange/12-s5b-correctness-review.md F4): GraphQL
// allows a response to carry `data` for the fields that resolved AND
// `errors` for the ones that didn't in the SAME envelope (GitHub's `search`
// -- used for reviewRequests -- has its own stricter rate-limit bucket
// separate from the object-graph API, so it's realistic for reviewRequests
// to error out while openPRs/repositories/myIssues succeed in the same
// call). Each of the four returned sections is either a mapped array (the
// source field was present as an object in `data`, however many/few nodes
// it had -- an empty array is a legitimate "genuinely nothing here", not
// "unusable") or `null`, which is the explicit "this section did not
// resolve -- caller must NOT replace its last-good value" signal
// (exchange/19-feedback-delta-spec.md extends this same contract to the new
// myIssues section). A whole-envelope failure (non-object `json`,
// missing/non-object `json.data`) returns all four as null, which is the
// correct "nothing usable" case the caller treats as a full fetch failure.
//
// `login` (exchange/23-s11-delta-review.md F2): also returned, always a
// string ("" when unresolvable) -- never null, unlike the four section
// keys, since it isn't subject to the same partial-envelope replace
// contract. This lets Service.qml opportunistically learn internal.login
// from an ordinary dashboard response's own viewer.login field when the
// auth probe itself never got the chance to (its first attempt failed
// non-auth, or timed out into the watchdog) -- see handleDashboardExit.
function mapDashboard(json) {
  var result = { openPRs: null, reviewRequests: null, repos: null, myIssues: null, login: "" }
  if (!isObject(json)) return result
  var data = isObject(json.data) ? json.data : null
  if (!data) return result

  var viewer = isObject(data.viewer) ? data.viewer : null
  var login = viewer ? safeStr(viewer.login, "") : ""
  result.login = login
  if (viewer && isObject(viewer.openPRs)) {
    result.openPRs = mapOpenPRs(login, viewer.openPRs.nodes)
  }
  if (viewer && isObject(viewer.repositories)) {
    result.repos = mapRepos(login, viewer.repositories.nodes)
  }
  if (viewer && isObject(viewer.myIssues)) {
    result.myIssues = mapMyIssues(login, viewer.myIssues.nodes)
  }
  if (isObject(data.reviewRequests)) {
    result.reviewRequests = mapReviewRequests(login, data.reviewRequests.nodes)
  }
  return result
}

// `viewer.repositories.nodes[].name` in the mega query is a bare repo name
// (no owner), so repo.url needs `viewer.login` joined in -- both are
// present in the same top-level query response, which is why mapDashboard
// can build a correct web URL itself rather than pushing "owner/name"
// string-building duty onto Service.qml. Exposed as a small named helper
// (not inlined) so it has its own test coverage.
function repoWebUrl(login, repoName) {
  if (!isString(login) || !login || !isString(repoName) || !repoName) return ""
  return "https://github.com/" + login + "/" + repoName
}

// ------------------------------------------------------------- relative time

// iso: an ISO-8601 timestamp string. nowMs: caller-supplied "now" in epoch
// ms (never Date.now() inside the mapper -- keeps this testable/deterministic).
function relativeTime(iso, nowMs) {
  if (!isString(iso) || !iso) return ""
  var then = Date.parse(iso)
  if (isNaN(then)) return ""
  var now = safeNum(nowMs, then)
  var diffSec = Math.floor((now - then) / 1000)
  if (diffSec < 60) return "just now"
  var diffMin = Math.floor(diffSec / 60)
  if (diffMin < 60) return diffMin + "m"
  var diffHour = Math.floor(diffMin / 60)
  if (diffHour < 24) return diffHour + "h"
  var diffDay = Math.floor(diffHour / 24)
  if (diffDay < 7) return diffDay + "d"
  var diffWeek = Math.floor(diffDay / 7)
  if (diffWeek < 5) return diffWeek + "w"
  var d = new Date(then)
  var month = MONTH_NAMES[d.getUTCMonth()]
  return month + " " + d.getUTCDate() + ", " + d.getUTCFullYear()
}

// ------------------------------------------------------------------ safety

// Only ever true for a genuine https://github.com/... URL. Deliberately a
// plain prefix check (anchored regex), not a hostname parse, so it has no
// dependency on a URL-parsing global that may not exist in the QML JS
// engine. "https://github.com.evil.com/..." fails because the character
// right after the literal "github.com" must be "/", never ".". The
// userinfo trick ("https://github.com@evil.com/...") is also already
// rejected by this same prefix requirement: the character immediately
// after "github.com" there is "@", not "/", so it never matches either --
// asserted with an explicit test in test/model.test.js per
// exchange/11-s5a-security-review.md F1.
var SAFE_GITHUB_URL_RE = /^https:\/\/github\.com\//

// Hardened per exchange/11-s5a-security-review.md F1: the plain prefix
// check above has no `$` anchor and no character-class restriction on what
// follows the required prefix, so a string like
// "https://github.com/\n../evil" (a literal newline right after the
// prefix) used to pass. This is the last allowlist gate before
// Quickshell.execDetached(["xdg-open", url]) in Service.qml, so it now also
// rejects any control character or whitespace anywhere in the string, and
// caps overall length -- defense-in-depth on top of execDetached's own
// array-form (no shell reparse) call shape.
var CONTROL_OR_WHITESPACE_RE = /[\x00-\x20\x7f]/

function isSafeGithubUrl(url) {
  if (!isString(url)) return false
  if (url.length === 0 || url.length > FIELD_CAP_URL) return false
  if (!SAFE_GITHUB_URL_RE.test(url)) return false
  if (CONTROL_OR_WHITESPACE_RE.test(url)) return false
  return true
}

// ------------------------------------------------------------- failure shapes

// Classifies a failed `gh` invocation using the exact observed shapes from
// exchange/04-github-data.md #7. Order matters: check the most specific
// signal first so e.g. a 401 body that also happens to mention "timeout"
// text somewhere doesn't get misclassified.
function classifyFailure(stderrText, exitCode) {
  var text = safeStr(stderrText, "")

  if (exitCode === 127 || /no such file or directory/i.test(text) || /command not found/i.test(text)) {
    return "no-gh"
  }
  if (/HTTP 304/i.test(text)) {
    return "http-304"
  }
  if (/HTTP 401/i.test(text) || /bad credentials/i.test(text)) {
    return "unauthenticated"
  }
  if (/API rate limit exceeded/i.test(text) || (/HTTP 403/i.test(text) && /rate.?limit/i.test(text))) {
    return "rate-limited"
  }
  var hasHttpStatus = /HTTP\s+\d{3}/i.test(text)
  if (!hasHttpStatus && (/dial tcp/i.test(text) || /connection refused/i.test(text) || /no such host/i.test(text) || /timeout/i.test(text))) {
    return "offline"
  }
  return "error"
}

// ------------------------------------------------------ headers + body parse

// Parses the combined output of `gh api -i ...`: an HTTP status line, a
// block of "Header: value" lines (observed CRLF-terminated; the status line
// itself is LF-terminated -- normalize both), a blank line, then the body
// (absent entirely on a 304). Never throws: a body that fails JSON.parse
// (or is empty) yields `body: null`.
function parseHeadersAndBody(rawStdout) {
  var result = { status: 0, etag: "", body: null }
  var raw = safeStr(rawStdout, "")
  if (!raw) return result

  var normalized = raw.replace(/\r\n/g, "\n")
  var sepIndex = normalized.indexOf("\n\n")
  var headerBlock = sepIndex >= 0 ? normalized.slice(0, sepIndex) : normalized
  var bodyText = sepIndex >= 0 ? normalized.slice(sepIndex + 2) : ""

  var lines = headerBlock.split("\n")
  if (lines.length > 0) {
    var statusMatch = /^HTTP\/\S+\s+(\d{3})/.exec(lines[0])
    if (statusMatch) result.status = parseInt(statusMatch[1], 10)
  }
  for (var i = 1; i < lines.length; i++) {
    var line = lines[i]
    var colonIdx = line.indexOf(":")
    if (colonIdx < 0) continue
    var name = line.slice(0, colonIdx).trim().toLowerCase()
    var value = line.slice(colonIdx + 1).trim()
    if (name === "etag") result.etag = value
  }

  var trimmedBody = bodyText.replace(/\s+$/, "")
  if (trimmedBody) {
    try {
      result.body = JSON.parse(trimmedBody)
    } catch (e) {
      result.body = null
    }
  }
  return result
}

// ---------------------------------------------------------------- bar text

function badgeText(count) {
  var n = safeNum(count, 0)
  if (n <= 0) return "0"
  if (n > 99) return "99+"
  return String(n)
}

// state: { unreadCount, openPRCount, reviewRequestCount, ciFailingCount }
// -- every field optional/defensive. Composes the short bar tooltip, e.g.
// "3 unread · 1 PR · CI failing".
function summaryTooltip(state) {
  var s = isObject(state) ? state : {}
  var parts = []

  var unread = safeNum(s.unreadCount, 0)
  if (unread > 0) parts.push(unread + " unread")

  var prCount = safeNum(s.openPRCount, 0)
  if (prCount > 0) parts.push(prCount + " PR" + (prCount === 1 ? "" : "s"))

  var reviewCount = safeNum(s.reviewRequestCount, 0)
  if (reviewCount > 0) parts.push(reviewCount + " review request" + (reviewCount === 1 ? "" : "s"))

  var ciFailing = safeNum(s.ciFailingCount, s.ciFailing === true ? 1 : 0)
  if (ciFailing > 0) parts.push("CI failing")

  if (parts.length === 0) return "All caught up"
  return parts.join(" · ")
}

// ------------------------------------------------------------- settings persistence

// `shell.updateEntryInline(moduleName, settings)` (the first-party host
// helper, /usr/share/omarchy/shell/shell.qml) REPLACES the whole plugin
// settings entry with `{id}` plus exactly the keys `settings` hands it --
// it does not merge onto whatever is already stored. A caller that passes
// only the one key it wants to change silently drops every other setting
// the entry held (the precedent this mirrors:
// ~/.config/omarchy/plugins/halmylyseas.ristretto/Model.js's
// `mergedSettings`, same trap, same fix). Always build the full next-state
// object from `current` (the plugin's existing settings entry, or any
// falsy value for "no entry yet") first, so a single-setting write like
// `setRepoSort` can never clobber `dashboardIntervalSec`/`repoLimit`/etc.
// The `id` key is stripped from `current` even if present -- the host adds
// it back itself, keyed off the moduleName argument, not off anything in
// this object.
function mergedSettings(current, key, value) {
  var next = {}
  if (isObject(current)) {
    for (var k in current) {
      if (k !== "id") next[k] = current[k]
    }
  }
  next[key] = value
  return next
}

// ------------------------------------------------------------- module export

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    apiUrlToWebUrl: apiUrlToWebUrl,
    mapNotifications: mapNotifications,
    remapNotificationsExternal: remapNotificationsExternal,
    mapDashboard: mapDashboard,
    ciRollupToState: ciRollupToState,
    relativeTime: relativeTime,
    isSafeGithubUrl: isSafeGithubUrl,
    classifyFailure: classifyFailure,
    parseHeadersAndBody: parseHeadersAndBody,
    badgeText: badgeText,
    summaryTooltip: summaryTooltip,
    repoWebUrl: repoWebUrl,
    truncate: truncate,
    repoPill: repoPill,
    sortRepos: sortRepos,
    ownerFromNameWithOwner: ownerFromNameWithOwner,
    isExternalOwner: isExternalOwner,
    mergedSettings: mergedSettings,
    lastComment: lastComment,
    subscribedFromViewerSubscription: subscribedFromViewerSubscription,
    matchesQuery: matchesQuery,
    filterIssues: filterIssues,
    FIELD_CAP_TEXT: FIELD_CAP_TEXT,
    FIELD_CAP_TAG: FIELD_CAP_TAG,
    FIELD_CAP_URL: FIELD_CAP_URL,
    FIELD_CAP_COMMENTER: FIELD_CAP_COMMENTER,
    QUERY_CAP: QUERY_CAP
  }
}
