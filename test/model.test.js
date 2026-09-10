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

// ---------------------------------------------- apiUrlToWebUrl (adversarial)

test("apiUrlToWebUrl: shell-metacharacter-shaped trailing content is rejected", function () {
  // The finding's own repro: an embedded slash breaks the [^\/]+ rest
  // capture before ID validation even runs, so this never matches at all.
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "PullRequest", url: "https://api.github.com/repos/o/r/pulls/1; rm -rf /" }), "")
  // No embedded slash, but the ID segment isn't all-digits -- rejected by
  // SEGMENT_ID_RE instead.
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "PullRequest", url: "https://api.github.com/repos/o/r/pulls/1;+rm+-rf" }), "")
  // Control character (newline) inside the ID segment.
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "PullRequest", url: "https://api.github.com/repos/o/r/pulls/1\n../evil" }), "")
})

test("apiUrlToWebUrl: owner/repo restricted to the real GitHub identifier charset", function () {
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "Issue", url: "https://api.github.com/repos/o!/r/issues/5" }), "")
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "Issue", url: "https://api.github.com/repos/o/r r/issues/5" }), "")
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "Issue", url: "https://api.github.com/repos/o/r?evil=1/issues/5" }), "")
})

test("apiUrlToWebUrl: numeric-ID segments reject non-numeric content", function () {
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "Issue", url: "https://api.github.com/repos/o/r/issues/5abc" }), "")
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "Release", url: "https://api.github.com/repos/o/r/releases/latest" }), "")
})

test("apiUrlToWebUrl: commit SHA segment accepts hex, rejects non-hex", function () {
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "Commit", url: "https://api.github.com/repos/o/r/commits/deadbeef" }), "https://github.com/o/r/commit/deadbeef")
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "Commit", url: "https://api.github.com/repos/o/r/commits/not-a-sha" }), "")
})

test("apiUrlToWebUrl: overlong url is rejected", function () {
  var hugeOwner = new Array(3000).join("a")
  assert.strictEqual(Model.apiUrlToWebUrl({ type: "Issue", url: "https://api.github.com/repos/" + hugeOwner + "/r/issues/5" }), "")
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

test("mapNotifications: per-field string length is capped", function () {
  var hugeTitle = new Array(1024 * 1024 + 2).join("x")   // ~1MB
  var hugeReason = new Array(10000).join("y")
  var hugeRepo = new Array(10000).join("z")
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, reason: hugeReason, subject: { title: hugeTitle, url: "" }, repository: { full_name: hugeRepo, html_url: "https://github.com/" + new Array(5000).join("w") } }
  ])
  assert.strictEqual(mapped[0].title.length, 300)
  assert.strictEqual(mapped[0].title, hugeTitle.slice(0, 300))
  assert.strictEqual(mapped[0].reason.length, 100)
  assert.strictEqual(mapped[0].repo.length, 100)
  assert.ok(mapped[0].webUrl.length <= 2048)
})

test("mapNotifications: never evals title content even if it looks like code", function () {
  var payload = "'; global.__pwned = true; ('"
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: payload, url: "" }, repository: { full_name: "o/r" } }
  ])
  assert.strictEqual(mapped[0].title, payload)
  assert.strictEqual(global.__pwned, undefined)
})

// ------------------------------------------------- mapNotifications: own vs external

test("mapNotifications: login param sets isExternal/owner per item", function () {
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: "own repo", url: "" }, repository: { full_name: "HalmyLyseas/VandalHearts-PcPort" } },
    { id: "2", unread: false, subject: { title: "external repo", url: "" }, repository: { full_name: "octocat/Hello-World" } }
  ], "HalmyLyseas")
  assert.strictEqual(mapped[0].owner, "HalmyLyseas")
  assert.strictEqual(mapped[0].isExternal, false)
  assert.strictEqual(mapped[1].owner, "octocat")
  assert.strictEqual(mapped[1].isExternal, true)
})

test("mapNotifications: isExternal derivation is case-insensitive on the owner segment", function () {
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: "t", url: "" }, repository: { full_name: "HALMYLYSEAS/some-repo" } }
  ], "halmylyseas")
  assert.strictEqual(mapped[0].isExternal, false, "owner comparison must be case-insensitive")
})

test("mapNotifications: no login (undefined/empty) -- never external, never throws", function () {
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: "t", url: "" }, repository: { full_name: "octocat/Hello-World" } }
  ])
  assert.strictEqual(mapped[0].isExternal, false)
  assert.strictEqual(mapped[0].owner, "octocat")

  var mapped2 = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: "t", url: "" }, repository: { full_name: "octocat/Hello-World" } }
  ], "")
  assert.strictEqual(mapped2[0].isExternal, false)
})

test("mapNotifications: missing/malformed repository.full_name -- owner is empty, never external, never throws", function () {
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: "t", url: "" }, repository: {} },
    { id: "2", unread: true, subject: { title: "t2", url: "" }, repository: { full_name: "no-slash-here" } },
    { id: "3", unread: true, subject: { title: "t3", url: "" }, repository: null }
  ], "HalmyLyseas")
  mapped.forEach(function (item) {
    assert.strictEqual(item.owner, "")
    assert.strictEqual(item.isExternal, false)
  })
})

// ---------------------------------------------------- remapNotificationsExternal

test("remapNotificationsExternal: re-derives isExternal from each item's own owner, leaves every other field untouched", function () {
  var before = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: "own repo", url: "" }, repository: { full_name: "HalmyLyseas/VandalHearts-PcPort" }, updated_at: "2026-01-01T00:00:00Z" },
    { id: "2", unread: false, subject: { title: "external repo", url: "" }, repository: { full_name: "octocat/Hello-World" }, updated_at: "2026-01-02T00:00:00Z" }
  ])
  // No login was known yet -- both items came back non-external.
  assert.strictEqual(before[0].isExternal, false)
  assert.strictEqual(before[1].isExternal, false)

  var after = Model.remapNotificationsExternal(before, "HalmyLyseas")
  assert.strictEqual(after[0].isExternal, false, "own repo still not external")
  assert.strictEqual(after[1].isExternal, true, "external repo now correctly flagged, using the owner already carried on the item")
  // Every other field is identical, not just equal-looking (same id/title/etc).
  assert.strictEqual(after[0].id, before[0].id)
  assert.strictEqual(after[0].title, before[0].title)
  assert.strictEqual(after[0].owner, before[0].owner)
  assert.strictEqual(after[1].webUrl, before[1].webUrl)
  assert.strictEqual(after[1].updatedAt, before[1].updatedAt)
  // Original array/items are not mutated in place.
  assert.strictEqual(before[1].isExternal, false, "input array must not be mutated")
  assert.notStrictEqual(after, before)
})

test("remapNotificationsExternal: a login owning none of the items flags every one external (account switch)", function () {
  var before = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: "own repo", url: "" }, repository: { full_name: "HalmyLyseas/VandalHearts-PcPort" }, updated_at: "2026-01-01T00:00:00Z" },
    { id: "2", unread: false, subject: { title: "external repo", url: "" }, repository: { full_name: "octocat/Hello-World" }, updated_at: "2026-01-02T00:00:00Z" }
  ], "HalmyLyseas")
  assert.strictEqual(before[0].isExternal, false, "owned by the original login before the switch")

  var after = Model.remapNotificationsExternal(before, "SomeoneElse")
  assert.strictEqual(after[0].isExternal, true, "now external under the switched-to login")
  assert.strictEqual(after[1].isExternal, true)
})

