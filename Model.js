// Model.js -- pure data-mapping library for halmylyseas.github-status.
// No Quickshell/QML dependency, so plain Node can require() it directly
// (see docs/developers.md, "Architecture"); every list output is capped.

var CAP_NOTIFICATIONS = 50
var CAP_PRS = 20
var CAP_REVIEW_REQUESTS = 20
var CAP_REPOS = 30
var CAP_MY_ISSUES = 20  // same cap shape as reviewRequests

// Per-field length caps, independent of the list-length caps above: bounds
// a single field's cost even though real GitHub data never approaches these
// (defense-in-depth against a future API/host change, not an observed issue).
var FIELD_CAP_TEXT = 300    // titles / commit headlines
var FIELD_CAP_TAG = 100     // reasons / repo identifiers / release tags / timestamps
var FIELD_CAP_URL = 2048    // urls
// lastCommenter is already GitHub-login-length-capped well under this; the
// query cap bounds matchesQuery's per-item scan cost against a huge paste.
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

// ------------------------------------------------------------- own vs external

// "owner/repo" (GraphQL nameWithOwner, or REST full_name -- same shape) ->
// just the owner segment. "" on anything that doesn't contain a "/" with
// content before it (missing/malformed repo identifier).
function ownerFromNameWithOwner(nameWithOwner) {
  var s = safeStr(nameWithOwner, "")
  var idx = s.indexOf("/")
  return idx > 0 ? s.slice(0, idx) : ""
}

// A row is "external" when its repo's owner differs from the viewer's own
// login, compared case-insensitively (GitHub logins are case-insensitive).
// An unknown owner or login is never flagged external (fail-safe default).
function isExternalOwner(owner, login) {
  var o = safeStr(owner, "")
  var l = safeStr(login, "")
  if (!o || !l) return false
  return o.toLowerCase() !== l.toLowerCase()
}

// ----------------------------------------------------- URL translation

// api.github.com REST subject -> a github.com web URL, string-rewrite only,
// never an extra network call. owner/repo/id are all charset-validated
// (no slash/control chars) before the URL is built; "" on no match.
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
// repository: {full_name, html_url}, updated_at }. `login`, when passed,
// marks external rows; omitted, every row reads as non-external instead.
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

// Re-derives isExternal for an already-mapped notifications array without
// re-fetching -- used once, when login becomes known after notifications
// were already fetched with it unknown. Manual field copy keeps this ES5.
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

// -------------------------------------------------------- last comment

// `comments(last: 1)` -> { commenter, commentAt }, both "" when there is no
// comment, or its author is a since-deleted account (a real GraphQL shape,
// not malformed). Returned as one pair since a login-less age is misleading.
function lastComment(commentsConn) {
  var empty = { commenter: "", commentAt: "" }
  if (!isObject(commentsConn) || !isArray(commentsConn.nodes) || commentsConn.nodes.length === 0) return empty
  var node = commentsConn.nodes[commentsConn.nodes.length - 1]
  if (!isObject(node)) return empty
  var author = isObject(node.author) ? node.author : null
  var login = author ? safeStr(author.login, "") : ""
  if (!login) return empty
  var commentAt = truncate(node.updatedAt, FIELD_CAP_TAG)
  // A missing/null updatedAt degrades to "" -- collapse commenter alongside
  // it too, so the pairing this function returns stays symmetric in code.
  if (!commentAt) return empty
  return {
    commenter: truncate(login, FIELD_CAP_COMMENTER),
    commentAt: commentAt
  }
}

// ---------------------------------------------------------- subscribed

// GraphQL's viewerSubscription enum: "SUBSCRIBED" | "UNSUBSCRIBED" | "IGNORED".
// Fails OPEN (true) on a missing/null field -- a schema hiccup must never
// silently hide the user's own issues; anything else means "not subscribed".
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

// Issues the viewer opened, any repo, open state -- same shape/cap
// discipline as mapReviewRequests, plus lastCommenter/lastCommentAt and
// `subscribed` (the field the Focus/All toggle filters on, filterIssues()).
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
      // stars is a bare int, no string cap needed; isArchived/isFork/
      // isPrivate are always GraphQL-typed booleans, so a strict `=== true`
      // check is enough to guard a malformed node.
      stars: safeNum(r.stargazerCount, 0),
      isArchived: r.isArchived === true,
      isFork: r.isFork === true,
      isPrivate: r.isPrivate === true
    })
  }
  return repos
}

// One status pill per repo row, priority archived > fork > private -- the
// same state GitHub itself foregrounds first on a repo's own page. "" = none.
function repoPill(repo) {
  if (!isObject(repo)) return ""
  if (repo.isArchived === true) return "archived"
  if (repo.isFork === true) return "fork"
  if (repo.isPrivate === true) return "private"
  return ""
}

