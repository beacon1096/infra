#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const fixtureDir = join(root, "utils/fixtures/observed-rollout");
const script = join(root, "utils/plan-observed-rollout.mjs");
const inventory = JSON.parse(readFileSync(join(fixtureDir, "inventory.json"), "utf8"));
const healthyPlan = JSON.parse(readFileSync(join(fixtureDir, "healthy-plan.json"), "utf8"));

function run(plan, inventoryValue = inventory) {
  const directory = mkdtempSync(join(tmpdir(), "observed-rollout-"));
  const planPath = join(directory, "plan.json");
  const inventoryPath = join(directory, "inventory.json");
  writeFileSync(planPath, JSON.stringify(plan));
  writeFileSync(inventoryPath, JSON.stringify(inventoryValue));
  const result = spawnSync(process.execPath, [script, "--plan", planPath, "--inventory", inventoryPath], { encoding: "utf8" });
  return { status: result.status, output: JSON.parse(result.stdout) };
}

function clone(value) {
  return structuredClone(value);
}

function blockerCodes(result) {
  return result.output.blockers.map(({ code }) => code);
}

{
  const result = run(healthyPlan);
  assert.equal(result.status, 0);
  assert.equal(result.output.recommendation, "candidate-for-human-review");
  assert.equal(result.output.authorized, false);
  assert.deepEqual(result.output.impact.hosts, ["m920x", "microserver-gen10plus", "msi-claw", "surface-pro-8", "thinkbook-plus-hybrid"]);
  assert.deepEqual(result.output.batches[0].hosts, ["m920x"]);
  assert.equal(result.output.observations.length, 10);
  assert(result.output.observations.every(({ observed_at }) => observed_at === "2026-10-15T22:34:00Z"));
}

for (const [name, mutate, code] of [
  ["missing evidence", (plan) => plan.evidence.pop(), "missing-evidence"],
  ["stale evidence", (plan) => { plan.evidence[0].observed_at = "2026-10-15T20:00:00Z"; }, "stale-evidence"],
  ["future evidence", (plan) => { plan.evidence[0].observed_at = "2026-10-16T22:35:00Z"; }, "future-evidence"],
  ["wrong source", (plan) => { plan.evidence[0].source = "fixture/forged"; }, "evidence-source-mismatch"],
  ["wrong SHA", (plan) => { plan.evidence[0].sha = "3333333333333333333333333333333333333333"; }, "evidence-source-mismatch"],
  ["wrong repository", (plan) => { plan.repository = "infrastructure/infra"; }, "repository-not-deploy-source"],
  ["unknown status", (plan) => { delete plan.evidence[0].status; }, "unknown-evidence"],
  ["unknown path", (plan) => { plan.changed_paths = ["unknown/change.nix"]; }, "unknown-path"],
  ["incomplete batches", (plan) => { plan.batches.pop(); }, "batch-impact-mismatch"],
  ["control channel stop missing", (plan) => { plan.stop_conditions = plan.stop_conditions.filter((item) => item !== "control-channel-unavailable"); }, "missing-stop-condition"],
]) {
  const plan = clone(healthyPlan);
  mutate(plan);
  const result = run(plan);
  assert.equal(result.status, 2, name);
  assert(blockerCodes(result).includes(code), `${name}: expected ${code}, got ${blockerCodes(result)}`);
}

{
  const plan = clone(healthyPlan);
  plan.changed_paths = ["hosts/personal/fixed/microserver-gen10plus/disko.nix"];
  const result = run(plan);
  assert.equal(result.status, 2);
  assert(blockerCodes(result).includes("separate-review-required"));
  assert.deepEqual(result.output.separate_review_domains, ["storage"]);
}

{
  const changedInventory = clone(inventory);
  changedInventory.snapshot.sha = "3333333333333333333333333333333333333333";
  const result = run(healthyPlan, changedInventory);
  assert.equal(result.status, 2);
  assert(blockerCodes(result).includes("inventory-source-mismatch"));
}

{
  const changedInventory = clone(inventory);
  changedInventory.path_rules.find(({ shared }) => shared).hosts = ["m920x"];
  const plan = clone(healthyPlan);
  plan.batches = [{ name: "canary", hosts: ["m920x"] }];
  plan.evidence = plan.evidence.filter(({ host }) => host === "m920x");
  const result = run(plan, changedInventory);
  assert.equal(result.status, 2);
  assert(blockerCodes(result).includes("invalid-shared-impact"));
}

{
  const changedInventory = clone(inventory);
  delete changedInventory.hosts[0].independent_recovery;
  const result = run(healthyPlan, changedInventory);
  assert.equal(result.status, 2);
  assert(blockerCodes(result).includes("missing-independent-recovery"));
}

process.stdout.write("observed rollout planner: 15 scenarios passed\n");
