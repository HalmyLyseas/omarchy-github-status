#!/usr/bin/env node
// test/host-contract.mjs -- pins the host facade API this plugin's settings
// adapter depends on. Read-only, never writes or spawns a mutating command;
// skips cleanly when the shell tree is entirely absent.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const SHELL_TREE = process.env.GHS_SHELL_TREE || "/usr/share/omarchy/shell";

function skip(reason) {
  console.log(`SKIP: ${reason}`);
  process.exit(0);
}

if (!existsSync(SHELL_TREE)) {
  skip(`shell tree not found at ${SHELL_TREE} (set GHS_SHELL_TREE to override)`);
}

const failures = [];
let checks = 0;

function assertContains(path, needle, why) {
  checks++;
  const lines = readFileSync(path, "utf8").split("\n");
  const idx = lines.findIndex(l => l.includes(needle));
  if (idx === -1) {
    failures.push(`${path}: expected to find ${JSON.stringify(needle)} (${why}) -- host API changed`);
  } else {
    console.log(`ok - ${path}:${idx + 1} contains ${JSON.stringify(needle)}`);
  }
}

function assertNotContains(path, needle, why) {
  checks++;
  const lines = readFileSync(path, "utf8").split("\n");
  const idx = lines.findIndex(l => l.includes(needle));
  if (idx !== -1) {
    failures.push(`${path}:${idx + 1}: must not contain ${JSON.stringify(needle)} (${why})`);
  } else {
    console.log(`ok - ${path} does not contain ${JSON.stringify(needle)}`);
  }
}

// Scans a fixed-size window after `anchor` rather than the whole file, so a
// same-named member defined elsewhere in a large file can never satisfy it.
function assertContainsAfter(path, anchor, needle, why) {
  checks++;
  const text = readFileSync(path, "utf8");
  const anchorIdx = text.indexOf(anchor);
  if (anchorIdx === -1) {
    failures.push(`${path}: expected to find ${JSON.stringify(anchor)} (${why}) -- host API changed`);
    return;
  }
  const window = text.slice(anchorIdx, anchorIdx + 4000);
  if (!window.includes(needle)) {
    failures.push(`${path}: expected ${JSON.stringify(needle)} near ${JSON.stringify(anchor)} (${why}) -- host API changed`);
  } else {
    console.log(`ok - ${path} contains ${JSON.stringify(needle)} after ${JSON.stringify(anchor)}`);
  }
}

const shellApi = join(SHELL_TREE, "services/PluginShellApi.qml");
const shellQml = join(SHELL_TREE, "shell.qml");

if (!existsSync(shellApi)) {
  failures.push(`${shellApi}: missing -- the scoped plugin facade no longer ships with Omarchy`);
  checks++;
} else {
  assertContains(shellApi, "function serviceFor(", "Panel.qml/BarWidget.qml resolve their own service by id");
  assertContains(shellApi, "function updateEntryInline(", "Service.qml persists settings through this");
  assertNotContains(shellApi, "property var shellConfig",
    "the scoped facade must stay capability-limited -- a shellConfig property would silently widen every host back onto the legacy full-config read");
}

if (!existsSync(shellQml)) {
  failures.push(`${shellQml}: missing -- Omarchy's shell entry point moved`);
  checks++;
} else {
  assertContains(shellQml, "function updateEntryInline(moduleName, settings)", "the host's own settings-write entry point");
  assertContainsAfter(shellQml, "function updateEntryInline(moduleName, settings)", "var next = { id: stripped }",
    "the whole-entry replace this plugin's Model.mergedSettings guards against");
}

console.log("");
if (failures.length > 0) {
  console.log(`test/host-contract.mjs: ${failures.length} FAILURE(S) of ${checks} checks`);
  failures.forEach(f => console.log(`  ${f}`));
  process.exit(1);
}
console.log(`test/host-contract.mjs: ${checks} checks ok`);
process.exit(0);
