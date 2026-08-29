const { readFileSync } = require("node:fs");
const { execFileSync } = require("node:child_process");
const { join, extname, basename } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

// Keeps every shipped file's comments short and free of internal project-log
// references, since this tree is public. Scans git ls-files (excluding
// fixtures and preview.png, inert captured data/binary, not authored prose).
const ROOT = join(__dirname, "..");

function shippedFiles() {
  const out = execFileSync("git", ["ls-files"], { cwd: ROOT, encoding: "utf8" });
  // .github/** would be CI-only infra, never installed on or run by a user's
  // machine -- exempt from this scan the same way docs/threat-model.md
  // documents, if this repo ever gains one.
  return out.split("\n").filter(Boolean)
    .filter(f => !f.startsWith("test/fixtures/") && f !== "preview.png")
    .filter(f => !f.startsWith(".github/"));
}

// A comment "run" is any stretch of consecutive whole-comment lines, bare
// "//"/"#" separators included (a reader sees one block); only a non-comment
// line ends it. Shebangs are skipped; Markdown is prose and exempt.
function commentRuns(file, text) {
  if (extname(file) === ".md") return [];
  const lines = text.split("\n");
  const runs = [];
  let start = -1, len = 0;
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    const isShebang = i === 0 && trimmed.startsWith("#!");
    const marker = trimmed.startsWith("//") ? "//" : trimmed.startsWith("#") ? "#" : null;
    const isComment = !isShebang && marker !== null;
    if (isComment) {
      if (len === 0) start = i;
      len++;
    } else {
      if (len > 0) runs.push({ start: start + 1, len });
      len = 0;
    }
  }
  if (len > 0) runs.push({ start: start + 1, len });
  return runs;
}

// Forbidden-token scan runs over comment text only (whole document for
// markdown) -- never code or string literals, so incidental matches in data
// or test fixtures can never trip it.
const STAGE_ID = /\b[SNCDFRTGHAB][0-9]{1,2}\b(?=[\s:;,.)\]/]|$)/;
const FORBIDDEN = [
  { name: "exchange/", re: /exchange\// },
  { name: "scratchpad", re: /scratchpad/ },
  { name: "stage/finding id reference", re: STAGE_ID },
  { name: '"the human"', re: /\bthe human\b/ },
  { name: '"PM"', re: /\bPM\b/ },
  { name: "Fable", re: /\bFable\b/ },
  { name: "Sonnet", re: /\bSonnet\b/ },
  { name: "codex", re: /(?<!openai-)\bcodex\b/i },
  { name: "measured on this box", re: /measured (live )?on this box/ },
  { name: "project date", re: /\b202\d-\d{2}-\d{2}\b/ }
];

function commentText(file, text) {
  if (extname(file) === ".md") return text;
  if (basename(file) === "LICENSE") return "";
  const lines = text.split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    const isShebang = i === 0 && trimmed.startsWith("#!");
    if (!isShebang && (trimmed.startsWith("//") || trimmed.startsWith("#"))) out.push(lines[i]);
  }
  return out.join("\n");
}

function mdParagraphsMentioningExchange(file, text) {
  if (extname(file) !== ".md") return [];
  return text.split(/\n\s*\n/).filter(p => p.includes("exchange/"));
}

test("no comment run exceeds 3 lines", () => {
  const violations = [];
  for (const file of shippedFiles()) {
    const text = readFileSync(join(ROOT, file), "utf8");
    for (const run of commentRuns(file, text)) {
      if (run.len > 3) violations.push(`${file}:${run.start} run of ${run.len} lines`);
    }
  }
  assert.deepEqual(violations, [], `comment runs > 3 lines:\n${violations.join("\n")}`);
});

test("no forbidden project-log token in any shipped file", () => {
  const violations = [];
  for (const file of shippedFiles()) {
    const text = readFileSync(join(ROOT, file), "utf8");
    const comments = commentText(file, text);
    for (const { name, re } of FORBIDDEN) {
      if (re.test(comments)) violations.push(`${file}: forbidden token ${name}`);
    }
  }
  assert.deepEqual(violations, [], `forbidden tokens found:\n${violations.join("\n")}`);
});

test("no markdown paragraph mentions exchange/", () => {
  const violations = [];
  for (const file of shippedFiles()) {
    const text = readFileSync(join(ROOT, file), "utf8");
    for (const paragraph of mdParagraphsMentioningExchange(file, text)) {
      violations.push(`${file}: paragraph mentions exchange/: ${paragraph.slice(0, 80)}`);
    }
  }
  assert.deepEqual(violations, [], `markdown paragraphs mentioning exchange/:\n${violations.join("\n")}`);
});
