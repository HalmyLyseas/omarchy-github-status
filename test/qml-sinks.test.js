const { readFileSync, readdirSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

// Every local Text{} sink must be textFormat: Text.PlainText, since remote/
// GitHub-sourced strings are rendered there. Scoped to each Text{}'s own
// brace-matched body, since id/anchors routinely precede text/textFormat.
test("every local QML Text sink is explicitly plain text", () => {
    const root = join(__dirname, "..");
    for (const file of readdirSync(root).filter(name => name.endsWith(".qml"))) {
        const lines = readFileSync(join(root, file), "utf8").split("\n");
        for (let i = 0; i < lines.length; i++) {
            if (!/\bText\s*\{/.test(lines[i])) continue;
            const openIdx = lines[i].indexOf("{");
            let depth = 0;
            for (let c = openIdx; c < lines[i].length; c++) {
                if (lines[i][c] === "{") depth++;
                else if (lines[i][c] === "}") depth--;
            }
            const body = [];
            let j = i + 1;
            while (depth > 0 && j < lines.length) {
                body.push(lines[j]);
                for (let c = 0; c < lines[j].length; c++) {
                    if (lines[j][c] === "{") depth++;
                    else if (lines[j][c] === "}") depth--;
                }
                j++;
            }
            assert.match(body.join("\n"), /textFormat:\s*Text\.PlainText/, `${file}:${i + 1}`);
        }
    }
});

test("QML palette references use the Qt 6.12-safe Commons namespace", () => {
    const root = join(__dirname, "..");
    const offenders = [];
    const missingImports = [];
    for (const file of readdirSync(root).filter(name => name.endsWith(".qml"))) {
        const source = readFileSync(join(root, file), "utf8");
        source.split(/\r?\n/).forEach((line, index) => {
            if (/(^|[^A-Za-z_.])Color\./.test(line))
                offenders.push(`${file}:${index + 1}: ${line.trim()}`);
        });
        if (source.includes("Commons.Color.") && !source.includes("import qs.Commons as Commons"))
            missingImports.push(file);
    }
    assert.deepEqual(offenders, [],
        "Qt 6.12 shadows the unqualified Color singleton; import qs.Commons as Commons and use Commons.Color");
    assert.deepEqual(missingImports, [],
        "files using Commons.Color must import qs.Commons as Commons");
});

test("bar tooltip does not claim an empty inbox while the service is loading", () => {
    const source = readFileSync(join(__dirname, "..", "BarWidget.qml"), "utf8");
    assert.match(source, /status === "loading"[\s\S]{0,80}GitHub Status — loading/);
});
