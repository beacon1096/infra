#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const fixtureDir = join(root, "utils/fixtures/observed-rollout");
const script = join(root, "utils/plan-observed-rollout.mjs");
const inventory = JSON.parse(readFileSync(join(fixtureDir, "inventory.json"), "utf8"));
const healthyPlan = JSON.parse(readFileSync(join(fixtureDir, "healthy-plan.json"), "utf8"));
let scenarioCount = 0;

function run(plan, inventoryValue = inventory) {
  scenarioCount += 1;
  const directory = mkdtempSync(join(tmpdir(), "observed-rollout-"));
  try {
    const planPath = join(directory, "plan.json");
    const inventoryPath = join(directory, "inventory.json");
    writeFileSync(planPath, JSON.stringify(plan));
    writeFileSync(inventoryPath, JSON.stringify(inventoryValue));
    const result = spawnSync(process.execPath, [script, "--plan", planPath, "--inventory", inventoryPath], { encoding: "utf8", timeout: 10000 });
    assert.ifError(result.error);
    return { status: result.status, output: JSON.parse(result.stdout) };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function clone(value) {
  return structuredClone(value);
}

function promoteCandidate(plan, prodSha = "3333333333333333333333333333333333333333") {
  plan.rollout.current_prod_sha = prodSha;
  plan.rollout.candidate_prod_sha = prodSha;
  plan.rollout.promotion_source_sha = plan.candidate_sha;
  plan.rollout.promotion_observed_at = "2026-10-15T22:34:10Z";
}

function bindForwardRecovery(plan, {
  sourceSha = "4444444444444444444444444444444444444444",
  prodSha = "5555555555555555555555555555555555555555",
  configurationSha256 = `sha256:${"6".repeat(64)}`,
} = {}) {
  plan.rollout.current_prod_sha = prodSha;
  plan.rollout.current_prod_observed_at = "2026-10-15T22:34:50Z";
  plan.rollout.forward_recovery = {
    source_sha: sourceSha,
    prod_sha: prodSha,
    promotion_source_sha: sourceSha,
    promotion_observed_at: "2026-10-15T22:34:40Z",
    configuration_evidence: {
      kind: "nixos-configuration-evaluation",
      method: "nix-eval-and-reviewed-diff",
      reviewed_by: "offline-fixture-reviewer",
      reference_prod_sha: plan.known_good_sha,
      recovery_source_sha: sourceSha,
      reference_sha256: configurationSha256,
      recovery_sha256: configurationSha256,
      reviewed_at: "2026-10-15T22:34:20Z",
      status: "verified",
    },
  };
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
}

function digest(value) {
  return `sha256:${createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
}

function blockerCodes(result) {
  return result.output.blockers.map(({ code }) => code);
}

function expectBlocked(name, plan, inventoryValue, code) {
  const result = run(plan, inventoryValue);
  assert.equal(result.status, 2, name);
  assert.equal(result.output.recommendation, "blocked", name);
  assert.equal(result.output.authorized, false, name);
  assert(blockerCodes(result).includes(code), `${name}: expected ${code}, got ${blockerCodes(result)}`);
  return result;
}

{
  const result = run(healthyPlan);
  assert.equal(result.status, 0);
  assert.equal(result.output.recommendation, "candidate-for-human-review");
  assert.equal(result.output.authorized, false);
  assert.deepEqual(result.output.impact.hosts, ["m920x", "microserver-gen10plus", "msi-claw", "surface-pro-8", "thinkbook-plus-hybrid"]);
  assert.equal(result.output.observations.length, 10);
  assert.equal(result.output.recovery.length, 5);
  assert.equal(result.output.rollout.stages[0].name, "pre-release-hold");
  assert.deepEqual(result.output.rollout.stages[0].held_hosts, ["microserver-gen10plus", "msi-claw", "surface-pro-8", "thinkbook-plus-hybrid"]);
  assert.equal(result.output.rollout.stages[0].actions.length, 12);
  assert.deepEqual(result.output.rollout.stages[0].actions.slice(0, 3).map(({ action }) => action), ["install-persistent-hold", "stop-service", "verify-persistent-hold"]);
  assert(result.output.rollout.stages[0].expected_revisions.every(({ prod_revision }) => prod_revision === healthyPlan.known_good_sha));
  assert.deepEqual(result.output.rollout.stages[1].expected_revisions.find(({ host }) => host === "m920x"), { host: "m920x", prod_revision: null, source_revision: healthyPlan.candidate_sha, state: "awaiting-exact-promotion-proof" });
  assert(result.output.rollout.stages[1].expected_revisions.filter(({ host }) => host !== "m920x").every(({ prod_revision }) => prod_revision === healthyPlan.known_good_sha));
  assert.deepEqual(result.output.rollout.stages[2].held_hosts, ["microserver-gen10plus", "msi-claw", "surface-pro-8", "thinkbook-plus-hybrid"]);
  assert.deepEqual(result.output.rollout.stages[2].actions, []);
  assert.equal(result.output.recovery[0].cleanup_before_prod_change.state, "prod-unchanged");
  assert.deepEqual(result.output.recovery[0].cleanup_before_prod_change.actions.map(({ action }) => action), ["remove-persistent-hold", "start-service", "verify-promotion"]);
  assert.equal(result.output.recovery[0].release_after_forward_recovery.state, "not-applicable");
  assert.deepEqual(result.output.recovery[0].release_after_forward_recovery.actions, []);
}

{
  const plan = clone(healthyPlan);
  promoteCandidate(plan);
  const result = run(plan);
  assert.equal(result.status, 0);
  assert.deepEqual(result.output.rollout.stages[1].expected_revisions.find(({ host }) => host === "m920x"), { host: "m920x", prod_revision: plan.rollout.candidate_prod_sha, source_revision: plan.candidate_sha, state: "candidate-promotion" });
  const remaining = result.output.rollout.stages[2];
  assert.deepEqual(remaining.actions.slice(0, 3).map(({ action }) => action), ["remove-persistent-hold", "start-service", "verify-promotion"]);
  for (const action of remaining.actions) {
    assert.equal(action.expected_prod_revision, plan.rollout.candidate_prod_sha);
    assert.equal(action.expected_source_revision, plan.candidate_sha);
    if (action.action === "start-service") assert.equal(action.expected_revision, plan.rollout.candidate_prod_sha);
  }
  assert.equal(result.output.recovery[0].cleanup_before_prod_change.state, "not-applicable");
  assert.deepEqual(result.output.recovery[0].cleanup_before_prod_change.actions, []);
  assert.deepEqual(result.output.recovery[0].release_after_forward_recovery.actions, []);
}

{
  const plan = clone(healthyPlan);
  promoteCandidate(plan);
  const result = run(plan);
  assert.equal(result.status, 0);

  let prodRevision = plan.known_good_sha;
  const hosts = new Map(result.output.impact.hosts.map((host) => [host, {
    active: true,
    hold_marker: false,
    hold_supported: true,
    prod_revision: plan.known_good_sha,
  }]));
  const activate = (state) => {
    if (state.hold_supported && state.hold_marker) state.active = false;
    else {
      state.active = true;
      state.prod_revision = prodRevision;
    }
  };
  const applyAction = (action, { failInstall = false } = {}) => {
    const state = hosts.get(action.host);
    if (action.action === "install-persistent-hold") {
      if (failInstall) return false;
      state.hold_marker = true;
    } else if (action.action === "stop-service") state.active = false;
    else if (action.action === "remove-persistent-hold") state.hold_marker = false;
    else if (action.action === "start-service") activate(state);
    else if (action.action === "activate-known-good-generation") {
      state.prod_revision = plan.known_good_sha;
      activate(state);
    } else if (action.action === "verify-persistent-hold") {
      assert.equal(state.hold_marker, true);
      assert.equal(state.active, false);
      assert.equal(state.prod_revision, plan.known_good_sha);
    }
    return true;
  };

  const preRelease = result.output.rollout.stages[0];
  const failedHost = preRelease.held_hosts[0];
  assert.equal(applyAction(preRelease.actions.find(({ host, action }) => host === failedHost && action === "install-persistent-hold"), { failInstall: true }), false);
  assert.equal(hosts.get(failedHost).hold_marker, false);
  assert.equal(prodRevision, plan.known_good_sha, "hold failure must stop before prod advances");

  for (const action of preRelease.actions) applyAction(action);
  prodRevision = plan.rollout.candidate_prod_sha;
  for (const host of plan.batches[0].hosts) activate(hosts.get(host));
  const held = hosts.get(failedHost);
  activate(held);
  assert.equal(held.active, false, "persistent marker must block Comin after peer reboot");
  assert.equal(held.prod_revision, plan.known_good_sha);

  held.prod_revision = plan.known_good_sha;
  activate(held);
  assert.equal(held.active, false, "known-good activation must retain the hold");

  const recovering = result.output.recovery.find(({ host }) => host === plan.batches[0].hosts[0]);
  for (const action of recovering.actions) applyAction(action);
  assert.equal(hosts.get(recovering.host).active, false, "recovery activation must not restart Comin while prod is candidate");
  assert.equal(hosts.get(recovering.host).prod_revision, plan.known_good_sha);

  const recoveryPlan = clone(plan);
  bindForwardRecovery(recoveryPlan);
  const recovered = run(recoveryPlan);
  assert.equal(recovered.status, 0);
  assert(recovered.output.rollout.stages.every(({ actions }) => actions.length === 0), "forward recovery must not regenerate candidate rollout actions");
  const release = recovered.output.recovery.find(({ host }) => host === recovering.host).release_after_forward_recovery;
  assert.equal(release.state, "verified-forward-promotion");
  prodRevision = recoveryPlan.rollout.forward_recovery.prod_sha;
  for (const action of release.actions) applyAction(action);
  assert.equal(hosts.get(recovering.host).active, true);
  assert.equal(hosts.get(recovering.host).prod_revision, recoveryPlan.rollout.forward_recovery.prod_sha);
  assert(preRelease.held_hosts.slice(1).every((host) => hosts.get(host).active === false && hosts.get(host).prod_revision === plan.known_good_sha), "unreleased peers must not advance early");
}

{
  const plan = clone(healthyPlan);
  promoteCandidate(plan);
  plan.rollout.forward_recovery.source_sha = "4444444444444444444444444444444444444444";
  const result = expectBlocked("partial forward recovery", plan, inventory, "incomplete-forward-recovery");
  assert(result.output.recovery.every(({ release_after_forward_recovery }) => release_after_forward_recovery.actions.length === 0));
}

for (const [name, mutate, code] of [
  ["wrong recovery Source-Commit", (plan) => { plan.rollout.forward_recovery.promotion_source_sha = plan.candidate_sha; }, "recovery-source-mismatch"],
  ["mismatched recovery configuration", (plan) => { plan.rollout.forward_recovery.configuration_evidence.recovery_sha256 = `sha256:${"7".repeat(64)}`; }, "recovery-configuration-mismatch"],
  ["unidentified recovery review", (plan) => { plan.rollout.forward_recovery.configuration_evidence.reviewed_by = ""; }, "invalid-recovery-configuration-evidence"],
  ["stale recovery configuration review", (plan) => { plan.rollout.forward_recovery.configuration_evidence.reviewed_at = "2026-09-01T00:00:00Z"; }, "stale-recovery-review"],
  ["old prod reused for recovery", (plan) => {
    plan.rollout.forward_recovery.prod_sha = plan.known_good_sha;
    plan.rollout.current_prod_sha = plan.known_good_sha;
  }, "invalid-recovery-promotion"],
  ["recovery prod observation mismatch", (plan) => { plan.rollout.current_prod_sha = plan.rollout.candidate_prod_sha; }, "current-prod-mismatch"],
]) {
  const plan = clone(healthyPlan);
  promoteCandidate(plan);
  bindForwardRecovery(plan);
  mutate(plan);
  const result = expectBlocked(name, plan, inventory, code);
  assert(result.output.recovery.every(({ release_after_forward_recovery }) => release_after_forward_recovery.actions.length === 0), `${name}: hold must remain`);
}

{
  const plan = clone(healthyPlan);
  promoteCandidate(plan);
  bindForwardRecovery(plan);
  plan.rollout.control_channel_status = "unavailable";
  const result = expectBlocked("forward recovery control channel failure", plan, inventory, "control-channel-unavailable");
  assert(result.output.recovery.every(({ release_after_forward_recovery }) => release_after_forward_recovery.actions.length === 0));
}

for (const [name, mutate, code] of [
  ["missing evidence", (plan) => plan.evidence.pop(), "missing-evidence"],
  ["stale evidence", (plan) => { plan.evidence[0].observed_at = "2026-10-15T20:00:00Z"; }, "stale-evidence"],
  ["future evidence", (plan) => { plan.evidence[0].observed_at = "2026-10-16T22:35:00Z"; }, "future-evidence"],
  ["wrong source", (plan) => { plan.evidence[0].source = "fixture/forged"; }, "evidence-source-mismatch"],
  ["wrong SHA", (plan) => { plan.evidence[0].sha = "3333333333333333333333333333333333333333"; }, "evidence-source-mismatch"],
  ["wrong repository", (plan) => { plan.repository = "infrastructure/infra"; }, "repository-not-deploy-source"],
  ["unknown status", (plan) => { delete plan.evidence[0].status; }, "missing-field"],
  ["unknown path", (plan) => { plan.changed_paths = ["unknown/change.nix"]; }, "unknown-path"],
  ["noncanonical path", (plan) => { plan.changed_paths = ["hosts/personal/fixed/m920x/../../common/nixos-configuration.nix"]; }, "invalid-changed-paths"],
  ["file suffix", (plan) => { plan.changed_paths[0] += ".unreviewed"; }, "unknown-path"],
  ["incomplete batches", (plan) => { plan.batches.pop(); }, "batch-impact-mismatch"],
  ["control stop missing", (plan) => { plan.stop_conditions = plan.stop_conditions.filter((item) => item !== "control-channel-unavailable"); }, "missing-stop-condition"],
  ["known-good mismatch", (plan) => { plan.recovery[0].known_good_sha = plan.candidate_sha; }, "recovery-revision-mismatch"],
  ["missing generation", (plan) => { delete plan.recovery[0].generation.store_path; }, "missing-field"],
  ["stale recovery", (plan) => { plan.recovery[0].verified_at = "2026-09-01T00:00:00Z"; }, "stale-recovery"],
]) {
  const plan = clone(healthyPlan);
  mutate(plan);
  expectBlocked(name, plan, inventory, code);
}

{
  const plan = clone(healthyPlan);
  plan.changed_paths = ["hosts/personal/fixed/m920x/disko.nix"];
  plan.batches = [{ name: "canary", hosts: ["m920x"], minimum_observation_seconds: 900 }];
  plan.evidence = plan.evidence.filter(({ host }) => host === "m920x");
  plan.recovery = plan.recovery.filter(({ host }) => host === "m920x");
  const result = expectBlocked("storage classification", plan, inventory, "separate-review-required");
  assert.deepEqual(result.output.separate_review_domains, ["storage"]);
}

{
  const plan = clone(healthyPlan);
  plan.changed_paths = ["hosts/personal/fixed/m920x/configuration.nix"];
  plan.batches = [{ name: "canary", hosts: ["m920x"], minimum_observation_seconds: 900 }];
  plan.evidence = plan.evidence.filter(({ host }) => host === "m920x");
  plan.recovery = plan.recovery.filter(({ host }) => host === "m920x");
  expectBlocked("broad host directory is not low risk", plan, inventory, "unclassified-risk");
}

{
  const changedInventory = clone(inventory);
  const rule = changedInventory.path_rules.find(({ prefix }) => prefix === "hosts/personal/fixed/m920x/");
  rule.hosts = [];
  rule.services = [];
  const plan = clone(healthyPlan);
  plan.changed_paths = ["hosts/personal/fixed/m920x/configuration.nix"];
  plan.evidence = [];
  plan.batches = [];
  plan.recovery = [];
  expectBlocked("empty impact", plan, changedInventory, "empty-runtime-impact");
}

{
  const changedInventory = clone(inventory);
  changedInventory.snapshot.sha = "3333333333333333333333333333333333333333";
  expectBlocked("inventory revision mismatch", healthyPlan, changedInventory, "inventory-source-mismatch");
}

{
  const changedInventory = clone(inventory);
  const shared = changedInventory.path_rules.find(({ shared }) => shared);
  shared.hosts = shared.hosts.slice(0, 2);
  const plan = clone(healthyPlan);
  plan.batches = shared.hosts.map((host, index) => ({ name: `batch-${index}`, hosts: [host], minimum_observation_seconds: 900 }));
  plan.evidence = plan.evidence.filter(({ host }) => shared.hosts.includes(host));
  plan.recovery = plan.recovery.filter(({ host }) => shared.hosts.includes(host));
  expectBlocked("truncated consumers", plan, changedInventory, "consumer-set-mismatch");
}

{
  const changedInventory = clone(inventory);
  for (const host of changedInventory.hosts) host.required_evidence = [{}];
  const plan = clone(healthyPlan);
  plan.evidence = plan.evidence.filter(({ kind }) => kind === "host-health");
  for (const entry of plan.evidence) { delete entry.kind; delete entry.source; }
  expectBlocked("undefined evidence contract", plan, changedInventory, "invalid-evidence-contract");
}

{
  const changedInventory = clone(inventory);
  changedInventory.hosts[0].recovery_channels[0].independent_of = ["comin"];
  expectBlocked("dependent recovery channel", healthyPlan, changedInventory, "dependent-recovery-channel");
}

{
  const changedInventory = clone(inventory);
  changedInventory.hosts[0].staged_delivery.state = "inactive";
  expectBlocked("Comin preflight not active", healthyPlan, changedInventory, "staged-delivery-not-ready");
}

{
  const changedInventory = clone(inventory);
  changedInventory.hosts[0].staged_delivery.hold_capability.ready = false;
  expectBlocked("persistent hold prerequisite not deployed", healthyPlan, changedInventory, "persistent-hold-not-ready");
}

{
  const changedInventory = clone(inventory);
  changedInventory.hosts[0].staged_delivery.hold_capability.candidate_source_revision = healthyPlan.base_source_sha;
  expectBlocked("candidate drops persistent hold support", healthyPlan, changedInventory, "persistent-hold-not-ready");
}

{
  const plan = clone(healthyPlan);
  plan.recovery[0].hold.support_revision = plan.candidate_sha;
  expectBlocked("recovery generation lacks known-good hold support", plan, inventory, "recovery-hold-mismatch");
}

{
  const plan = clone(healthyPlan);
  plan.rollout.control_channel_status = "unavailable";
  const result = expectBlocked("control channel failure", plan, inventory, "control-channel-unavailable");
  assert(result.output.rollout.stages.every(({ actions }) => actions.length === 0));
  assert(result.output.recovery.every(({ available, hold, actions, stop_service, generation }) => available === true && hold.marker_path === "/var/lib/comin/rollout-hold" && actions[0].action === "install-persistent-hold" && stop_service.args.join(" ") === "stop comin.service" && generation.executable.startsWith(generation.store_path)));
}

{
  const directory = mkdtempSync(join(tmpdir(), "observed-rollout-release-graph-"));
  const gitEnv = {
    ...process.env,
    GIT_AUTHOR_NAME: "Offline fixture",
    GIT_AUTHOR_EMAIL: "fixture@example.invalid",
    GIT_COMMITTER_NAME: "Offline fixture",
    GIT_COMMITTER_EMAIL: "fixture@example.invalid",
  };
  for (const key of Object.keys(gitEnv)) if (key.startsWith("GIT_CONFIG_")) delete gitEnv[key];
  const git = (...arguments_) => {
    const result = spawnSync("git", ["-c", "commit.gpgsign=false", ...arguments_], { cwd: directory, env: gitEnv, encoding: "utf8", timeout: 10000 });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  try {
    git("init", "--quiet");
    writeFileSync(join(directory, "service.txt"), "known-good\n");
    git("add", "service.txt");
    git("commit", "--quiet", "-m", "known-good source");
    const knownGoodSource = git("rev-parse", "HEAD");
    const knownGoodTree = git("rev-parse", "HEAD^{tree}");
    const knownGoodProd = git("commit-tree", knownGoodTree, "-m", `release good\n\nSource-Commit: ${knownGoodSource}`);

    writeFileSync(join(directory, "service.txt"), "candidate\n");
    git("add", "service.txt");
    git("commit", "--quiet", "-m", "candidate source");
    const candidateSource = git("rev-parse", "HEAD");
    const candidateProd = git("commit-tree", git("rev-parse", "HEAD^{tree}"), "-p", knownGoodProd, "-m", `release candidate\n\nSource-Commit: ${candidateSource}`);
    const rejectedOldSource = spawnSync("git", ["merge-base", "--is-ancestor", candidateSource, knownGoodSource], { cwd: directory, env: gitEnv, encoding: "utf8", timeout: 10000 });
    assert.ifError(rejectedOldSource.error);
    assert.equal(rejectedOldSource.status, 1, "release ancestry guard must reject republishing the historical source");

    writeFileSync(join(directory, "service.txt"), "known-good\n");
    git("add", "service.txt");
    git("commit", "--quiet", "-m", "forward recovery source");
    const recoverySource = git("rev-parse", "HEAD");
    git("merge-base", "--is-ancestor", candidateSource, recoverySource);
    assert.equal(git("rev-parse", "HEAD^{tree}"), knownGoodTree);
    const recoveryProd = git("commit-tree", knownGoodTree, "-p", candidateProd, "-m", `release recovery\n\nSource-Commit: ${recoverySource}`);
    assert.notEqual(recoveryProd, knownGoodProd, "forward recovery must produce a new prod promotion identity");

    const replacements = new Map([
      [healthyPlan.base_source_sha, knownGoodSource],
      [healthyPlan.known_good_sha, knownGoodProd],
      [healthyPlan.candidate_sha, candidateSource],
    ]);
    const replaceFixtureRevisions = (value) => JSON.parse(JSON.stringify(value, (key, entry) => replacements.get(entry) ?? entry));
    const plan = replaceFixtureRevisions(healthyPlan);
    const inventoryValue = replaceFixtureRevisions(inventory);
    inventoryValue.attestation.scope_sha256 = digest({ hosts: inventoryValue.hosts, path_rules: inventoryValue.path_rules });
    promoteCandidate(plan, candidateProd);
    bindForwardRecovery(plan, { sourceSha: recoverySource, prodSha: recoveryProd, configurationSha256: digest({ evaluated_tree: knownGoodTree }) });
    const result = run(plan, inventoryValue);
    assert.equal(result.status, 0);
    const release = result.output.recovery[0].release_after_forward_recovery;
    assert.equal(release.state, "verified-forward-promotion");
    assert(release.actions.every(({ expected_prod_revision }) => expected_prod_revision === recoveryProd));
    assert(release.actions.every(({ expected_source_revision }) => expected_source_revision === recoverySource));
    assert.notEqual(release.prod_revision, knownGoodProd);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

process.stdout.write(`observed rollout planner: ${scenarioCount} planner scenarios passed\n`);
