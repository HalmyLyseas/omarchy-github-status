// test/model.test.js -- plain-assert Node tests over Model.js. No framework.
// Run: node test/model.test.js -- exits 0 on success, 1 on any failure.
"use strict"

var assert = require("assert")
var fs = require("fs")
var path = require("path")

var Model = require(path.join(__dirname, "..", "Model.js"))

var FIXTURES = path.join(__dirname, "fixtures")

function loadFixture(name) {
  return JSON.parse(fs.readFileSync(path.join(FIXTURES, name), "utf8"))
}

var passed = 0
var failed = 0
var failures = []

function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failed++
    failures.push({ name: name, error: e })
  }
}

// ------------------------------------------------------------- apiUrlToWebUrl

test("apiUrlToWebUrl: issues stays plural", function () {
  var web = Model.apiUrlToWebUrl({ type: "Issue", url: "https://api.github.com/repos/o/r/issues/5" })
  assert.strictEqual(web, "https://github.com/o/r/issues/5")
})

test("apiUrlToWebUrl: pulls -> pull, singular rewrite (the one real gotcha)", function () {
  var web = Model.apiUrlToWebUrl({ type: "PullRequest", url: "https://api.github.com/repos/o/r/pulls/42" })
  assert.strictEqual(web, "https://github.com/o/r/pull/42")
})

test("apiUrlToWebUrl: commits -> commit, singular rewrite", function () {
  var web = Model.apiUrlToWebUrl({ type: "Commit", url: "https://api.github.com/repos/o/r/commits/abc123" })
  assert.strictEqual(web, "https://github.com/o/r/commit/abc123")
})

test("apiUrlToWebUrl: releases", function () {
  var web = Model.apiUrlToWebUrl({ type: "Release", url: "https://api.github.com/repos/o/r/releases/9" })
  assert.strictEqual(web, "https://github.com/o/r/releases/9")
})

test("apiUrlToWebUrl: discussions", function () {
  var web = Model.apiUrlToWebUrl({ type: "Discussion", url: "https://api.github.com/repos/o/r/discussions/3" })
  assert.strictEqual(web, "https://github.com/o/r/discussions/3")
})

test("apiUrlToWebUrl: unknown/unmatched subject type -> empty string (caller falls back to repo html url)", function () {
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "CheckSuite", url: "https://api.github.com/repos/o/r/check-suites/1" }), "")
  assert.strictEqual(Model.apiUrlToWebUrl({}), "")
  assert.strictEqual(Model.apiUrlToWebUrl(null), "")
  assert.strictEqual(Model.apiUrlToWebUrl(undefined), "")
  assert.strictEqual(Model.apiUrlToWebUrl({ url: 12345 }), "")
  assert.strictEqual(Model.apiUrlToWebUrl({ url: "not a url at all" }), "")
})

// ------------------------------------------------------------- mapNotifications

test("mapNotifications: real fixture maps every item with expected shape", function () {
  var raw = loadFixture("notifications.json")
  assert.ok(Array.isArray(raw) && raw.length > 0, "fixture should be a non-empty array")
  var mapped = Model.mapNotifications(raw)
  assert.strictEqual(mapped.length, raw.length)
  mapped.forEach(function (item, i) {
    assert.strictEqual(typeof item.id, "string")
    assert.strictEqual(typeof item.unread, "boolean")
    assert.strictEqual(typeof item.reason, "string")
    assert.strictEqual(typeof item.title, "string")
    assert.strictEqual(typeof item.repo, "string")
    assert.strictEqual(typeof item.webUrl, "string")
    assert.strictEqual(typeof item.updatedAt, "string")
    // Every mapped item must resolve to *some* usable URL: either the
    // translated subject web URL or the repo's html_url fallback.
    assert.ok(item.webUrl.length > 0, "item " + i + " should have a non-empty webUrl")
  })
})

