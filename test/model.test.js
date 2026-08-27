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

// ---------------------------------------------- apiUrlToWebUrl (adversarial, S5a F1)

test("apiUrlToWebUrl: shell-metacharacter-shaped trailing content is rejected (exchange/11-s5a-security-review.md F1)", function () {
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

test("mapNotifications: per-field string length is capped (exchange/11-s5a-security-review.md F2)", function () {
  var hugeTitle = new Array(1024 * 1024 + 2).join("x")   // ~1MB
  var hugeReason = new Array(10000).join("y")
  var hugeRepo = new Array(10000).join("z")
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, reason: hugeReason, subject: { title: hugeTitle, url: "" }, repository: { full_name: hugeRepo, html_url: "https://github.com/" + new Array(5000).join("w") } }
  ])
  assert.strictEqual(mapped[0].title.length, Model.FIELD_CAP_TEXT)
  assert.strictEqual(mapped[0].title, hugeTitle.slice(0, Model.FIELD_CAP_TEXT))
  assert.strictEqual(mapped[0].reason.length, Model.FIELD_CAP_TAG)
  assert.strictEqual(mapped[0].repo.length, Model.FIELD_CAP_TAG)
  assert.ok(mapped[0].webUrl.length <= Model.FIELD_CAP_URL)
})

test("mapNotifications: never evals title content even if it looks like code", function () {
  var payload = "'; global.__pwned = true; ('"
  var mapped = Model.mapNotifications([
    { id: "1", unread: true, subject: { title: payload, url: "" }, repository: { full_name: "o/r" } }
  ])
  assert.strictEqual(mapped[0].title, payload)
  assert.strictEqual(global.__pwned, undefined)
})

// ------------------------------------------------- mapNotifications: F6 (own vs external)

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
  assert.strictEqual(pr.repo, "omacom-io/omarchy-site")
  assert.strictEqual(pr.number, 77)
  assert.strictEqual(pr.webUrl, "https://github.com/omacom-io/omarchy-site/pull/77")
  assert.strictEqual(pr.isDraft, false)
  // statusCheckRollup was null in the real captured sample -- a legitimate
  // empty state (no CI configured), not a query bug (see 04-github-data.md #3).
  assert.strictEqual(pr.ciState, "none")
  assert.strictEqual(pr.reviewDecision, "")
  // F6: this PR is against a fork of a third-party repo (omacom-io), not
  // the account's (HalmyLyseas) own -- a real live example of an external
  // PR row, not a fabricated one.
  assert.strictEqual(pr.owner, "omacom-io")
  assert.strictEqual(pr.isExternal, true)

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

  // F2: the live archived-repo acceptance fixture -- flows through
  // completely unfiltered (no isArchived query arg anywhere), pill-flagged.
  var archivedRepo = mapped.repos.filter(function (r) { return r.name === "VandalHearts-decomp-SLPM-86007" })[0]
  assert.ok(archivedRepo, "expected the archived VandalHearts-decomp repo in mapped repos -- must not be filtered out")
  assert.strictEqual(archivedRepo.isArchived, true)
  assert.strictEqual(Model.repoPill(archivedRepo), "archived")

  var forkRepo = mapped.repos.filter(function (r) { return r.name === "omarchy-site" })[0]
  assert.strictEqual(forkRepo.isFork, true)
  assert.strictEqual(Model.repoPill(forkRepo), "fork")

  // F3: the acceptance fixture issue -- authored by this account, in a repo
  // it does not own, MUST appear in myIssues.
  assert.strictEqual(mapped.myIssues.length, raw.data.viewer.myIssues.nodes.length)
  var marketplaceIssue = mapped.myIssues.filter(function (i) { return i.number === 2672 })[0]
  assert.ok(marketplaceIssue, "expected HANCORE-linux/omarchy-plugin-marketplace#2672 in myIssues")
  assert.strictEqual(marketplaceIssue.repo, "HANCORE-linux/omarchy-plugin-marketplace")
  assert.strictEqual(marketplaceIssue.webUrl, "https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/2672")
  assert.strictEqual(marketplaceIssue.owner, "HANCORE-linux")
  assert.strictEqual(marketplaceIssue.isExternal, true)
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

