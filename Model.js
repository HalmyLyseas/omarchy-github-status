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
function mapNotifications(json) {
  if (!isArray(json)) return []
  var out = []
  for (var i = 0; i < json.length && out.length < CAP_NOTIFICATIONS; i++) {
    var n = json[i]
    if (!isObject(n)) continue
    var subject = isObject(n.subject) ? n.subject : {}
    var repository = isObject(n.repository) ? n.repository : {}
    var repo = truncate(repository.full_name, FIELD_CAP_TAG)
    var webUrl = apiUrlToWebUrl(subject)
    if (!webUrl) webUrl = truncate(repository.html_url, FIELD_CAP_URL)
    out.push({
      id: truncate(n.id, FIELD_CAP_TAG, String(i)),
      unread: n.unread === true,
      reason: truncate(n.reason, FIELD_CAP_TAG),
      title: truncate(subject.title, FIELD_CAP_TEXT),
      repo: repo,
      webUrl: truncate(webUrl, FIELD_CAP_URL),
      updatedAt: truncate(n.updated_at, FIELD_CAP_TAG)
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

function mapOpenPRs(nodes) {
  var arr = isArray(nodes) ? nodes : []
  var openPRs = []
  for (var i = 0; i < arr.length && openPRs.length < CAP_PRS; i++) {
    var pr = arr[i]
    if (!isObject(pr)) continue
    var prRepo = isObject(pr.repository) ? truncate(pr.repository.nameWithOwner, FIELD_CAP_TAG) : ""
    var rollup = null
    if (isObject(pr.commits) && isArray(pr.commits.nodes) && pr.commits.nodes.length > 0) {
      var lastCommitNode = pr.commits.nodes[pr.commits.nodes.length - 1]
      if (isObject(lastCommitNode) && isObject(lastCommitNode.commit)) {
        rollup = lastCommitNode.commit.statusCheckRollup
      }
    }
    openPRs.push({
      title: truncate(pr.title, FIELD_CAP_TEXT),
      repo: prRepo,
      number: safeNum(pr.number, 0),
      webUrl: truncate(pr.url, FIELD_CAP_URL),
      updatedAt: truncate(pr.updatedAt, FIELD_CAP_TAG),
      isDraft: pr.isDraft === true,
      ciState: ciRollupToState(rollup),
      reviewDecision: truncate(isString(pr.reviewDecision) ? pr.reviewDecision : "", FIELD_CAP_TAG)
    })
  }
  return openPRs
}

function mapReviewRequests(nodes) {
  var arr = isArray(nodes) ? nodes : []
  var reviewRequests = []
  for (var j = 0; j < arr.length && reviewRequests.length < CAP_REVIEW_REQUESTS; j++) {
    var rr = arr[j]
    if (!isObject(rr)) continue
    var rrRepo = isObject(rr.repository) ? truncate(rr.repository.nameWithOwner, FIELD_CAP_TAG) : ""
    reviewRequests.push({
      title: truncate(rr.title, FIELD_CAP_TEXT),
      repo: rrRepo,
      number: safeNum(rr.number, 0),
      webUrl: truncate(rr.url, FIELD_CAP_URL),
      updatedAt: truncate(rr.updatedAt, FIELD_CAP_TAG)
    })
  }
  return reviewRequests
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
      lastCommitHeadline: branchTarget ? truncate(branchTarget.messageHeadline, FIELD_CAP_TEXT) : ""
    })
  }
  return repos
}

// Raw shape: the parsed body of the mega GraphQL query
// (exchange/04-github-data.md #6 / exchange/samples/mega-graphql.json):
// { data: { viewer: { openPRs: {nodes:[...]}, repositories: {nodes:[...]} },
//           reviewRequests: { nodes: [...] } } }
//
// Per-section contract (exchange/12-s5b-correctness-review.md F4): GraphQL
// allows a response to carry `data` for the fields that resolved AND
// `errors` for the ones that didn't in the SAME envelope (GitHub's `search`
// -- used for reviewRequests -- has its own stricter rate-limit bucket
// separate from the object-graph API, so it's realistic for reviewRequests
// to error out while openPRs/repositories succeed in the same call). Each
// of the three returned sections is either a mapped array (the source field
// was present as an object in `data`, however many/few nodes it had -- an
// empty array is a legitimate "genuinely nothing here", not "unusable") or
// `null`, which is the explicit "this section did not resolve -- caller
// must NOT replace its last-good value" signal. A whole-envelope failure
// (non-object `json`, missing/non-object `json.data`) returns all three as
// null, which is the correct "nothing usable" case the caller treats as a
// full fetch failure.
function mapDashboard(json) {
  var result = { openPRs: null, reviewRequests: null, repos: null }
  if (!isObject(json)) return result
  var data = isObject(json.data) ? json.data : null
  if (!data) return result

  var viewer = isObject(data.viewer) ? data.viewer : null
  if (viewer && isObject(viewer.openPRs)) {
    result.openPRs = mapOpenPRs(viewer.openPRs.nodes)
  }
  if (viewer && isObject(viewer.repositories)) {
    result.repos = mapRepos(safeStr(viewer.login, ""), viewer.repositories.nodes)
  }
  if (isObject(data.reviewRequests)) {
    result.reviewRequests = mapReviewRequests(data.reviewRequests.nodes)
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
    repoWebUrl: repoWebUrl,
    truncate: truncate,
    FIELD_CAP_TEXT: FIELD_CAP_TEXT,
    FIELD_CAP_TAG: FIELD_CAP_TAG,
    FIELD_CAP_URL: FIELD_CAP_URL
  }
}
