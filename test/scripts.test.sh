#!/usr/bin/env bash
# test/scripts.test.sh -- runs scripts/fetch-dashboard, scripts/fetch-notifications,
# and scripts/probe-auth with `gh` shadowed on PATH by test/mocks/gh, asserting
# exit codes and output shapes against the fixtures under test/fixtures/.
# Plain assertions, no framework. Exits 0 if every check passes, 1 otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"
MOCKS="$SCRIPT_DIR/mocks"

fail_count=0
pass_count=0

ok() {
  pass_count=$((pass_count + 1))
  echo "ok - $1"
}

not_ok() {
  fail_count=$((fail_count + 1))
  echo "NOT OK - $1"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc"
  else
    not_ok "$desc (expected [$expected], got [$actual])"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$desc"
  else
    not_ok "$desc (expected to find [$needle])"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$desc"
  else
    not_ok "$desc (expected NOT to find [$needle])"
  fi
}

# ------------------------------------------------------------- fetch-dashboard

out="$(PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/fetch-dashboard")"
code=$?
assert_eq "fetch-dashboard exits 0 against mock" "0" "$code"
expected_dashboard="$(cat "$FIXTURES/mega-graphql.json")"
assert_eq "fetch-dashboard stdout matches mega-graphql fixture" "$expected_dashboard" "$out"

# Assert on the query actually sent to `gh`, not just the script's source
# text: test/mocks/gh's graphql branch discards stdin by default, so a
# regression in the repositories() window (e.g. `first: 30` -> `first: 20`)
# would pass every check above -- the mock always serves the same fixture
# regardless of what query it received. MOCK_GH_GRAPHQL_QUERY_FILE makes the
# mock capture stdin to a file instead so we can inspect it here.
query_capture_dir="$(mktemp -d)"
trap 'rm -rf "$query_capture_dir"' EXIT
query_capture_file="$query_capture_dir/graphql-query.txt"
MOCK_GH_GRAPHQL_QUERY_FILE="$query_capture_file" PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/fetch-dashboard" >/dev/null
code=$?
assert_eq "fetch-dashboard (query capture) exits 0" "0" "$code"
sent_query="$(cat "$query_capture_file")"
assert_contains "fetch-dashboard sends repositories(first: 30, ...) as the actual query" "$sent_query" 'repositories(first: 30, ownerAffiliations: OWNER'
assert_not_contains "fetch-dashboard query contains no mutation token" "$sent_query" "mutation"

# --------------------------------------------------------- fetch-notifications

out="$(PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/fetch-notifications")"
code=$?
assert_eq "fetch-notifications (no etag) exits 0" "0" "$code"
assert_contains "fetch-notifications (no etag) includes 200 status line" "$out" "HTTP/2.0 200 OK"
assert_contains "fetch-notifications (no etag) includes Etag header" "$out" 'Etag: "mock-etag-v1"'

out="$(PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/fetch-notifications" '"mock-etag-v1"')"
code=$?
assert_eq "fetch-notifications (matching etag) exits 1 (gh's 304 exit)" "1" "$code"
assert_contains "fetch-notifications (matching etag) includes 304 status line" "$out" "HTTP/2.0 304 Not Modified"

err="$(PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/fetch-notifications" '"mock-etag-v1"' 2>&1 >/dev/null)"
assert_contains "fetch-notifications (matching etag) stderr says gh: HTTP 304" "$err" "gh: HTTP 304"

out="$(PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/fetch-notifications" '"a-different-etag"')"
code=$?
assert_eq "fetch-notifications (non-matching etag) still exits 0" "0" "$code"
assert_contains "fetch-notifications (non-matching etag) gets a fresh 200" "$out" "HTTP/2.0 200 OK"

# -------------------------------------------------------------------- probe-auth

out="$(GH_MOCK_MODE=ok PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/probe-auth")"
code=$?
assert_eq "probe-auth (ok) exits 0" "0" "$code"
assert_eq "probe-auth (ok) prints the login" "HalmyLyseas" "$out"

GH_MOCK_MODE=unauth PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/probe-auth" >/dev/null 2>&1
code=$?
assert_eq "probe-auth (unauth) exits 4" "4" "$code"

GH_MOCK_MODE=offline PATH="$MOCKS:$PATH" "$PLUGIN_DIR/scripts/probe-auth" >/dev/null 2>&1
code=$?
assert_eq "probe-auth (offline) exits 5" "5" "$code"

# No-gh case: a PATH with no `gh` binary at all (mocks dir excluded, and this
# machine's real gh -- under mise -- is not on this minimal PATH either).
PATH="/usr/bin:/bin" "$PLUGIN_DIR/scripts/probe-auth" >/dev/null 2>&1
code=$?
assert_eq "probe-auth (no gh on PATH) exits 3" "3" "$code"

# ------------------------------------------------------------------- summary

echo
echo "$pass_count passed, $fail_count failed"
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
exit 0