test("mapDashboard: non-object / malformed input returns all-null per-section shape (nothing usable -- caller must not replace last-good data), never throws", function () {
  // Per exchange/12-s5b-correctness-review.md F4, a section is `null` (not
  // []) when it did not resolve at all -- that's the explicit "don't
  // replace" signal the Service layer relies on. An envelope with no
  // usable `data` at all (these cases) means all three sections are null.
  var allNull = { openPRs: null, reviewRequests: null, repos: null, myIssues: null }
  assert.deepStrictEqual(Model.mapDashboard(null), allNull)
  assert.deepStrictEqual(Model.mapDashboard(undefined), allNull)
  assert.deepStrictEqual(Model.mapDashboard("not json"), allNull)
  assert.deepStrictEqual(Model.mapDashboard(42), allNull)
  assert.deepStrictEqual(Model.mapDashboard([]), allNull)
  assert.deepStrictEqual(Model.mapDashboard({}), allNull)
  assert.deepStrictEqual(Model.mapDashboard({ data: null }), allNull)
  assert.deepStrictEqual(Model.mapDashboard({ data: { viewer: null, reviewRequests: null } }), allNull)
})

// ------------------------------------------- mapDashboard partial-GraphQL (S5b F4)

test("mapDashboard: partial envelope (data present for some sections, errors for others) keeps the sections that parsed, nulls the rest", function () {
  // Realistic shape: reviewRequests (via GraphQL `search`, its own stricter
  // rate-limit bucket) errored out; openPRs/repositories still resolved in
  // the same envelope, alongside a top-level `errors` array.
  var partial = {
    data: {
      viewer: {
        login: "me",
        openPRs: { nodes: [{ title: "Fix bug", url: "https://github.com/o/r/pull/1", number: 1, updatedAt: "2026-01-01T00:00:00Z", repository: { nameWithOwner: "o/r" } }] },
        repositories: { nodes: [{ name: "r" }] }
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
})

test("mapDashboard: fully-successful envelope with a coexisting (unrelated/empty) errors array still maps every section", function () {
  var mapped = Model.mapDashboard({
    data: {
      viewer: { login: "me", openPRs: { nodes: [] }, repositories: { nodes: [] }, myIssues: { nodes: [] } },
      reviewRequests: { nodes: [] }
    },
    errors: []
  })
  assert.deepStrictEqual(mapped, { openPRs: [], reviewRequests: [], repos: [], myIssues: [] })
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

test("mapDashboard: tolerates non-array `nodes` fields", function () {
  var mapped = Model.mapDashboard({
    data: {
      viewer: { openPRs: { nodes: "not an array" }, repositories: { nodes: null }, myIssues: { nodes: 7 } },
      reviewRequests: { nodes: 42 }
    }
  })
  assert.deepStrictEqual(mapped, { openPRs: [], reviewRequests: [], repos: [], myIssues: [] })
})

test("mapDashboard: per-field string length is capped (exchange/11-s5a-security-review.md F2)", function () {
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
  assert.strictEqual(mapped.openPRs[0].title.length, Model.FIELD_CAP_TEXT)
  assert.strictEqual(mapped.openPRs[0].repo.length, Model.FIELD_CAP_TAG)
  assert.ok(mapped.openPRs[0].webUrl.length <= Model.FIELD_CAP_URL)
  assert.strictEqual(mapped.openPRs[0].reviewDecision.length, Model.FIELD_CAP_TAG)
  // `owner` is derived from the (already-capped) `repo` field, so it is
  // naturally bounded too -- no separate cap needed, just proof it doesn't
  // explode past the repo field's own cap.
  assert.ok(mapped.openPRs[0].owner.length <= Model.FIELD_CAP_TAG)
  assert.strictEqual(mapped.reviewRequests[0].title.length, Model.FIELD_CAP_TEXT)
  assert.strictEqual(mapped.repos[0].name.length, Model.FIELD_CAP_TAG)
  assert.strictEqual(mapped.repos[0].releaseTag.length, Model.FIELD_CAP_TAG)
  assert.strictEqual(mapped.repos[0].lastCommitHeadline.length, Model.FIELD_CAP_TEXT)
  assert.strictEqual(mapped.myIssues[0].title.length, Model.FIELD_CAP_TEXT)
  assert.strictEqual(mapped.myIssues[0].repo.length, Model.FIELD_CAP_TAG)
  assert.ok(mapped.myIssues[0].webUrl.length <= Model.FIELD_CAP_URL)
  assert.ok(mapped.myIssues[0].owner.length <= Model.FIELD_CAP_TAG)
})

// ---------------------------------------------------- mapDashboard: repos F1/F2 fields

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

test("isExternalOwner: case-insensitive comparison (exchange/19-feedback-delta-spec.md F6)", function () {
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

test("repoPill: priority order archived > fork > private (exchange/19-feedback-delta-spec.md F2), one pill max", function () {
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

// ---------------------------------------------------------------------- sortRepos

function fakeRepo(name, pushedAt, stars) {
  return { name: name, pushedAt: pushedAt, stars: stars }
}

test("sortRepos: activity mode sorts by pushedAt desc (default mode)", function () {
  var repos = [
    fakeRepo("old", "2026-01-01T00:00:00Z", 0),
    fakeRepo("newest", "2026-08-27T00:00:00Z", 0),
    fakeRepo("middle", "2026-04-01T00:00:00Z", 0)
  ]
  var sorted = Model.sortRepos(repos, "activity")
  assert.deepStrictEqual(sorted.map(function (r) { return r.name }), ["newest", "middle", "old"])
})

test("sortRepos: stars mode sorts by stars desc, ties broken by pushedAt desc", function () {
  var repos = [
    fakeRepo("low-old", "2026-01-01T00:00:00Z", 5),
    fakeRepo("high", "2026-02-01T00:00:00Z", 100),
    fakeRepo("tie-newer", "2026-06-01T00:00:00Z", 5),
    fakeRepo("tie-older", "2026-03-01T00:00:00Z", 5)
  ]
  var sorted = Model.sortRepos(repos, "stars")
  assert.deepStrictEqual(sorted.map(function (r) { return r.name }), ["high", "tie-newer", "tie-older", "low-old"])
})

test("sortRepos: unrecognized mode falls back to activity, default (undefined) mode too", function () {
  var repos = [fakeRepo("old", "2026-01-01T00:00:00Z", 999), fakeRepo("new", "2026-08-01T00:00:00Z", 1)]
  assert.deepStrictEqual(Model.sortRepos(repos, "bogus-mode").map(function (r) { return r.name }), ["new", "old"])
  assert.deepStrictEqual(Model.sortRepos(repos, undefined).map(function (r) { return r.name }), ["new", "old"])
})

test("sortRepos: does not mutate the input array, returns a new array", function () {
  var repos = [fakeRepo("a", "2026-01-01T00:00:00Z", 1), fakeRepo("b", "2026-02-01T00:00:00Z", 2)]
  var original = repos.slice()
  var sorted = Model.sortRepos(repos, "stars")
  assert.deepStrictEqual(repos, original, "input array must be untouched")
  assert.notStrictEqual(sorted, repos, "must return a new array, not the same reference")
})

test("sortRepos: adversarial -- huge star values, missing/malformed pushedAt, non-array input, never throws", function () {
  var repos = [
    fakeRepo("huge", "2026-01-01T00:00:00Z", Number.MAX_SAFE_INTEGER),
    fakeRepo("no-pushed-at", undefined, 3),
    fakeRepo("bad-date", "not a date", 3),
    { name: "no-stars-field", pushedAt: "2026-05-01T00:00:00Z" }
  ]
  var sorted = Model.sortRepos(repos, "stars")
  assert.strictEqual(sorted.length, 4)
  assert.strictEqual(sorted[0].name, "huge")
  assert.deepStrictEqual(Model.sortRepos(null, "activity"), [])
  assert.deepStrictEqual(Model.sortRepos(undefined, "stars"), [])
  assert.deepStrictEqual(Model.sortRepos("not an array", "activity"), [])
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

// ------------------------------------------------ isSafeGithubUrl (adversarial, S5a F1)

test("isSafeGithubUrl: rejects the userinfo trick explicitly (exchange/11-s5a-security-review.md F1(c))", function () {
  assert.strictEqual(Model.isSafeGithubUrl("https://github.com@evil.com/"), false)
  assert.strictEqual(Model.isSafeGithubUrl("https://user:pass@github.com/o/r"), false)
})

test("isSafeGithubUrl: rejects a literal newline right after the required prefix (exchange/11-s5a-security-review.md F1, MUST-cover case)", function () {
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
  var okAtCap = prefix + "a".repeat(Model.FIELD_CAP_URL - prefix.length)
  assert.strictEqual(okAtCap.length, Model.FIELD_CAP_URL)
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