// Repos render in fetch order (GraphQL PUSHED_AT desc), sliced by repoLimit
// in Service.qml -- no client-side sort layer. `stars` is unused by the UI
// but kept in the mapped shape; harmless to leave rather than thread out.

// ------------------------------------------------------- search + filter

// Case-insensitive substring match over whichever of title/repo/owner/name
// a given item shape actually has; empty/whitespace query matches
// everything. `query` is capped at QUERY_CAP chars before comparing.
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

// "focus" (default) keeps myIssues rows still subscribed (`subscribed !==
// false`, so a legacy item missing the field fails open); "all" is a
// pass-through copy. Any other mode is treated as "focus". Never mutates.
function filterIssues(issues, mode) {
  var arr = isArray(issues) ? issues : []
  if (mode === "all") return arr.slice()
  return arr.filter(function (i) { return isObject(i) && i.subscribed !== false })
}

// Each of the four sections below is a mapped array (nodes present, however
// many) or null -- the field didn't resolve, caller must not replace
// last-good data. `login` and each *Total field ride alongside, per-section.
function mapDashboard(json) {
  var result = {
    openPRs: null, reviewRequests: null, repos: null, myIssues: null, login: "",
    openPRsTotal: null, reviewRequestsTotal: null, reposTotal: null, myIssuesTotal: null
  }
  if (!isObject(json)) return result
  var data = isObject(json.data) ? json.data : null
  if (!data) return result

  var viewer = isObject(data.viewer) ? data.viewer : null
  var login = viewer ? safeStr(viewer.login, "") : ""
  result.login = login
  if (viewer && isObject(viewer.openPRs)) {
    result.openPRs = mapOpenPRs(login, viewer.openPRs.nodes)
    result.openPRsTotal = safeNum(viewer.openPRs.totalCount, 0)
  }
  if (viewer && isObject(viewer.repositories)) {
    result.repos = mapRepos(login, viewer.repositories.nodes)
    result.reposTotal = safeNum(viewer.repositories.totalCount, 0)
  }
  if (viewer && isObject(viewer.myIssues)) {
    result.myIssues = mapMyIssues(login, viewer.myIssues.nodes)
    result.myIssuesTotal = safeNum(viewer.myIssues.totalCount, 0)
  }
  if (isObject(data.reviewRequests)) {
    result.reviewRequests = mapReviewRequests(login, data.reviewRequests.nodes)
    result.reviewRequestsTotal = safeNum(data.reviewRequests.issueCount, 0)
  }
  return result
}

// `repositories.nodes[].name` in the query is a bare repo name (no owner),
// so this joins in `viewer.login` (present in the same response) to build
// a correct web URL. A named helper, not inlined, so it has its own test.
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

// True only for a genuine https://github.com/... URL: a plain anchored
// prefix check (no URL-parsing global needed) where the char right after
// "github.com" must be "/", so neither a lookalike domain nor userinfo matches.
var SAFE_GITHUB_URL_RE = /^https:\/\/github\.com\//

// The prefix check alone has no length/charset limit on what follows, so a
// literal newline right after it used to pass -- this also rejects any
// control character or whitespace, and the caller caps overall length.
var CONTROL_OR_WHITESPACE_RE = /[\x00-\x20\x7f]/

function isSafeGithubUrl(url) {
  if (!isString(url)) return false
  if (url.length === 0 || url.length > FIELD_CAP_URL) return false
  if (!SAFE_GITHUB_URL_RE.test(url)) return false
  if (CONTROL_OR_WHITESPACE_RE.test(url)) return false
  return true
}

// ------------------------------------------------------------- failure shapes

// Classifies a failed `gh` invocation by its observed stderr/exit shape.
// Order matters: the most specific signal is checked first, so a 401 body
// that also happens to mention "timeout" doesn't get misclassified.
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

// ------------------------------------------------------------------ gh version pin

// Major versions of the gh CLI this plugin has actually been tested
// against. `gh --version`'s first line reads "gh version X.Y.Z (date)".
var SUPPORTED_GH_MAJORS = [2]

// Parses that first line down to just "X.Y.Z"; "" on anything else.
function parseGhVersion(raw) {
  var s = safeStr(raw, "").slice(0, 256)
  var match = s.match(/gh version\s+(\S+)/i)
  return match ? truncate(match[1], FIELD_CAP_TAG) : ""
}