test("mapNotifications: PullRequest subject in the real fixture gets singular /pull/ rewrite", function () {
  var raw = loadFixture("notifications.json")
  var prNotification = raw.filter(function (n) {
    return n.subject && n.subject.type === "PullRequest"
  })[0]
  assert.ok(prNotification, "fixture should contain at least one PullRequest notification")
  var mapped = Model.mapNotifications([prNotification])[0]
  assert.ok(/\/pull\/\d+$/.test(mapped.webUrl), "expected singular /pull/N in " + mapped.webUrl)
  assert.ok(!/\/pulls\//.test(mapped.webUrl), "must not contain plural /pulls/")
})

test("mapNotifications: non-array input returns empty array, never throws", function () {
  assert.deepStrictEqual(Model.mapNotifications(null), [])
  assert.deepStrictEqual(Model.mapNotifications(undefined), [])
  assert.deepStrictEqual(Model.mapNotifications({}), [])
  assert.deepStrictEqual(Model.mapNotifications("not json"), [])
  assert.deepStrictEqual(Model.mapNotifications(42), [])
})

test("mapNotifications: tolerates null/missing fields on individual items", function () {
  var mapped = Model.mapNotifications([
    {},
    null,
    { id: 1, unread: "yes", subject: null, repository: null },
    { id: "2", unread: true, subject: { title: null, url: 5 }, repository: { full_name: null } }
  ])
  // null entries are skipped; the rest map to safe defaults.
  assert.strictEqual(mapped.length, 3)
  mapped.forEach(function (item) {
    assert.strictEqual(typeof item.title, "string")
    assert.strictEqual(typeof item.repo, "string")
    assert.strictEqual(typeof item.webUrl, "string")
  })
})

test("mapNotifications: adversarial huge array is capped at 50", function () {
  var huge = []
  for (var i = 0; i < 5000; i++) {
    huge.push({ id: String(i), unread: true, reason: "mention", subject: { title: "t" + i, url: "" }, repository: { full_name: "o/r" }, updated_at: "2026-01-01T00:00:00Z" })
  }
  var mapped = Model.mapNotifications(huge)
  assert.strictEqual(mapped.length, 50)
})

test("mapNotifications: rich-text/HTML-ish titles pass through untouched (mapping never sanitizes by mutation -- UI handles rendering)", function () {
  var evil = '<img src=x onerror=alert(1)>&amp;<script>alert(2)</script>'
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: evil, url: "" }, repository: { full_name: "o/r" } }
  ])
  assert.strictEqual(mapped[0].title, evil)
})

test("mapNotifications: never evals title content even if it looks like code", function () {
  var payload = "'; global.__pwned = true; ('"
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: payload, url: "" }, repository: { full_name: "o/r" } }
  ])
  assert.strictEqual(mapped[0].title, payload)
  assert.strictEqual(global.__pwned, undefined)
})

// ------------------------------------------------------------------- ciRollupToState

test("ciRollupToState: maps every documented state", function () {
  assert.strictEqual(Model.ciRollupToState("SUCCESS"), "success")
  assert.strictEqual(Model.ciRollupToState("FAILURE"), "failure")
  assert.strictEqual(Model.ciRollupToState("ERROR"), "failure")
  assert.strictEqual(Model.ciRollupToState("PENDING"), "pending")
  assert.strictEqual(Model.ciRollupToState("EXPECTED"), "pending")
  assert.strictEqual(Model.ciRollupToState(null), "none")
  assert.strictEqual(Model.ciRollupToState(undefined), "none")
  assert.strictEqual(Model.ciRollupToState("something-unknown"), "none")
})

test("ciRollupToState: accepts a GraphQL-shaped { state } object too", function () {
  assert.strictEqual(Model.ciRollupToState({ state: "SUCCESS" }), "success")
  assert.strictEqual(Model.ciRollupToState({ state: "FAILURE" }), "failure")
  assert.strictEqual(Model.ciRollupToState({}), "none")
})

// ------------------------------------------------------------------------- mapDashboard