test("remapNotificationsExternal: non-array / adversarial input never throws", function () {
  assert.deepStrictEqual(Model.remapNotificationsExternal(null, "x"), [])
  assert.deepStrictEqual(Model.remapNotificationsExternal(undefined, "x"), [])
  assert.deepStrictEqual(Model.remapNotificationsExternal("not an array", "x"), [])
  assert.deepStrictEqual(Model.remapNotificationsExternal([null, "garbage", 5], "x"), [null, "garbage", 5])
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

test("mapDashboard: real mega-graphql fixture maps openPRs/reviewRequests/repos/myIssues", function () {
  var raw = loadFixture("mega-graphql.json")
  var mapped = Model.mapDashboard(raw)

  assert.strictEqual(mapped.openPRs.length, raw.data.viewer.openPRs.nodes.length)
  var pr = mapped.openPRs[0]
  assert.strictEqual(pr.title, "Add Nujabes theme")
  assert.strictEqual(pr.repo, "omacom/omarchy-site")
  assert.strictEqual(pr.number, 77)
  assert.strictEqual(pr.webUrl, "https://github.com/omacom/omarchy-site/pull/77")
  assert.strictEqual(pr.isDraft, false)
  // statusCheckRollup was null in the real captured sample -- a legitimate
  // empty state (no CI configured), not a query bug.
  assert.strictEqual(pr.ciState, "none")
  assert.strictEqual(pr.reviewDecision, "")
  // This PR is against a fork of a third-party repo (omacom), not the
  // account's own -- a real example of an external PR row.
  assert.strictEqual(pr.owner, "omacom")
  assert.strictEqual(pr.isExternal, true)
  // This PR's live `comments(last: 1)` came back empty -- no comment yet.
  assert.strictEqual(pr.lastCommenter, "")
  assert.strictEqual(pr.lastCommentAt, "")

  assert.strictEqual(mapped.repos.length, raw.data.viewer.repositories.nodes.length)
  var repoWithRelease = mapped.repos.filter(function (r) { return r.name === "VandalHearts-PcPort" })[0]
  assert.ok(repoWithRelease, "expected VandalHearts-PcPort in mapped repos")
  assert.strictEqual(repoWithRelease.releaseTag, "v2.0.0")
  assert.strictEqual(repoWithRelease.releaseUrl, "https://github.com/HalmyLyseas/VandalHearts-PcPort/releases/tag/v2.0.0")
  assert.strictEqual(repoWithRelease.url, "https://github.com/HalmyLyseas/VandalHearts-PcPort")
  assert.strictEqual(repoWithRelease.lastCommitHeadline, "gitignore: ignore platform/pc/timing_runs/")
  assert.strictEqual(repoWithRelease.stars, 25)
  assert.strictEqual(repoWithRelease.isArchived, false)
  assert.strictEqual(repoWithRelease.isFork, false)
  assert.strictEqual(repoWithRelease.isPrivate, false)

  var repoWithCi = mapped.repos.filter(function (r) { return r.name === "fe3h-companionApp" })[0]
  assert.ok(repoWithCi, "expected fe3h-companionApp in mapped repos")

  var repoWithoutRelease = mapped.repos.filter(function (r) { return r.name === "omarchy-ristretto" })[0]
  assert.strictEqual(repoWithoutRelease.releaseTag, "")
  assert.strictEqual(repoWithoutRelease.releaseUrl, "")
  assert.strictEqual(repoWithoutRelease.stars, 1)

  // An archived repo flows through completely unfiltered (no isArchived
  // query arg anywhere), only pill-flagged.
  var archivedRepo = mapped.repos.filter(function (r) { return r.name === "VandalHearts-decomp-SLPM-86007" })[0]
  assert.ok(archivedRepo, "expected the archived VandalHearts-decomp repo in mapped repos -- must not be filtered out")
  assert.strictEqual(archivedRepo.isArchived, true)
  assert.strictEqual(Model.repoPill(archivedRepo), "archived")

  var forkRepo = mapped.repos.filter(function (r) { return r.name === "omarchy-site" })[0]
  assert.strictEqual(forkRepo.isFork, true)
  assert.strictEqual(Model.repoPill(forkRepo), "fork")

  // An issue authored by this account, in a repo it does not own, MUST
  // appear in myIssues.
  assert.strictEqual(mapped.myIssues.length, raw.data.viewer.myIssues.nodes.length)
  var marketplaceIssue = mapped.myIssues.filter(function (i) { return i.number === 2672 })[0]
  assert.ok(marketplaceIssue, "expected HANCORE-linux/omarchy-plugin-marketplace#2672 in myIssues")
  assert.strictEqual(marketplaceIssue.repo, "HANCORE-linux/omarchy-plugin-marketplace")
  assert.strictEqual(marketplaceIssue.webUrl, "https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/2672")
  assert.strictEqual(marketplaceIssue.owner, "HANCORE-linux")
  assert.strictEqual(marketplaceIssue.isExternal, true)
  // This account is still subscribed to its own marketplace verification issue.
  assert.strictEqual(marketplaceIssue.subscribed, true)
  // A real comment on this issue, authored by the account itself.
  assert.strictEqual(marketplaceIssue.lastCommenter, "HalmyLyseas")
  assert.strictEqual(marketplaceIssue.lastCommentAt, "2026-08-27T21:47:43Z")

  // A real UNSUBSCRIBED example -- MUST come back subscribed:false so
  // filterIssues("focus") hides it by default.
  var protonIssue = mapped.myIssues.filter(function (i) { return i.number === 8626 })[0]
  assert.ok(protonIssue, "expected ValveSoftware/Proton#8626 in myIssues")
  assert.strictEqual(protonIssue.repo, "ValveSoftware/Proton")
  assert.strictEqual(protonIssue.subscribed, false)
  assert.strictEqual(protonIssue.lastCommenter, "neidlosEnte7")
  assert.strictEqual(protonIssue.lastCommentAt, "2026-05-08T20:42:19Z")

  // Every other live myIssues row in the fixture is SUBSCRIBED with no
  // recent comment of its own.
  var themeIssue = mapped.myIssues.filter(function (i) { return i.number === 117 })[0]
  assert.strictEqual(themeIssue.subscribed, true)
  assert.strictEqual(themeIssue.lastCommenter, "")
  assert.strictEqual(themeIssue.lastCommentAt, "")

  // mapDashboard also returns the viewer's own login straight off the
  // envelope, independent of whether any section resolved -- Service.qml's
  // opportunistic capture (handleDashboardExit) reads this.
  assert.strictEqual(mapped.login, raw.data.viewer.login)
  assert.ok(mapped.login, "expected a non-empty login in the real fixture")

  // totalCount/issueCount ride alongside each section, read straight off
  // the fixture's own GraphQL metadata (bumped above each section's own
  // cap/window so "N of T" has real coverage).
  assert.strictEqual(mapped.openPRsTotal, raw.data.viewer.openPRs.totalCount)
  assert.strictEqual(mapped.myIssuesTotal, raw.data.viewer.myIssues.totalCount)
  assert.strictEqual(mapped.reposTotal, raw.data.viewer.repositories.totalCount)
  assert.strictEqual(mapped.reviewRequestsTotal, raw.data.reviewRequests.issueCount)
  assert.ok(mapped.openPRsTotal > mapped.openPRs.length, "openPRsTotal exceeds the rendered/capped count")
  assert.ok(mapped.myIssuesTotal > mapped.myIssues.length, "myIssuesTotal exceeds the rendered/capped count")
  assert.ok(mapped.reposTotal > mapped.repos.length, "reposTotal exceeds the rendered/capped count")
  assert.ok(mapped.reviewRequestsTotal > mapped.reviewRequests.length, "reviewRequestsTotal exceeds the rendered count")
})

test("mapDashboard: login field -- present when viewer.login is set, empty string when missing/malformed, never null", function () {
  assert.strictEqual(Model.mapDashboard({ data: { viewer: { login: "HalmyLyseas" } } }).login, "HalmyLyseas")
  assert.strictEqual(Model.mapDashboard({ data: { viewer: {} } }).login, "")
  assert.strictEqual(Model.mapDashboard({ data: { viewer: { login: 42 } } }).login, "")
  assert.strictEqual(Model.mapDashboard({ data: { viewer: null } }).login, "")
  assert.strictEqual(Model.mapDashboard({ data: {} }).login, "")
  assert.strictEqual(Model.mapDashboard(null).login, "")
})

test("mapDashboard: real review-requests-graphql empty-inbox fixture maps to []", function () {
  // This is the genuine "no review requests" shape from a live account,
  // not a fabricated empty case.
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

test("mapDashboard: non-object / malformed input returns all-null per-section shape (nothing usable -- caller must not replace last-good data), never throws", function () {
  // A section is `null` (not []) when it did not resolve at all -- the
  // explicit "don't replace" signal the Service layer relies on.
  var allNull = {
    openPRs: null, reviewRequests: null, repos: null, myIssues: null, login: "",
    openPRsTotal: null, reviewRequestsTotal: null, reposTotal: null, myIssuesTotal: null
  }
  assert.deepStrictEqual(Model.mapDashboard(null), allNull)
  assert.deepStrictEqual(Model.mapDashboard(undefined), allNull)
  assert.deepStrictEqual(Model.mapDashboard("not json"), allNull)
  assert.deepStrictEqual(Model.mapDashboard(42), allNull)
  assert.deepStrictEqual(Model.mapDashboard([]), allNull)
  assert.deepStrictEqual(Model.mapDashboard({}), allNull)
  assert.deepStrictEqual(Model.mapDashboard({ data: null }), allNull)
  assert.deepStrictEqual(Model.mapDashboard({ data: { viewer: null, reviewRequests: null } }), allNull)
})

// ------------------------------------------- mapDashboard partial-GraphQL

test("mapDashboard: partial envelope (data present for some sections, errors for others) keeps the sections that parsed, nulls the rest", function () {
  // Realistic shape: reviewRequests (via GraphQL `search`, its own stricter
  // rate-limit bucket) errored out; openPRs/repositories still resolved in
  // the same envelope, alongside a top-level `errors` array.
  var partial = {
    data: {
      viewer: {
        login: "me",
        openPRs: { totalCount: 9, nodes: [{ title: "Fix bug", url: "https://github.com/o/r/pull/1", number: 1, updatedAt: "2026-01-01T00:00:00Z", repository: { nameWithOwner: "o/r" } }] },
        repositories: { totalCount: 3, nodes: [{ name: "r" }] }
      },
      reviewRequests: null
    },
    errors: [{ message: "Something went wrong while executing your query. Please include `X-abc` when reporting this issue." }]
  }
  var mapped = Model.mapDashboard(partial)
  assert.strictEqual(mapped.openPRs.length, 1)
  assert.strictEqual(mapped.openPRs[0].title, "Fix bug")
  assert.strictEqual(mapped.repos.length, 1)
  assert.strictEqual(mapped.reviewRequests, null, "the errored section must be null, not []," +
    " so the Service layer knows not to replace last-good reviewRequests")
  // A parsed section's total rides along with it; the errored section's
  // total is null exactly like the section itself.
  assert.strictEqual(mapped.openPRsTotal, 9)
  assert.strictEqual(mapped.reposTotal, 3)
  assert.strictEqual(mapped.reviewRequestsTotal, null)
})

test("mapDashboard: fully-successful envelope with a coexisting (unrelated/empty) errors array still maps every section", function () {
  var mapped = Model.mapDashboard({
    data: {
      viewer: { login: "me", openPRs: { nodes: [] }, repositories: { nodes: [] }, myIssues: { nodes: [] } },
      reviewRequests: { nodes: [] }
    },
    errors: []
  })
  assert.deepStrictEqual(mapped, {
    openPRs: [], reviewRequests: [], repos: [], myIssues: [], login: "me",
    openPRsTotal: 0, reviewRequestsTotal: 0, reposTotal: 0, myIssuesTotal: 0
  })
})

test("mapDashboard: adversarial huge node arrays get capped (PRs 20, reviewRequests 20, repos 30, myIssues 20)", function () {
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
        repositories: { nodes: manyNodes(500, function (i) { return { name: "repo" + i } } ) },
        myIssues: { nodes: manyNodes(500, function (i) { return { title: "issue" + i, url: "", number: i, updatedAt: "", repository: { nameWithOwner: "o/r" } } }) }
      },
      reviewRequests: { nodes: manyNodes(500, function (i) { return { title: "rr" + i, url: "", number: i, repository: { nameWithOwner: "o/r" } } }) }
    }
  }
  var mapped = Model.mapDashboard(huge)
  assert.strictEqual(mapped.openPRs.length, 20)
  assert.strictEqual(mapped.reviewRequests.length, 20)
  assert.strictEqual(mapped.repos.length, 30)
  assert.strictEqual(mapped.myIssues.length, 20)
})

test("mapDashboard: a non-array `nodes` field leaves that section null (unparsed), never a false empty list", function () {
  var mapped = Model.mapDashboard({
    data: {
      viewer: { openPRs: { nodes: "not an array" }, repositories: { nodes: null }, myIssues: { nodes: 7 } },
      reviewRequests: { nodes: 42 }
    }
  })
  assert.deepStrictEqual(mapped, {
    openPRs: null, reviewRequests: null, repos: null, myIssues: null, login: "",
    openPRsTotal: null, reviewRequestsTotal: null, reposTotal: null, myIssuesTotal: null
  })
})

test("mapDashboard: an object connection with no `nodes` key at all also leaves the section null", function () {
  var mapped = Model.mapDashboard({
    data: {
      viewer: { openPRs: {}, repositories: {}, myIssues: {} },
      reviewRequests: {}
    }
  })
  assert.deepStrictEqual(mapped, {
    openPRs: null, reviewRequests: null, repos: null, myIssues: null, login: "",
    openPRsTotal: null, reviewRequestsTotal: null, reposTotal: null, myIssuesTotal: null
  })
})

test("mapDashboard: per-field string length is capped", function () {
  var hugeText = new Array(1024 * 1024 + 2).join("x")
  var hugeTag = new Array(10000).join("y")
  var mapped = Model.mapDashboard({
    data: {
      viewer: {
        login: "me",
        openPRs: { nodes: [{ title: hugeText, url: "https://github.com/" + hugeTag, number: 1, updatedAt: hugeTag, repository: { nameWithOwner: hugeTag }, reviewDecision: hugeTag }] },
        repositories: { nodes: [{ name: hugeTag, pushedAt: hugeTag, latestRelease: { tagName: hugeTag, url: "https://github.com/" + hugeTag }, defaultBranchRef: { target: { messageHeadline: hugeText } } }] },
        myIssues: { nodes: [{ title: hugeText, url: "https://github.com/" + hugeTag, number: 3, updatedAt: hugeTag, repository: { nameWithOwner: hugeTag } }] }
      },
      reviewRequests: { nodes: [{ title: hugeText, url: "https://github.com/" + hugeTag, number: 2, updatedAt: hugeTag, repository: { nameWithOwner: hugeTag } }] }
    }
  })
  assert.strictEqual(mapped.openPRs[0].title.length, 300)
  assert.strictEqual(mapped.openPRs[0].repo.length, 100)
  assert.ok(mapped.openPRs[0].webUrl.length <= 2048)
  assert.strictEqual(mapped.openPRs[0].reviewDecision.length, 100)
  // `owner` is derived from the (already-capped) `repo` field, so it is
  // naturally bounded too -- no separate cap needed, just proof it doesn't
  // explode past the repo field's own cap.
  assert.ok(mapped.openPRs[0].owner.length <= 100)
  assert.strictEqual(mapped.reviewRequests[0].title.length, 300)
  assert.strictEqual(mapped.repos[0].name.length, 100)
  assert.strictEqual(mapped.repos[0].releaseTag.length, 100)
  assert.strictEqual(mapped.repos[0].lastCommitHeadline.length, 300)
  assert.strictEqual(mapped.myIssues[0].title.length, 300)
  assert.strictEqual(mapped.myIssues[0].repo.length, 100)
  assert.ok(mapped.myIssues[0].webUrl.length <= 2048)
  assert.ok(mapped.myIssues[0].owner.length <= 100)
})

// ---------------------------------------------------- mapDashboard: repos fields

test("mapDashboard: repos gain stars/isArchived/isFork/isPrivate, strict boolean typing", function () {
  var mapped = Model.mapDashboard({
    data: {
      viewer: {
        login: "me",
        openPRs: { nodes: [] },
        repositories: {
          nodes: [
            { name: "r1", stargazerCount: 42, isArchived: true, isFork: false, isPrivate: false },
            { name: "r2", stargazerCount: 0, isArchived: false, isFork: true, isPrivate: true }
          ]
        }
      },
      reviewRequests: { nodes: [] }
    }
  })
  assert.strictEqual(mapped.repos[0].stars, 42)
  assert.strictEqual(mapped.repos[0].isArchived, true)
  assert.strictEqual(mapped.repos[0].isFork, false)
  assert.strictEqual(mapped.repos[0].isPrivate, false)
  assert.strictEqual(mapped.repos[1].stars, 0)
  assert.strictEqual(mapped.repos[1].isFork, true)
  assert.strictEqual(mapped.repos[1].isPrivate, true)
})

test("mapDashboard: repos -- adversarial huge stargazerCount, missing/non-boolean flags never throw", function () {
  var mapped = Model.mapDashboard({
    data: {
      viewer: {
        login: "me",
        openPRs: { nodes: [] },
        repositories: {
          nodes: [
            { name: "huge-stars", stargazerCount: Number.MAX_SAFE_INTEGER },
            { name: "no-fields" },
            { name: "malformed-flags", isArchived: "true", isFork: 1, isPrivate: null, stargazerCount: "not a number" }
          ]
        }
      },
      reviewRequests: { nodes: [] }
    }
  })
  assert.strictEqual(mapped.repos[0].stars, Number.MAX_SAFE_INTEGER)
  assert.strictEqual(mapped.repos[1].stars, 0)
  assert.strictEqual(mapped.repos[1].isArchived, false)
  assert.strictEqual(mapped.repos[1].isFork, false)
  assert.strictEqual(mapped.repos[1].isPrivate, false)
  // Non-boolean truthy values must not be coerced to true -- strict `=== true`.
  assert.strictEqual(mapped.repos[2].isArchived, false)
  assert.strictEqual(mapped.repos[2].isFork, false)
  assert.strictEqual(mapped.repos[2].isPrivate, false)
  assert.strictEqual(mapped.repos[2].stars, 0)
})

// -------------------------------------------------------------------- truncate

test("truncate: passes short strings through, caps long ones, defends bad input", function () {
  assert.strictEqual(Model.truncate("short", 10), "short")
  assert.strictEqual(Model.truncate("a very long string here", 5), "a ver")
  assert.strictEqual(Model.truncate(null, 5), "")
  assert.strictEqual(Model.truncate(undefined, 5, "abc"), "abc")
  assert.strictEqual(Model.truncate(42, 5, "42"), "42")
  // A caller-supplied fallback longer than maxLen is truncated too --
  // truncate's cap is unconditional, not just for the primary value.
  assert.strictEqual(Model.truncate(undefined, 5, "fallback"), "fallb")
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

// -------------------------------------------------- ownerFromNameWithOwner / isExternalOwner

test("ownerFromNameWithOwner: extracts the owner segment", function () {
  assert.strictEqual(Model.ownerFromNameWithOwner("HalmyLyseas/VandalHearts-PcPort"), "HalmyLyseas")
  assert.strictEqual(Model.ownerFromNameWithOwner("HANCORE-linux/omarchy-plugin-marketplace"), "HANCORE-linux")
})

test("ownerFromNameWithOwner: adversarial/missing input never throws, empty on no usable owner", function () {
  assert.strictEqual(Model.ownerFromNameWithOwner(""), "")
  assert.strictEqual(Model.ownerFromNameWithOwner(null), "")
  assert.strictEqual(Model.ownerFromNameWithOwner(undefined), "")
  assert.strictEqual(Model.ownerFromNameWithOwner(42), "")
  assert.strictEqual(Model.ownerFromNameWithOwner("no-slash-at-all"), "")
  assert.strictEqual(Model.ownerFromNameWithOwner("/leading-slash-no-owner"), "")
  // Only the FIRST "/" delimits owner/repo -- a repo name containing a
  // slash (can't happen on GitHub, but defend anyway) doesn't confuse this.
  assert.strictEqual(Model.ownerFromNameWithOwner("owner/repo/extra"), "owner")
})

test("isExternalOwner: case-insensitive comparison", function () {
  assert.strictEqual(Model.isExternalOwner("HalmyLyseas", "HalmyLyseas"), false)
  assert.strictEqual(Model.isExternalOwner("HALMYLYSEAS", "halmylyseas"), false)
  assert.strictEqual(Model.isExternalOwner("HalmyLyseas", "halmylyseas"), false)
  assert.strictEqual(Model.isExternalOwner("octocat", "HalmyLyseas"), true)
})

test("isExternalOwner: missing owner or login defaults to non-external (no false-positive pill), never throws", function () {
  assert.strictEqual(Model.isExternalOwner("", "HalmyLyseas"), false)
  assert.strictEqual(Model.isExternalOwner("octocat", ""), false)
  assert.strictEqual(Model.isExternalOwner(null, undefined), false)
  assert.strictEqual(Model.isExternalOwner(undefined, "HalmyLyseas"), false)
  assert.strictEqual(Model.isExternalOwner(42, "HalmyLyseas"), false)
})

// ---------------------------------------------------------------------- repoPill

test("repoPill: priority order archived > fork > private, one pill max", function () {
  assert.strictEqual(Model.repoPill({ isArchived: true, isFork: false, isPrivate: false }), "archived")
  assert.strictEqual(Model.repoPill({ isArchived: false, isFork: true, isPrivate: false }), "fork")
  assert.strictEqual(Model.repoPill({ isArchived: false, isFork: false, isPrivate: true }), "private")
  assert.strictEqual(Model.repoPill({ isArchived: false, isFork: false, isPrivate: false }), "")
})

test("repoPill: adversarial -- unknown/multiple-true combos still resolve to exactly one pill, archived wins", function () {
  assert.strictEqual(Model.repoPill({ isArchived: true, isFork: true, isPrivate: true }), "archived")
  assert.strictEqual(Model.repoPill({ isArchived: true, isFork: true, isPrivate: false }), "archived")
  assert.strictEqual(Model.repoPill({ isArchived: false, isFork: true, isPrivate: true }), "fork")
})

test("repoPill: defensive on missing/malformed input, never throws", function () {
  assert.strictEqual(Model.repoPill(null), "")
  assert.strictEqual(Model.repoPill(undefined), "")
  assert.strictEqual(Model.repoPill({}), "")
  assert.strictEqual(Model.repoPill("not an object"), "")
  assert.strictEqual(Model.repoPill({ isArchived: "yes" }), "", "non-boolean truthy value must not count as true")
})

// Repos render in fetch order (GraphQL PUSHED_AT desc), sliced by
// repoLimit in Service.qml; no client-side sort layer remains.

// ---------------------------------------------------------------------- lastComment

test("lastComment: extracts commenter/commentAt from the single comments(last: 1) node", function () {
  var c = Model.lastComment({ nodes: [{ author: { login: "octocat" }, updatedAt: "2026-08-27T10:00:00Z" }] })
  assert.deepStrictEqual(c, { commenter: "octocat", commentAt: "2026-08-27T10:00:00Z" })
})

test("lastComment: no comments at all -> both fields empty", function () {
  assert.deepStrictEqual(Model.lastComment({ nodes: [] }), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment(null), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment(undefined), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment({}), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment({ nodes: "not an array" }), { commenter: "", commentAt: "" })
})

test("lastComment: a deleted GitHub user's comment has author: null -- both fields collapse to empty, not a throw", function () {
  var c = Model.lastComment({ nodes: [{ author: null, updatedAt: "2026-08-27T10:00:00Z" }] })
  assert.deepStrictEqual(c, { commenter: "", commentAt: "" })
})

test("lastComment: adversarial -- missing author.login, non-object node, oversized login capped at FIELD_CAP_COMMENTER", function () {
  assert.deepStrictEqual(Model.lastComment({ nodes: [{ author: {}, updatedAt: "x" }] }), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment({ nodes: [null] }), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment({ nodes: ["not an object"] }), { commenter: "", commentAt: "" })
  var hugeLogin = new Array(1000).join("z")
  var c = Model.lastComment({ nodes: [{ author: { login: hugeLogin }, updatedAt: "2026-01-01T00:00:00Z" }] })
  assert.strictEqual(c.commenter.length, 40)
})

test("lastComment: only the LAST node in the connection is used (last: 1 should already only send one, defend anyway)", function () {
  var c = Model.lastComment({
    nodes: [
      { author: { login: "first" }, updatedAt: "2026-01-01T00:00:00Z" },
      { author: { login: "second" }, updatedAt: "2026-01-02T00:00:00Z" }
    ]
  })
  assert.strictEqual(c.commenter, "second")
})

// A real author with a missing/null/malformed updatedAt must collapse BOTH
// fields to "" -- the pairing lastComment()'s own header documents is
// symmetric, not just commentAt-follows-commenter.
test("lastComment: present author, missing/null/non-string updatedAt -- BOTH fields collapse to empty, not just commentAt", function () {
  assert.deepStrictEqual(Model.lastComment({ nodes: [{ author: { login: "octocat" }, updatedAt: null }] }), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment({ nodes: [{ author: { login: "octocat" } }] }), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment({ nodes: [{ author: { login: "octocat" }, updatedAt: 42 }] }), { commenter: "", commentAt: "" })
  assert.deepStrictEqual(Model.lastComment({ nodes: [{ author: { login: "octocat" }, updatedAt: "" }] }), { commenter: "", commentAt: "" })
})

// ------------------------------------------------------------ subscribedFromViewerSubscription

test("subscribedFromViewerSubscription: SUBSCRIBED -> true, anything else resolved -> false", function () {
  assert.strictEqual(Model.subscribedFromViewerSubscription("SUBSCRIBED"), true)
  assert.strictEqual(Model.subscribedFromViewerSubscription("UNSUBSCRIBED"), false)
  assert.strictEqual(Model.subscribedFromViewerSubscription("IGNORED"), false)
  assert.strictEqual(Model.subscribedFromViewerSubscription("something-unexpected"), false)
})

test("subscribedFromViewerSubscription: missing/null field fails OPEN (true) -- a schema hiccup must never hide the user's own issues", function () {
  assert.strictEqual(Model.subscribedFromViewerSubscription(undefined), true)
  assert.strictEqual(Model.subscribedFromViewerSubscription(null), true)
})

// ---------------------------------------------------------------------- matchesQuery

test("matchesQuery: case-insensitive substring match over title/repo/owner", function () {
  var item = { title: "Add Nujabes theme", repo: "HalmyLyseas/omarchy-nujabes-theme", owner: "HalmyLyseas" }
  assert.strictEqual(Model.matchesQuery(item, "nujabes"), true)
  assert.strictEqual(Model.matchesQuery(item, "NUJABES"), true)
  assert.strictEqual(Model.matchesQuery(item, "HalmyLyseas"), true)
  assert.strictEqual(Model.matchesQuery(item, "omarchy-nujabes"), true)
  assert.strictEqual(Model.matchesQuery(item, "no-match-here"), false)
})

test("matchesQuery: matches a repo-activity row's `name` field too", function () {
  var repoItem = { name: "omarchy-nujabes-theme" }
  assert.strictEqual(Model.matchesQuery(repoItem, "nujabes"), true)
  assert.strictEqual(Model.matchesQuery(repoItem, "ristretto"), false)
})

test("matchesQuery: empty/whitespace-only query matches everything, including an item with no matchable fields", function () {
  assert.strictEqual(Model.matchesQuery({ title: "x" }, ""), true)
  assert.strictEqual(Model.matchesQuery({ title: "x" }, "   "), true)
  assert.strictEqual(Model.matchesQuery({ title: "x" }, undefined), true)
  assert.strictEqual(Model.matchesQuery({ title: "x" }, null), true)
  assert.strictEqual(Model.matchesQuery({}, ""), true)
  assert.strictEqual(Model.matchesQuery({ someOtherField: "nujabes" }, ""), true)
})

test("matchesQuery: item with no matchable fields never matches a real query, never throws", function () {
  assert.strictEqual(Model.matchesQuery({}, "nujabes"), false)
  assert.strictEqual(Model.matchesQuery({ someUnrelatedField: 42 }, "nujabes"), false)
  assert.strictEqual(Model.matchesQuery(null, "nujabes"), false)
  assert.strictEqual(Model.matchesQuery(undefined, "nujabes"), false)
  assert.strictEqual(Model.matchesQuery("not an object", "nujabes"), false)
})

test("matchesQuery: defensive on non-string matchable fields, never throws", function () {
  var item = { title: 42, repo: null, owner: undefined, name: { nested: true } }
  assert.strictEqual(Model.matchesQuery(item, "42"), false)
})

test("matchesQuery: unicode query matches unicode field content", function () {
  var item = { title: "テーマ: Nujabes 米津玄師", repo: "o/r", owner: "o" }
  assert.strictEqual(Model.matchesQuery(item, "米津玄師"), true)
  assert.strictEqual(Model.matchesQuery(item, "テーマ"), true)
  assert.strictEqual(Model.matchesQuery(item, "café"), false)
})

test("matchesQuery: query longer than QUERY_CAP is truncated before matching, never throws", function () {
  var longQuery = new Array(100 + 500).join("a")
  var item = { title: new Array(100 + 500).join("a") }
  // Both sides get capped the same way in practice (title itself is capped
  // at FIELD_CAP_TEXT by the mappers) -- this asserts the query side alone
  // never throws or hangs on a huge input, whatever it matches to.
  assert.strictEqual(typeof Model.matchesQuery(item, longQuery), "boolean")
  assert.strictEqual(Model.matchesQuery({ title: "short" }, longQuery), false)
})

// ---------------------------------------------------------------------- filterIssues

function fakeIssue(number, subscribed) {
  return { number: number, subscribed: subscribed }
}

test("filterIssues: focus mode keeps only subscribed:true rows", function () {
  var issues = [fakeIssue(1, true), fakeIssue(2, false), fakeIssue(3, true)]
  var filtered = Model.filterIssues(issues, "focus")
  assert.deepStrictEqual(filtered.map(function (i) { return i.number }), [1, 3])
})

test("filterIssues: all mode is a pass-through copy, unfiltered", function () {
  var issues = [fakeIssue(1, true), fakeIssue(2, false)]
  var filtered = Model.filterIssues(issues, "all")
  assert.deepStrictEqual(filtered.map(function (i) { return i.number }), [1, 2])
  assert.notStrictEqual(filtered, issues, "must return a new array, not the same reference")
})

test("filterIssues: unrecognized/missing mode falls back to focus", function () {
  var issues = [fakeIssue(1, true), fakeIssue(2, false)]
  assert.deepStrictEqual(Model.filterIssues(issues, "bogus-mode").map(function (i) { return i.number }), [1])
  assert.deepStrictEqual(Model.filterIssues(issues, undefined).map(function (i) { return i.number }), [1])
  assert.deepStrictEqual(Model.filterIssues(issues, null).map(function (i) { return i.number }), [1])
})

test("filterIssues: focus fails OPEN on a row missing the subscribed field entirely (not === false)", function () {
  var issues = [{ number: 1 }, fakeIssue(2, false)]
  assert.deepStrictEqual(Model.filterIssues(issues, "focus").map(function (i) { return i.number }), [1])
})

test("filterIssues: real acceptance data -- Proton#8626 hidden in focus, visible in all", function () {
  var raw = loadFixture("mega-graphql.json")
  var mapped = Model.mapDashboard(raw)
  var focus = Model.filterIssues(mapped.myIssues, "focus")
  var all = Model.filterIssues(mapped.myIssues, "all")
  assert.strictEqual(focus.some(function (i) { return i.number === 8626 }), false, "Proton#8626 (unsubscribed) must be hidden by default")
  assert.strictEqual(all.some(function (i) { return i.number === 8626 }), true, "Proton#8626 must still appear under All")
  assert.strictEqual(focus.some(function (i) { return i.number === 2672 }), true, "the subscribed marketplace issue stays visible under Focus")
})

test("filterIssues: defensive on non-array input, never throws", function () {
  assert.deepStrictEqual(Model.filterIssues(null, "focus"), [])
  assert.deepStrictEqual(Model.filterIssues(undefined, "all"), [])
  assert.deepStrictEqual(Model.filterIssues("not an array", "focus"), [])
})

// -------------------------------------------------------------------------- entryFor

var PLUGIN_ID = "halmylyseas.github-status"

test("entryFor: finds the own entry in bar.layout.left/center/right", function () {
  var left = { id: PLUGIN_ID, dashboardIntervalSec: 200 }
  var center = { id: PLUGIN_ID, dashboardIntervalSec: 300 }
  var right = { id: PLUGIN_ID, dashboardIntervalSec: 400 }
  assert.strictEqual(Model.entryFor({ bar: { layout: { left: [left] } } }, PLUGIN_ID), left)
  assert.strictEqual(Model.entryFor({ bar: { layout: { center: [center] } } }, PLUGIN_ID), center)
  assert.strictEqual(Model.entryFor({ bar: { layout: { right: [right] } } }, PLUGIN_ID), right)
})

test("entryFor: falls back to plugins[] when not in the layout", function () {
  var entry = { id: PLUGIN_ID, repoLimit: 5 }
  var config = { bar: { layout: { left: [] } }, plugins: [{ id: "other" }, entry] }
  assert.strictEqual(Model.entryFor(config, PLUGIN_ID), entry)
})

test("entryFor: missing entry (not in layout or plugins) returns null", function () {
  var config = { bar: { layout: { left: [{ id: "other" }] } }, plugins: [{ id: "another" }] }
  assert.strictEqual(Model.entryFor(config, PLUGIN_ID), null)
})

test("entryFor: a bare-string layout entry is skipped, not matched", function () {
  var config = { bar: { layout: { left: [PLUGIN_ID] } } }
  assert.strictEqual(Model.entryFor(config, PLUGIN_ID), null)
})

test("entryFor: defensive on missing/malformed config, never throws", function () {
  assert.strictEqual(Model.entryFor(null, PLUGIN_ID), null)
  assert.strictEqual(Model.entryFor(undefined, PLUGIN_ID), null)
  assert.strictEqual(Model.entryFor([], PLUGIN_ID), null)
  assert.strictEqual(Model.entryFor({ bar: { layout: "not an object" } }, PLUGIN_ID), null)
  assert.strictEqual(Model.entryFor({ plugins: "not an array" }, PLUGIN_ID), null)
})

// ------------------------------------------------------------- ownEntryFromConfigText

test("ownEntryFromConfigText: valid entry in bar.layout", function () {
  var text = JSON.stringify({ version: 1, bar: { layout: { left: [{ id: PLUGIN_ID, repoLimit: 7 }] } } })
  var result = Model.ownEntryFromConfigText(text, PLUGIN_ID, 1048576)
  assert.deepStrictEqual(result, { entry: { id: PLUGIN_ID, repoLimit: 7 }, error: "" })
})

test("ownEntryFromConfigText: valid entry in plugins[]", function () {
  var text = JSON.stringify({ version: 1, plugins: [{ id: PLUGIN_ID, issuesFilter: "all" }] })
  var result = Model.ownEntryFromConfigText(text, PLUGIN_ID, 1048576)
  assert.deepStrictEqual(result, { entry: { id: PLUGIN_ID, issuesFilter: "all" }, error: "" })
})

test("ownEntryFromConfigText: missing own entry", function () {
  var text = JSON.stringify({ version: 1, bar: { layout: { left: [{ id: "other" }] } } })
  var result = Model.ownEntryFromConfigText(text, PLUGIN_ID, 1048576)
  assert.deepStrictEqual(result, { entry: null, error: "missing own entry" })
})

test("ownEntryFromConfigText: bare-string layout entry -- missing own entry", function () {
  var text = JSON.stringify({ version: 1, bar: { layout: { left: [PLUGIN_ID] } } })
  var result = Model.ownEntryFromConfigText(text, PLUGIN_ID, 1048576)
  assert.deepStrictEqual(result, { entry: null, error: "missing own entry" })
})

test("ownEntryFromConfigText: invalid JSON", function () {
  var result = Model.ownEntryFromConfigText("{not json", PLUGIN_ID, 1048576)
  assert.deepStrictEqual(result, { entry: null, error: "config invalid" })
})

test("ownEntryFromConfigText: top-level array is rejected", function () {
  var result = Model.ownEntryFromConfigText("[1,2,3]", PLUGIN_ID, 1048576)
  assert.deepStrictEqual(result, { entry: null, error: "config invalid" })
})

test("ownEntryFromConfigText: wrong version is rejected", function () {
  var text = JSON.stringify({ version: 2, plugins: [{ id: PLUGIN_ID }] })
  var result = Model.ownEntryFromConfigText(text, PLUGIN_ID, 1048576)
  assert.deepStrictEqual(result, { entry: null, error: "config invalid" })
})

test("ownEntryFromConfigText: missing version is rejected", function () {
  var text = JSON.stringify({ plugins: [{ id: PLUGIN_ID }] })
  var result = Model.ownEntryFromConfigText(text, PLUGIN_ID, 1048576)
  assert.deepStrictEqual(result, { entry: null, error: "config invalid" })
})

test("ownEntryFromConfigText: oversized text is rejected before parsing", function () {
  var text = JSON.stringify({ version: 1, plugins: [{ id: PLUGIN_ID }] })
  var result = Model.ownEntryFromConfigText(text, PLUGIN_ID, text.length - 1)
  assert.deepStrictEqual(result, { entry: null, error: "config too large" })
})

test("ownEntryFromConfigText: returned entry is a copy -- mutating it does not alter a second call", function () {
  var text = JSON.stringify({ version: 1, plugins: [{ id: PLUGIN_ID, repoLimit: 9 }] })
  var first = Model.ownEntryFromConfigText(text, PLUGIN_ID, 1048576)
  first.entry.repoLimit = 999
  first.entry.newKey = "mutated"
  var second = Model.ownEntryFromConfigText(text, PLUGIN_ID, 1048576)
  assert.strictEqual(second.entry.repoLimit, 9)
  assert.strictEqual(second.entry.newKey, undefined)
})

// ---------------------------------------------------------------------- mergedSettings

test("mergedSettings: merges a new/changed key onto the existing entry (does not drop other settings)", function () {
  var current = { id: "halmylyseas.github-status", dashboardIntervalSec: 240, repoLimit: 15 }
  var next = Model.mergedSettings(current, "repoSort", "stars")
  assert.deepStrictEqual(next, { dashboardIntervalSec: 240, repoLimit: 15, repoSort: "stars" })
})

test("mergedSettings: strips any incoming `id` key -- the host adds its own", function () {
  var current = { id: "old-id", repoSort: "activity" }
  var next = Model.mergedSettings(current, "repoSort", "stars")
  assert.strictEqual(next.id, undefined)
  assert.strictEqual(next.repoSort, "stars")
})

test("mergedSettings: defensive on missing/malformed `current`, never throws", function () {
  assert.deepStrictEqual(Model.mergedSettings(null, "repoSort", "stars"), { repoSort: "stars" })
  assert.deepStrictEqual(Model.mergedSettings(undefined, "repoSort", "stars"), { repoSort: "stars" })
  assert.deepStrictEqual(Model.mergedSettings("not an object", "repoSort", "stars"), { repoSort: "stars" })
})

test("mergedSettings: overwrites an existing value for the same key", function () {
  var current = { repoSort: "activity", repoLimit: 10 }
  var next = Model.mergedSettings(current, "repoSort", "stars")
  assert.strictEqual(next.repoSort, "stars")
  assert.strictEqual(next.repoLimit, 10)
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

// -------------------------------------------------------------------------- oldestSync

test("oldestSync: the min of two non-zero values", function () {
  assert.strictEqual(Model.oldestSync(1000, 2000), 1000)
  assert.strictEqual(Model.oldestSync(2000, 1000), 1000)
})

test("oldestSync: a single synced source (the other still 0) reports itself", function () {
  assert.strictEqual(Model.oldestSync(1500, 0), 1500)
  assert.strictEqual(Model.oldestSync(0, 1500), 1500)
})

test("oldestSync: both 0 (never synced) stays 0", function () {
  assert.strictEqual(Model.oldestSync(0, 0), 0)
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

// ------------------------------------------------ isSafeGithubUrl (adversarial)

test("isSafeGithubUrl: rejects the userinfo trick explicitly", function () {
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com@evil.com/"), false)
  assert.strictEqual(Model.isSafeGithubUrl("https://user:pass@github.com/o/r"), false)
})

test("isSafeGithubUrl: rejects a literal newline right after the required prefix", function () {
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/\n../evil"), false)
})

test("isSafeGithubUrl: rejects any control character or whitespace anywhere in the string", function () {
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/o/r\n"), false)
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/o/r\t/evil"), false)
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/o/r\r\nSet-Cookie: x"), false)
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/o r"), false)
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/o/r\x00trailing"), false)
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com/o/r\x7f"), false)
})

test("isSafeGithubUrl: rejects overlong urls, accepts right at the cap", function () {
  var prefix = "https://github.com/"
  var okAtCap = prefix + "a".repeat(2048 - prefix.length)
  assert.strictEqual(okAtCap.length, 2048)
  assert.strictEqual(Model.isSafeGithubUrl(okAtCap), true)
  assert.strictEqual(Model.isSafeGithubUrl(okAtCap + "a"), false)
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

test("classifyFailure: never-authenticated fresh install (exit 4 / \"please run: gh auth login\")", function () {
  var stderr = "To get started with GitHub CLI, please run:  gh auth login\n"
    + "Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token."
  assert.strictEqual(Model.classifyFailure(stderr, 4), "unauthenticated")
  // Whitespace-tolerant: real gh prints two spaces before `gh`, but the
  // classifier must not depend on that exact count.
  assert.strictEqual(Model.classifyFailure("please run: gh auth login", 4), "unauthenticated")
  assert.strictEqual(Model.classifyFailure("anything at all", 4), "unauthenticated")
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

test("classifyFailure: watchdog timeout (exit 124 / \"timed out\") reads as offline, not an API error", function () {
  assert.strictEqual(Model.classifyFailure("timed out", 124), "offline")
  assert.strictEqual(Model.classifyFailure("anything", 124), "offline")
})

test("classifyFailure: output-overflow kill (exit 137 / \"output limit exceeded\") stays a genuine API error", function () {
  assert.strictEqual(Model.classifyFailure("output limit exceeded", 137), "error")
})

// -------------------------------------------------------------------- apiErrorDetail

test("apiErrorDetail: extracts the HTTP status from a gh error line", function () {
  assert.strictEqual(Model.apiErrorDetail("gh: Server Error (HTTP 502)", 1), "HTTP 502")
})

test("apiErrorDetail: finds the HTTP status on a later line of multi-line stderr", function () {
  var stderr = "gh: request to api.github.com failed\ngh: Server Error (HTTP 503)\nretrying..."
  assert.strictEqual(Model.apiErrorDetail(stderr, 1), "HTTP 503")
})

test("apiErrorDetail: control characters stripped from oversized input, never exceeds 48 chars", function () {
  // Neither label template can realistically reach 48 chars for any real
  // exit code -- this is a defensive bound on oversized/control-laden
  // input, not a case where truncate()'s cap actually engages.
  var noisy = "gh: \x00\x01\x1b[31merror\x1b[0m " + "x".repeat(2048)
  var detail = Model.apiErrorDetail(noisy, 1)
  assert.ok(detail.length <= 48, "detail should never exceed 48 chars, got " + detail.length)
  assert.ok(!/[\x00-\x1f\x7f]/.test(detail), "detail must not contain control characters")
})

test("apiErrorDetail: no HTTP status falls back to the exit code", function () {
  assert.strictEqual(Model.apiErrorDetail("gh: mock generic failure", 1), "request failed (exit 1)")
})

test("apiErrorDetail: output-overflow kill (exit 137) reports \"response too large\"", function () {
  assert.strictEqual(Model.apiErrorDetail("output limit exceeded", 137), "response too large")
  assert.strictEqual(Model.apiErrorDetail("anything", 137), "response too large")
})

test("apiErrorDetail: non-string input never throws", function () {
  assert.doesNotThrow(function () { Model.apiErrorDetail(null, 1) })
  assert.doesNotThrow(function () { Model.apiErrorDetail(undefined, undefined) })
  assert.doesNotThrow(function () { Model.apiErrorDetail(42, "not a number") })
  assert.doesNotThrow(function () { Model.apiErrorDetail({}, null) })
  assert.strictEqual(Model.apiErrorDetail(null, 1), "request failed (exit 1)")
})

// -------------------------------------------------------------------- apiErrorSourceLabel

test("apiErrorSourceLabel: maps the three known sources to their display labels", function () {
  assert.strictEqual(Model.apiErrorSourceLabel("dashboard"), "dashboard")
  assert.strictEqual(Model.apiErrorSourceLabel("notifications"), "notifications")
  assert.strictEqual(Model.apiErrorSourceLabel("probe"), "sign-in check")
})

test("apiErrorSourceLabel: an unrecognized source passes through unchanged", function () {
  assert.strictEqual(Model.apiErrorSourceLabel("something-else"), "something-else")
  assert.strictEqual(Model.apiErrorSourceLabel(""), "")
})

test("apiErrorSourceLabel: non-string input never throws", function () {
  assert.doesNotThrow(function () { Model.apiErrorSourceLabel(null) })
  assert.doesNotThrow(function () { Model.apiErrorSourceLabel(undefined) })
  assert.doesNotThrow(function () { Model.apiErrorSourceLabel(42) })
  assert.strictEqual(Model.apiErrorSourceLabel(null), "")
  assert.strictEqual(Model.apiErrorSourceLabel(undefined), "")
})

// -------------------------------------------------------------------- gh version pin

test("SUPPORTED_GH_MAJORS: pinned exact literal (a mutated table must not pass its own test)", function () {
  assert.deepStrictEqual(Model.SUPPORTED_GH_MAJORS, [2])
})

test("parseGhVersion: real gh --version first line -> just the X.Y.Z segment", function () {
  assert.strictEqual(Model.parseGhVersion("gh version 2.98.0 (2026-08-20)\nhttps://cli.github.com"), "2.98.0")
  assert.strictEqual(Model.parseGhVersion("gh version 3.0.0 (2026-08-20)"), "3.0.0")
})

test("parseGhVersion: defensive on missing/malformed input, never throws", function () {
  assert.strictEqual(Model.parseGhVersion(""), "")
  assert.strictEqual(Model.parseGhVersion(null), "")
  assert.strictEqual(Model.parseGhVersion("command not found: gh"), "")
})

test("isGhVersionSupported: true only for a pinned major (patch/minor drift doesn't matter)", function () {
  assert.strictEqual(Model.isGhVersionSupported("2.98.0"), true)
  assert.strictEqual(Model.isGhVersionSupported("2.0.0"), true)
  assert.strictEqual(Model.isGhVersionSupported("2.98.0-beta"), true)
})

test("isGhVersionSupported: false for an unpinned major or unparsed input", function () {
  assert.strictEqual(Model.isGhVersionSupported("3.0.0"), false)
  assert.strictEqual(Model.isGhVersionSupported("1.9.0"), false)
  assert.strictEqual(Model.isGhVersionSupported(""), false)
  assert.strictEqual(Model.isGhVersionSupported(null), false)
  assert.strictEqual(Model.isGhVersionSupported("v2.98.0"), false)
})

// ---------------------------------------------------------------- parseHeadersAndBody

test("parseHeadersAndBody: real captured 200 notifications -i output", function () {
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

// --------------------------------------------------------------- DASHBOARD_QUERY

test("DASHBOARD_QUERY: pinned exact literal (G2 native rework -- was scripts/fetch-dashboard's heredoc)", function () {
  var expected = [
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
  assert.strictEqual(Model.DASHBOARD_QUERY, expected)
  assert.ok(Model.DASHBOARD_QUERY.indexOf("mutation") === -1, "never a mutation")
  assert.ok(Model.DASHBOARD_QUERY.indexOf("repositories(first: 30") >= 0, "repositories window pinned at 30")
  // reviewRequestsTotal is read off this field -- pin its presence the
  // same way the other three sections' totalCount is already pinned above.
  assert.ok(Model.DASHBOARD_QUERY.indexOf("    issueCount") >= 0, "reviewRequests search carries issueCount")
})

// -------------------------------------------------------------------- sanitizeEtag

test("sanitizeEtag: passes through an ordinary quoted etag unchanged", function () {
  assert.strictEqual(Model.sanitizeEtag('"abc123"'), '"abc123"')
})

test("sanitizeEtag: strips control characters and spaces", function () {
  assert.strictEqual(Model.sanitizeEtag('"abc\n123\t "'), '"abc123"')
})

test("sanitizeEtag: caps at 128 chars of safe content", function () {
  var huge = '"' + "a".repeat(500) + '"'
  var out = Model.sanitizeEtag(huge)
  assert.strictEqual(out.length, 128)
  assert.ok(/^[!-~]+$/.test(out))
})

test("sanitizeEtag: defensive on missing/non-string input", function () {
  assert.strictEqual(Model.sanitizeEtag(null), "")
  assert.strictEqual(Model.sanitizeEtag(undefined), "")
  assert.strictEqual(Model.sanitizeEtag(123), "")
})

// --------------------------------------------------------- isNotificationsBodyValid

test("isNotificationsBodyValid: true only for status 200 + array body", function () {
  assert.strictEqual(Model.isNotificationsBodyValid({ status: 200, body: [] }), true)
  assert.strictEqual(Model.isNotificationsBodyValid({ status: 200, body: [{ id: "1" }] }), true)
})

test("isNotificationsBodyValid: false on a malformed exit-0 envelope (C4)", function () {
  assert.strictEqual(Model.isNotificationsBodyValid({ status: 200, body: { message: "not an array" } }), false)
  assert.strictEqual(Model.isNotificationsBodyValid({ status: 200, body: null }), false)
  assert.strictEqual(Model.isNotificationsBodyValid({ status: 500, body: [] }), false)
  assert.strictEqual(Model.isNotificationsBodyValid(null), false)
  assert.strictEqual(Model.isNotificationsBodyValid(undefined), false)
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
