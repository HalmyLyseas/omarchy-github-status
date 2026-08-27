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

// ----------------------------------------------------- URL translation

// api.github.com REST subject -> a github.com web URL, string-rewrite only
// (never an extra network call -- see exchange/04-github-data.md #2).
// `subject` is the {type, url} shape the notifications API and our own
// mapped list items use. Returns "" when the subject type/url doesn't match
// a known pattern -- the caller is expected to fall back to the containing
// repository's html_url in that case.
var API_URL_RE = /^https:\/\/api\.github\.com\/repos\/([^\/]+)\/([^\/]+)\/(issues|pulls|releases|discussions|commits)\/(.+)$/
var SEGMENT_TO_WEB = {
  issues: "issues",
  pulls: "pull",       // the one real gotcha: plural API segment, singular web segment
  releases: "releases",
  discussions: "discussions",
  commits: "commit"    // also irregular: plural API segment, singular web segment
}

function apiUrlToWebUrl(subject) {
  if (!isObject(subject)) return ""
  var url = subject.url
  if (!isString(url)) return ""
  var m = API_URL_RE.exec(url)
  if (!m) return ""
  var owner = m[1]
  var repo = m[2]
  var apiSegment = m[3]
  var rest = m[4]
  var webSegment = SEGMENT_TO_WEB[apiSegment]
  if (!webSegment || !rest) return ""
  return "https://github.com/" + owner + "/" + repo + "/" + webSegment + "/" + rest
}

// ----------------------------------------------------------- notifications

// Raw shape: array of { id, unread, reason, subject: {title, url, type},
// repository: {full_name, html_url}, updated_at }. See
// exchange/samples/notifications.json.
function mapNotifications(json) {
  if (!isArray(json)) return []
  var out = []
  for (var i = 0; i < json.length && out.length < CAP_NOTIFICATIONS; i++) {
    var n = json[i]
    if (!isObject(n)) continue
    var subject = isObject(n.subject) ? n.subject : {}
    var repository = isObject(n.repository) ? n.repository : {}
    var repo = safeStr(repository.full_name, "")
    var webUrl = apiUrlToWebUrl(subject)
    if (!webUrl) webUrl = safeStr(repository.html_url, "")
    out.push({
      id: safeStr(n.id, String(i)),
      unread: n.unread === true,
      reason: safeStr(n.reason, ""),
      title: safeStr(subject.title, ""),
      repo: repo,
      webUrl: webUrl,
      updatedAt: safeStr(n.updated_at, "")
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

// ------------------------------------------------------------------ dashboard

// Raw shape: the parsed body of the mega GraphQL query
// (exchange/04-github-data.md #6 / exchange/samples/mega-graphql.json):
// { data: { viewer: { openPRs: {nodes:[...]}, repositories: {nodes:[...]} },
//           reviewRequests: { nodes: [...] } } }
function mapDashboard(json) {
  var empty = { openPRs: [], reviewRequests: [], repos: [] }
  if (!isObject(json)) return empty
  var data = isObject(json.data) ? json.data : {}
  var viewer = isObject(data.viewer) ? data.viewer : {}

  var prNodes = isObject(viewer.openPRs) && isArray(viewer.openPRs.nodes) ? viewer.openPRs.nodes : []
  var openPRs = []
  for (var i = 0; i < prNodes.length && openPRs.length < CAP_PRS; i++) {
    var pr = prNodes[i]
    if (!isObject(pr)) continue
    var prRepo = isObject(pr.repository) ? safeStr(pr.repository.nameWithOwner, "") : ""
    var rollup = null
    if (isObject(pr.commits) && isArray(pr.commits.nodes) && pr.commits.nodes.length > 0) {
      var lastCommitNode = pr.commits.nodes[pr.commits.nodes.length - 1]
      if (isObject(lastCommitNode) && isObject(lastCommitNode.commit)) {
        rollup = lastCommitNode.commit.statusCheckRollup
      }
    }
    openPRs.push({
      title: safeStr(pr.title, ""),
      repo: prRepo,
      number: safeNum(pr.number, 0),
      webUrl: safeStr(pr.url, ""),
      updatedAt: safeStr(pr.updatedAt, ""),
      isDraft: pr.isDraft === true,
      ciState: ciRollupToState(rollup),
      reviewDecision: isString(pr.reviewDecision) ? pr.reviewDecision : ""
    })
  }

  var reviewNodes = isObject(data.reviewRequests) && isArray(data.reviewRequests.nodes) ? data.reviewRequests.nodes : []
  var reviewRequests = []
  for (var j = 0; j < reviewNodes.length && reviewRequests.length < CAP_REVIEW_REQUESTS; j++) {
    var rr = reviewNodes[j]
    if (!isObject(rr)) continue
    var rrRepo = isObject(rr.repository) ? safeStr(rr.repository.nameWithOwner, "") : ""
    reviewRequests.push({
      title: safeStr(rr.title, ""),
      repo: rrRepo,
      number: safeNum(rr.number, 0),
      webUrl: safeStr(rr.url, ""),
      updatedAt: safeStr(rr.updatedAt, "")
    })
  }

  var login = safeStr(viewer.login, "")
  var repoNodes = isObject(viewer.repositories) && isArray(viewer.repositories.nodes) ? viewer.repositories.nodes : []
  var repos = []
  for (var k = 0; k < repoNodes.length && repos.length < CAP_REPOS; k++) {
    var r = repoNodes[k]
    if (!isObject(r)) continue
    var release = isObject(r.latestRelease) ? r.latestRelease : null
    var branchTarget = isObject(r.defaultBranchRef) && isObject(r.defaultBranchRef.target) ? r.defaultBranchRef.target : null
    var name = safeStr(r.name, "")
    repos.push({
      name: name,
      url: repoWebUrl(login, name),
      pushedAt: safeStr(r.pushedAt, ""),
      openIssues: isObject(r.openIssues) ? safeNum(r.openIssues.totalCount, 0) : 0,
      openPRs: isObject(r.openPRCount) ? safeNum(r.openPRCount.totalCount, 0) : 0,
      releaseTag: release ? safeStr(release.tagName, "") : "",
      releaseUrl: release ? safeStr(release.url, "") : "",
      lastCommitHeadline: branchTarget ? safeStr(branchTarget.messageHeadline, "") : ""
    })
  }

  return { openPRs: openPRs, reviewRequests: reviewRequests, repos: repos }
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
// right after the literal "github.com" must be "/", never ".".
var SAFE_GITHUB_URL_RE = /^https:\/\/github\.com\//

function isSafeGithubUrl(url) {
  if (!isString(url)) return false
  return SAFE_GITHUB_URL_RE.test(url)
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

// ------------------------------------------------------------- module export

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    apiUrlToWebUrl: apiUrlToWebUrl,
    mapNotifications: mapNotifications,
    mapDashboard: mapDashboard,
    ciRollupToState: ciRollupToState,
    relativeTime: relativeTime,
    isSafeGithubUrl: isSafeGithubUrl,
    classifyFailure: classifyFailure,
    parseHeadersAndBody: parseHeadersAndBody,
    badgeText: badgeText,
    summaryTooltip: summaryTooltip,
    repoWebUrl: repoWebUrl
  }
}