test("mapDashboard: real mega-graphql fixture maps openPRs/reviewRequests/repos", function () {
  var raw = loadFixture("mega-graphql.json")
  var mapped = Model.mapDashboard(raw)

  assert.strictEqual(mapped.openPRs.length, raw.data.viewer.openPRs.nodes.length)
  var pr = mapped.openPRs[0]
  assert.strictEqual(pr.title, "Add Nujabes theme")
  assert.strictEqual(pr.repo, "omacom-io/omarchy-site")
  assert.strictEqual(pr.number, 77)
  assert.strictEqual(pr.webUrl, "https://github.com/omacom-io/omarchy-site/pull/77")
  assert.strictEqual(pr.isDraft, false)
  // statusCheckRollup was null in the real captured sample -- a legitimate
  // empty state (no CI configured), not a query bug (see 04-github-data.md #3).
  assert.strictEqual(pr.ciState, "none")
  assert.strictEqual(pr.reviewDecision, "")

  assert.strictEqual(mapped.repos.length, raw.data.viewer.repositories.nodes.length)
  var repoWithRelease = mapped.repos.filter(function (r) { return r.name === "VandalHearts-PcPort" })[0]
  assert.ok(repoWithRelease, "expected VandalHearts-PcPort in mapped repos")
  assert.strictEqual(repoWithRelease.releaseTag, "v2.0.0")
  assert.strictEqual(repoWithRelease.releaseUrl, "https://github.com/HalmyLyseas/VandalHearts-PcPort/releases/tag/v2.0.0")
  assert.strictEqual(repoWithRelease.url, "https://github.com/HalmyLyseas/VandalHearts-PcPort")
  assert.strictEqual(repoWithRelease.lastCommitHeadline, "gitignore: ignore platform/pc/timing_runs/")

  var repoWithCi = mapped.repos.filter(function (r) { return r.name === "fe3h-companionApp" })[0]
  assert.ok(repoWithCi, "expected fe3h-companionApp in mapped repos")

  var repoWithoutRelease = mapped.repos.filter(function (r) { return r.name === "omarchy-ristretto" })[0]
  assert.strictEqual(repoWithoutRelease.releaseTag, "")
  assert.strictEqual(repoWithoutRelease.releaseUrl, "")
})

test("mapDashboard: real review-requests-graphql empty-inbox fixture maps to []", function () {
  // This is the genuine "no review requests" shape from a live account, not
  // a fabricated empty case -- exchange/04-github-data.md #4.
  var reviewOnly = loadFixture("review-requests-graphql.json")
  var combined = { data: { viewer: {}, reviewRequests: reviewOnly.data.search } }
  var mapped = Model.mapDashboard(combined)
  assert.deepStrictEqual(mapped.reviewRequests, [])
})

test("mapDashboard: populated reviewRequests map correctly", function () {
  var combined = {
    data: {
      viewer: { login: "me", openPRs: { nodes: [] }, repositories: { nodes: [] } },
      reviewRequests: {
        nodes: [
          { title: "Fix thing", url: "https://github.com/o/r/pull/9", number: 9, updatedAt: "2026-01-01T00:00:00Z", repository: { nameWithOwner: "o/r" } }
        ]
      }
    }
  }
  var mapped = Model.mapDashboard(combined)
  assert.strictEqual(mapped.reviewRequests.length, 1)
  assert.strictEqual(mapped.reviewRequests[0].repo, "o/r")
  assert.strictEqual(mapped.reviewRequests[0].number, 9)
})

test("mapDashboard: non-object / malformed input returns empty shape, never throws", function () {
  var empty = { openPRs: [], reviewRequests: [], repos: [] }
  assert.deepStrictEqual(Model.mapDashboard(null), empty)
  assert.deepStrictEqual(Model.mapDashboard(undefined), empty)
  assert.deepStrictEqual(Model.mapDashboard("not json"), empty)
  assert.deepStrictEqual(Model.mapDashboard(42), empty)
  assert.deepStrictEqual(Model.mapDashboard([]), empty)
  assert.deepStrictEqual(Model.mapDashboard({}), empty)
  assert.deepStrictEqual(Model.mapDashboard({ data: null }), empty)
  assert.deepStrictEqual(Model.mapDashboard({ data: { viewer: null, reviewRequests: null } }), empty)
})

