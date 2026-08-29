#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const modelSource = readFileSync(join(__dirname, "..", "Model.js"), "utf8");
const modelExports = { exports: {} };
new Function("module", "exports", modelSource)(modelExports, modelExports.exports);
const Model = modelExports.exports;

function skip(reason) {
  console.log(`SKIP: ${reason}`);
  process.exit(0);
}

function readOnly(args) {
  const result = spawnSync("gh", args, { encoding: "utf8", timeout: 15000 });
  return {
    error: result.error,
    status: result.status,
    stdout: String(result.stdout || ""),
    stderr: String(result.stderr || "")
  };
}

const version = readOnly(["--version"]);
if (version.error?.code === "ENOENT") skip("gh CLI is not installed");
assert.equal(version.status, 0, "gh --version failed");
const ghVersion = Model.parseGhVersion(version.stdout);
assert.ok(
  Model.isGhVersionSupported(ghVersion),
  `installed gh CLI ${ghVersion || "(unparsed)"} is not a pinned major ` +
  `[${Model.SUPPORTED_GH_MAJORS.join(", ")}] -- a gh upgrade needs Model.SUPPORTED_GH_MAJORS updated`
);

// Everything past this point needs a signed-in gh; CI has the CLI (from
// `extra`) but no credentials, so this half skips cleanly there.
const auth = readOnly(["auth", "status"]);
if (auth.status !== 0) skip("gh is not authenticated (gh auth status failed)");

const login = readOnly(["api", "user", "--jq", ".login"]);
assert.equal(login.status, 0, `gh api user --jq .login failed: ${login.stderr.trim()}`);
const loginName = login.stdout.trim();
assert.ok(loginName.length > 0, "gh api user --jq .login returned an empty string");

console.log(`halmylyseas.github-status read-only gh CLI contract: ok (gh ${ghVersion})`);
