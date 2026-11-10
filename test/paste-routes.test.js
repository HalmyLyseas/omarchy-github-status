const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");
const panel = readFileSync(join(root, "Panel.qml"), "utf8");
const job = readFileSync(join(root, "PasteJob.qml"), "utf8");

test("every native paste route in the search field is replaced", () => {
    assert.match(panel, /Keys\.priority: Keys\.BeforeItem/);
    assert.match(panel, /Qt\.Key_V/);
    assert.match(panel, /Qt\.Key_Insert/);
    assert.match(panel, /Qt\.Key_Paste/);
    assert.match(panel, /acceptedButtons: Qt\.MiddleButton/);
    assert.match(panel, /event\.accepted = true/);
    assert.match(panel, /pasteJob\.paste\(true\)/);
    assert.match(panel, /positionAt\(mouse\.x, mouse\.y\)/);
    assert.match(panel, /ContextMenu\.menu: Menu/);
    assert.match(panel, /text: "Paste"[\s\S]{0,200}pasteJob\.paste\(false\)/);
    assert.match(panel, /Model\.pasteQuery/);
    assert.match(panel, /pasteJob\.cancel\(\)/);
    assert.doesNotMatch(panel, /PasteAction/);
    assert.doesNotMatch(panel, /TextEditingContextMenu/);
});

test("the clipboard job is bounded, deadlined and killable", () => {
    assert.match(job, /maxChars/);
    assert.match(job, /timeoutMs/);
    assert.match(job, /splitMarker: ""/);
    assert.match(job, /signal\(15\)/);
    assert.match(job, /signal\(9\)/);
    assert.match(job, /"\/usr\/bin\/wl-paste"/);
});