test("mapDashboard: adversarial huge node arrays get capped (PRs 20, reviewRequests 20, repos 30)", function () {
  function manyNodes(n, factory) {
    var nodes = []
    for (var i = 0; i < n; i++) nodes.push(factory(i))
    return nodes
  }
  var huge = {
    data: {
      viewer: {
        login: "me",
        openPRs: { nodes: manyNodes(500, function (i) { return { title: "pr" + i, url: "", number: i, updatedAt: "", repository: { nameWithOwner: "o/r" } } }) },
        repositories: { nodes: manyNodes(500, function (i) { return { name: "repo" + i } } ) }
      },
      reviewRequests: { nodes: manyNodes(500, function (i) { return { title: "rr" + i, url: "", number: i, repository: { nameWithOwner: "o/r" } } }) }
    }
  }
  var mapped = Model.mapDashboard(huge)
  assert.strictEqual(mapped.openPRs.length, 20)
  assert.strictEqual(mapped.reviewRequests.length, 20)
  assert.strictEqual(mapped.repos.length, 30)
})

test("mapDashboard: tolerates non-array `nodes` fields", function () {
  var mapped = Model.mapDashboard({
    data: {
      viewer: { openPRs: { nodes: "not an array" }, repositories: { nodes: null } },
      reviewRequests: { nodes: 42 }
    }
  })
  assert.deepStrictEqual(mapped, { openPRs: [], reviewRequests: [], repos: [] })
})

// -------------------------------------------------------------------- repoWebUrl

test("repoWebUrl: joins login + repo name", function () {
  assert.strictEqual(Model.repoWebUrl("HalmyLyseas", "VandalHearts-PcPort"), "https://github.com/HalmyLyseas/VandalHearts-PcPort")
})

test("repoWebUrl: empty on missing login or name", function () {
  assert.strictEqual(Model.repoWebUrl("", "r"), "")
  assert.strictEqual(Model.repoWebUrl("o", ""), "")
  assert.strictEqual(Model.repoWebUrl(null, "r"), "")
  assert.strictEqual(Model.repoWebUrl("o", null), "")
})

// ------------------------------------------------------------------------ relativeTime

test("relativeTime: just now / minutes / hours / days / weeks / date buckets", function () {
  var now = Date.parse("2026-08-27T12:00:00Z")
  assert.strictEqual(Model.relativeTime("2026-08-27T11:59:30Z", now), "just now")
  assert.strictEqual(Model.relativeTime("2026-08-27T11:55:00Z", now), "5m")
  assert.strictEqual(Model.relativeTime("2026-08-27T09:00:00Z", now), "3h")
  assert.strictEqual(Model.relativeTime("2026-08-25T12:00:00Z", now), "2d")
  assert.strictEqual(Model.relativeTime("2026-08-06T12:00:00Z", now), "3w")
  // > ~5 weeks out: falls back to an absolute date, no locale dependency.
  assert.strictEqual(Model.relativeTime("2026-01-15T00:00:00Z", now), "Jan 15, 2026")
})

test("relativeTime: invalid/missing input returns empty string, never throws", function () {
  assert.strictEqual(Model.relativeTime("", 1000), "")
  assert.strictEqual(Model.relativeTime(null, 1000), "")
  assert.strictEqual(Model.relativeTime(undefined, 1000), "")
  assert.strictEqual(Model.relativeTime("not a date", 1000), "")
  assert.strictEqual(Model.relativeTime(12345, 1000), "")
})

test("relativeTime: clock skew (future timestamp) doesn't throw or go negative-looking", function () {
  var now = Date.parse("2026-08-27T12:00:00Z")
  assert.strictEqual(Model.relativeTime("2026-08-27T12:05:00Z", now), "just now")
})

// -------------------------------------------------------------------- isSafeGithubUrl

test("isSafeGithubUrl: accepts real github.com URLs", function () {
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/HalmyLyseas/VandalHearts-PcPort"), true)
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/o/r/pull/1"), true)
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/"), true)
})

