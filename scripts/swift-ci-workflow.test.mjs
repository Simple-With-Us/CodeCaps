// Contract for the Swift CI compile gate (.github/workflows/swift-ci.yml).
//
// The hosted macOS compile gate is what the release gate waits on.  Two
// things about it are pinned here:  the concurrency group, and who is
// allowed to replace a cancelled compile run.
//
// The concurrency group used to be one group per ref, so every later merge
// to main cancelled the compile run that the release gate was waiting on.
// The group is now one per commit and per event, so a push to main and a
// workflow_dispatch at the same commit land in different groups.  That
// separation matters twice over:  neither cancels the other, and the
// replacement run the release gate starts is not serialised behind the run
// it replaces.
//
// The second contract is the replacement itself.  Only the Mac release
// gate may replace a cancelled compile run.  The iOS ship gate cannot, so
// there a cancelled run has to fail the gate at once instead of polling
// for a run that will never arrive.
//
// Run: node --test scripts/swift-ci-workflow.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

function read(rel) {
  return readFileSync(join(ROOT, rel), "utf8");
}

function withoutComments(text) {
  return text
    .split("\n")
    .filter((line) => !/^\s*#/.test(line))
    .join("\n");
}

/** GitHub's format('{0}-{1}', a, b). */
function fmt(template, ...args) {
  return template.replace(/\{(\d+)\}/g, (_match, index) => String(args[Number(index)]));
}

/**
 * Evaluate a GitHub Actions setting against one context.
 *
 * Only the pieces the workflows use are supported:  the github context
 * fields, equality, and the logical operators.  That is enough to ask what
 * a workflow would really do, instead of reading the expression and
 * guessing.
 */
function evaluate(value, context) {
  const match = value.match(/^([\s\S]*?)\$\{\{([\s\S]*?)\}\}([\s\S]*)$/);
  if (!match) return value;
  const [, prefix, body, suffix] = match;
  const js = body
    .replace(/github\.event_name/g, "ctx.event_name")
    .replace(/github\.ref/g, "ctx.ref")
    .replace(/github\.sha/g, "ctx.sha")
    .replace(/\bformat\(/g, "fmt(")
    .replace(/==/g, "===");
  // eslint-disable-next-line no-new-func
  const result = new Function("ctx", "fmt", `return (${js});`)(context, fmt);
  return `${prefix}${result}${suffix}`;
}

function concurrencySetting(workflow, key) {
  const match = workflow.match(new RegExp(`^ {2}${key}:\\s*(.+)$`, "m"));
  assert.ok(match, `swift-ci.yml must declare concurrency.${key}`);
  return match[1].trim();
}

const swiftCi = read(".github/workflows/swift-ci.yml");
const groupExpression = concurrencySetting(swiftCi, "group");
const cancelExpression = concurrencySetting(swiftCi, "cancel-in-progress");

const PUSH_MAIN = {
  event_name: "push",
  ref: "refs/heads/main",
  sha: "1111111111111111111111111111111111111111",
};
const DISPATCH_MAIN = {
  event_name: "workflow_dispatch",
  ref: "refs/heads/main",
  sha: "1111111111111111111111111111111111111111",
};
const PULL_REQUEST = {
  event_name: "pull_request",
  ref: "refs/pull/42/merge",
  sha: "1111111111111111111111111111111111111111",
};

test("a push to main and a workflow_dispatch at the same commit get different groups", () => {
  const pushGroup = evaluate(groupExpression, PUSH_MAIN);
  const dispatchGroup = evaluate(groupExpression, DISPATCH_MAIN);
  assert.notEqual(
    pushGroup,
    dispatchGroup,
    "the release gate replaces a cancelled run with a workflow_dispatch, so the two must not share a group",
  );
  assert.ok(pushGroup.includes(PUSH_MAIN.sha), "a push group must carry the commit");
  assert.ok(dispatchGroup.includes(DISPATCH_MAIN.sha), "a dispatch group must carry the commit");
});

test("two pushes to main get one group each, so merges never serialise", () => {
  const first = evaluate(groupExpression, PUSH_MAIN);
  const second = evaluate(groupExpression, { ...PUSH_MAIN, sha: "2222222222222222222222222222222222222222" });
  assert.notEqual(first, second, "two merges must not share a group");
  assert.equal(evaluate(groupExpression, PUSH_MAIN), first, "the same commit gets the same group");
});

test("a pull request keeps one group per ref, so a new push cancels the old run", () => {
  const first = evaluate(groupExpression, PULL_REQUEST);
  const second = evaluate(groupExpression, { ...PULL_REQUEST, sha: "3333333333333333333333333333333333333333" });
  assert.equal(first, second, "a pull request group must not carry the commit");
  assert.ok(first.includes("42"), "a pull request group must carry the ref");
});

test("only a pull request cancels the run that is still going", () => {
  assert.equal(evaluate(cancelExpression, PULL_REQUEST), "true");
  assert.equal(evaluate(cancelExpression, PUSH_MAIN), "false");
  assert.equal(evaluate(cancelExpression, DISPATCH_MAIN), "false");
});

test("the compile gate still checks the Mac package and the iOS companion", () => {
  const code = withoutComments(swiftCi);
  assert.match(code, /name: Mac package build and test/);
  assert.match(code, /name: iOS companion compile/);
  assert.match(code, /runs-on: macos-latest/);
});

test("only the Mac release gate may replace a cancelled compile run", () => {
  const release = withoutComments(read(".github/workflows/mac-release.yml"));
  const ship = withoutComments(read(".github/workflows/ios-ship.yml"));

  // The release gate replaces the run, so it opts in and it needs the
  // permission to re-run a workflow.
  assert.match(release, /REDISPATCH_ON_CANCEL:\s*'1'/);
  assert.match(release, /actions: write/);
  assert.match(release, /await-swift-ci-checks\.sh/);

  // The iOS ship gate cannot replace it, so a cancelled run has to fail
  // the gate at once instead of polling for a run that never arrives.
  assert.doesNotMatch(ship, /REDISPATCH_ON_CANCEL/);
  assert.match(ship, /await-swift-ci-checks\.sh/);
});

test("the gate script documents the exit codes it actually returns", () => {
  const script = read("scripts/await-swift-ci-checks.sh");
  const header = script.split("set -euo pipefail")[0];
  assert.match(header, /Exit 0 when every named check's newest github-actions run succeeded\./);
  assert.match(header, /Exit 1 on a failed or skipped check, on a timeout, and on a cancelled/);
  assert.match(header, /check when REDISPATCH_ON_CANCEL is 0\./);
  assert.match(header, /Exit 2 when ONCE or CHECKS_JSON sees a check that has not finished\./);
  // The old text promised a failure on a cancelled check in every case.
  assert.doesNotMatch(header, /Exit 1 on a failed, skipped, or cancelled check/);
});

test("the gate replaces a cancelled run by re-running it, not by dispatching a sha", () => {
  const script = read("scripts/await-swift-ci-checks.sh");
  // The dispatch endpoint takes a branch or tag name and answers a commit
  // sha with "No ref found", so the gate re-runs the workflow run the
  // cancelled check belonged to instead.
  assert.match(script, /actions\/runs\/\$\{eligible_run_id\}\/rerun/);
  assert.doesNotMatch(script, /actions\/workflows\/.*\/dispatches/);
  assert.doesNotMatch(script, /-f ref=/);
});