// True when the parsed version's leading major segment is a pinned one.
// An unpinned major, or an unparsed "", reads as untested rather than
// throwing -- gh's own text format changing is not this plugin's crash.
function isGhVersionSupported(version) {
  var match = String(version || "").match(/^(\d+)\./)
  return match !== null && SUPPORTED_GH_MAJORS.indexOf(parseInt(match[1], 10)) !== -1
}

// ------------------------------------------------------------- gh argv/etag

// Verbatim GraphQL query text sent as `-f query=<this>` to a direct `gh`
// child. Kept as an array of lines, joined, so a diff shows exactly which
// line of the query changed.
var DASHBOARD_QUERY = [
  "query {",
  "  viewer {",
  "    login",
  "    openPRs: pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {",
  "      totalCount",
  "      nodes {",
  "        title url number updatedAt isDraft reviewDecision",
  "        repository { nameWithOwner }",
  "        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }",
  "        comments(last: 1) { nodes { author { login } updatedAt } }",
  "      }",
  "    }",
  "    myIssues: issues(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {",
  "      totalCount",
  "      nodes {",
  "        title url number updatedAt viewerSubscription",
  "        repository { nameWithOwner }",
  "        comments(last: 1) { nodes { author { login } updatedAt } }",
  "      }",
  "    }",
  "    repositories(first: 30, ownerAffiliations: OWNER, orderBy: {field: PUSHED_AT, direction: DESC}) {",
  "      totalCount",
  "      nodes {",
  "        name pushedAt isPrivate isArchived isFork stargazerCount",
  "        openIssues: issues(states: OPEN) { totalCount }",
  "        openPRCount: pullRequests(states: OPEN) { totalCount }",
  "        latestRelease { tagName name publishedAt url }",
  "        defaultBranchRef {",
  "          target {",
  "            ... on Commit { oid messageHeadline committedDate statusCheckRollup { state } }",
  "          }",
  "        }",
  "      }",
  "    }",
  "  }",
  "  reviewRequests: search(query: \"is:open is:pr review-requested:@me\", type: ISSUE, first: 10) {",
  "    issueCount",
  "    nodes {",
  "      ... on PullRequest {",
  "        title url number updatedAt",
  "        repository { nameWithOwner }",
  "        comments(last: 1) { nodes { author { login } updatedAt } }",
  "      }",
  "    }",
  "  }",
  "}"
].join("\n")

// Only printable ASCII survives, capped at 128 chars -- an ETag becomes
// its own argv element (`-H "If-None-Match: " + etag`), so it's sanitised
// before that, not just length-capped.
var ETAG_SAFE_RE = /[!-~]/
function sanitizeEtag(etag) {
  var s = safeStr(etag, "")
  var out = ""
  for (var i = 0; i < s.length && out.length < 128; i++) {
    if (ETAG_SAFE_RE.test(s.charAt(i))) out += s.charAt(i)
  }
  return out
}

// An exit-0 notifications response is only trusted with a 200 status and
// an array body -- anything else is a failure that keeps last-good data,
// never silently mapped to an empty list.
function isNotificationsBodyValid(parsed) {
  return isObject(parsed) && parsed.status === 200 && isArray(parsed.body)
}

// ------------------------------------------------------ headers + body parse

// Parses `gh api -i ...`'s combined output: status line, "Header: value"
// lines (CRLF; the status line itself is LF -- normalize both), a blank
// line, then the body. Never throws: an unparseable/empty body -> null.
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

// shell.updateEntryInline REPLACES the whole settings entry with exactly
// the keys handed to it -- it does not merge. Build the full next-state
// object from `current` first so one changed key never drops the rest.
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
    ownerFromNameWithOwner: ownerFromNameWithOwner,
    isExternalOwner: isExternalOwner,
    mergedSettings: mergedSettings,
    lastComment: lastComment,
    subscribedFromViewerSubscription: subscribedFromViewerSubscription,
    matchesQuery: matchesQuery,
    filterIssues: filterIssues,
    DASHBOARD_QUERY: DASHBOARD_QUERY,
    sanitizeEtag: sanitizeEtag,
    isNotificationsBodyValid: isNotificationsBodyValid,
    FIELD_CAP_TEXT: FIELD_CAP_TEXT,
    FIELD_CAP_TAG: FIELD_CAP_TAG,
    FIELD_CAP_URL: FIELD_CAP_URL,
    FIELD_CAP_COMMENTER: FIELD_CAP_COMMENTER,
    QUERY_CAP: QUERY_CAP,
    SUPPORTED_GH_MAJORS: SUPPORTED_GH_MAJORS,
    parseGhVersion: parseGhVersion,
    isGhVersionSupported: isGhVersionSupported
  }
}