test("isSafeGithubUrl: rejects lookalike host", function () {
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com.evil.com/"), false)
})

test("isSafeGithubUrl: rejects non-https", function () {
  assert.strictEqual(Model.isSafeGithubUrl("http://github.com/"), false)
})

test("isSafeGithubUrl: rejects javascript: and other schemes", function () {
  assert.strictEqual(Model.isSafeGithubUrl("javascript:alert(1)"), false)
  assert.strictEqual(Model.isSafeGithubUrl("data:text/html,<script>alert(1)</script>"), false)
  assert.strictEqual(Model.isSafeGithubUrl("file:///etc/passwd"), false)
})

test("isSafeGithubUrl: rejects non-string / missing input, never throws", function () {
  assert.strictEqual(Model.isSafeGithubUrl(null), false)
  assert.strictEqual(Model.isSafeGithubUrl(undefined), false)
  assert.strictEqual(Model.isSafeGithubUrl(42), false)
  assert.strictEqual(Model.isSafeGithubUrl({}), false)
  assert.strictEqual(Model.isSafeGithubUrl([]), false)
})

test("isSafeGithubUrl: rejects a github.com URL used only as a substring/query trick", function () {
  assert.strictEqual(Model.isSafeGithubUrl("https://evil.com/?next=https://github.com/"), false)
  assert.strictEqual(Model.isSafeGithubUrl("https://evil.com/https://github.com/"), false)
})

// -------------------------------------------------------------------- classifyFailure

test("classifyFailure: gh not found (exit 127 / ENOENT-style stderr)", function () {
  assert.strictEqual(Model.classifyFailure("env: 'gh': No such file or directory", 127), "no-gh")
  assert.strictEqual(Model.classifyFailure("bash: gh: command not found", 127), "no-gh")
  assert.strictEqual(Model.classifyFailure("anything", 127), "no-gh")
})

test("classifyFailure: unauthenticated (HTTP 401 / Bad credentials)", function () {
  var stderr = 'gh: Bad credentials (HTTP 401)'
  assert.strictEqual(Model.classifyFailure(stderr, 1), "unauthenticated")
  assert.strictEqual(Model.classifyFailure("some other text mentioning HTTP 401 only", 1), "unauthenticated")
})

test("classifyFailure: offline (connection-level error, no HTTP status)", function () {
  var stderr = 'Get "https://api.github.com/user": proxyconnect tcp: dial tcp 127.0.0.1:1: connect: connection refused'
  assert.strictEqual(Model.classifyFailure(stderr, 1), "offline")
  assert.strictEqual(Model.classifyFailure("lookup api.github.com: no such host", 1), "offline")
  assert.strictEqual(Model.classifyFailure("context deadline exceeded (Client.Timeout exceeded)", 1), "offline")
})

test("classifyFailure: rate-limited (HTTP 403 + rate limit body, or the gh wording)", function () {
  assert.strictEqual(Model.classifyFailure("gh: API rate limit exceeded for user ID 123.", 1), "rate-limited")
  assert.strictEqual(Model.classifyFailure('{"message":"API rate limit exceeded"} (HTTP 403)', 1), "rate-limited")
})

test("classifyFailure: HTTP 304 classified distinctly, not as an error", function () {
  assert.strictEqual(Model.classifyFailure("gh: HTTP 304", 1), "http-304")
})

test("classifyFailure: unrecognized shape falls back to generic error", function () {
  assert.strictEqual(Model.classifyFailure("gh: something totally unexpected happened", 1), "error")
  assert.strictEqual(Model.classifyFailure("", 1), "error")
  assert.strictEqual(Model.classifyFailure(null, 2), "error")
})

// ---------------------------------------------------------------- parseHeadersAndBody

test("parseHeadersAndBody: real captured 200 notifications -i output (live-verified 2026-08-27)", function () {
  var raw = fs.readFileSync(path.join(FIXTURES, "notifications-i-200.txt"), "utf8")
  var parsed = Model.parseHeadersAndBody(raw)
  assert.strictEqual(parsed.status, 200)
  assert.strictEqual(parsed.etag, '"mock-etag-v1"')
  assert.ok(Array.isArray(parsed.body))
  assert.strictEqual(parsed.body.length, loadFixture("notifications.json").length)
})

