const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");
const assert = require("node:assert/strict");

const root = join(__dirname, "..");
const workflow = readFileSync(join(root, ".github/workflows/test.yml"), "utf8");
const localGate = readFileSync(join(root, "test/ci-local"), "utf8");

test("CI pins the exact Omarchy 4.0.5 shell tree", () => {
    assert.match(workflow, /--branch v4\.0\.5 https:\/\/github\.com\/basecamp\/omarchy\.git/);
    assert.match(workflow, /GHS_SHELL_TREE: \/tmp\/omarchy\/shell/);
    assert.match(workflow, /OMARCHY_PLUGIN_VALIDATOR: \/tmp\/omarchy\/bin\/omarchy-plugin-validate/);
    assert.doesNotMatch(workflow, /pacman -Swdd/);
});

test("local gate prefers Qt 6 qmllint and accepts a shell-tree override", () => {
    assert.match(localGate, /GHS_SHELL_TREE:-/);
    assert.match(localGate, /QMLLINT_BIN=\/usr\/lib\/qt6\/bin\/qmllint/);
    assert.match(localGate, /Qt 6 qmllint not found/);
    assert.match(localGate, /OMARCHY_PLUGIN_VALIDATOR/);
});

test("UI and scoped-settings probes share the selected shell tree", () => {
    for (const file of ["test/probe/run-ui", "test/probe/run-scoped-settings"]) {
        const source = readFileSync(join(root, file), "utf8");
        assert.match(source, /GHS_SHELL_TREE:-\/usr\/share\/omarchy\/shell/);
        assert.match(source, /ln -sfn "\$SHELL_TREE"/);
    }
    const probe = readFileSync(join(root, "test/probe/scoped-settings-probe.qml"), "utf8");
    assert.match(probe, /Quickshell\.env\("GHS_SHELL_TREE"\)/);
});