test("parseHeadersAndBody: real captured 304 output has no body and status 304 (live-verified behavior)", function () {
  var raw = fs.readFileSync(path.join(FIXTURES, "notifications-i-304.txt"), "utf8")
  var parsed = Model.parseHeadersAndBody(raw)
  assert.strictEqual(parsed.status, 304)
  assert.strictEqual(parsed.etag, '"mock-etag-v1"')
  assert.strictEqual(parsed.body, null)
})

test("parseHeadersAndBody: header name matching is case-insensitive", function () {
  var raw = "HTTP/2.0 200 OK\nETAG: \"abc\"\n\n{}"
  var parsed = Model.parseHeadersAndBody(raw)
  assert.strictEqual(parsed.etag, '"abc"')
})

test("parseHeadersAndBody: malformed body yields body:null, never throws", function () {
  var raw = "HTTP/2.0 200 OK\r\nEtag: \"x\"\r\n\r\nnot valid json{{{"
  var parsed = Model.parseHeadersAndBody(raw)
  assert.strictEqual(parsed.status, 200)
  assert.strictEqual(parsed.body, null)
})

test("parseHeadersAndBody: empty/missing input returns defaults, never throws", function () {
  assert.deepStrictEqual(Model.parseHeadersAndBody(""), { status: 0, etag: "", body: null })
  assert.deepStrictEqual(Model.parseHeadersAndBody(null), { status: 0, etag: "", body: null })
  assert.deepStrictEqual(Model.parseHeadersAndBody(undefined), { status: 0, etag: "", body: null })
})

// -------------------------------------------------------------------------- badgeText

test("badgeText: caps at 99+", function () {
  assert.strictEqual(Model.badgeText(0), "0")
  assert.strictEqual(Model.badgeText(1), "1")
  assert.strictEqual(Model.badgeText(99), "99")
  assert.strictEqual(Model.badgeText(100), "99+")
  assert.strictEqual(Model.badgeText(123456), "99+")
})

test("badgeText: defensive on bad input", function () {
  assert.strictEqual(Model.badgeText(-5), "0")
  assert.strictEqual(Model.badgeText(null), "0")
  assert.strictEqual(Model.badgeText(undefined), "0")
  assert.strictEqual(Model.badgeText("not a number"), "0")
  assert.strictEqual(Model.badgeText(NaN), "0")
})

// ----------------------------------------------------------------------- summaryTooltip

test("summaryTooltip: composes from counts in order", function () {
  var text = Model.summaryTooltip({ unreadCount: 3, openPRCount: 1, ciFailingCount: 1 })
  assert.strictEqual(text, "3 unread · 1 PR · CI failing")
})

test("summaryTooltip: pluralizes PRs and review requests", function () {
  assert.strictEqual(Model.summaryTooltip({ openPRCount: 2 }), "2 PRs")
  assert.strictEqual(Model.summaryTooltip({ openPRCount: 1 }), "1 PR")
  assert.strictEqual(Model.summaryTooltip({ reviewRequestCount: 2 }), "2 review requests")
  assert.strictEqual(Model.summaryTooltip({ reviewRequestCount: 1 }), "1 review request")
})

test("summaryTooltip: empty/all-zero state has a sensible fallback", function () {
  assert.strictEqual(Model.summaryTooltip({}), "All caught up")
  assert.strictEqual(Model.summaryTooltip(null), "All caught up")
  assert.strictEqual(Model.summaryTooltip(undefined), "All caught up")
})

// ------------------------------------------------------------------------------ summary

console.log("")
console.log(passed + " passed, " + failed + " failed")
if (failed > 0) {
  failures.forEach(function (f) {
    console.log("")
    console.log("FAIL: " + f.name)
    console.log(f.error && f.error.stack ? f.error.stack : String(f.error))
  })
  process.exit(1)
}
process.exit(0)
