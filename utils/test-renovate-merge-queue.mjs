import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const workflow = JSON.parse(fs.readFileSync(
  new URL("../wanxiang/kubernetes/apps/development/n8n/app/renovate-merge-queue.workflow.json", import.meta.url),
  "utf8",
))[0];
const nodes = new Map(workflow.nodes.map((node) => [node.name, node]));

assert.equal(nodes.size, workflow.nodes.length);
assert.equal(new Set(workflow.nodes.map((node) => node.id)).size, workflow.nodes.length);
for (const [source, outputs] of Object.entries(workflow.connections)) {
  assert(nodes.has(source), `missing connection source: ${source}`);
  for (const output of outputs.main ?? []) {
    for (const connection of output) {
      assert(nodes.has(connection.node), `missing connection target: ${connection.node}`);
    }
  }
}

const execute = (name, context) =>
  vm.runInNewContext(`(function () { ${nodes.get(name).parameters.jsCode} })()`, {
    require,
    ...context,
  });

const queueItem = {
  repo: "infrastructure/infra",
  pr_number: 50,
  approved_head_sha: "1".repeat(40),
  approved_base_sha: "2".repeat(40),
  delta_digest: "",
  delta_count: 1,
};
const currentHead = "3".repeat(40);
const currentBase = "4".repeat(40);
const decide = (body, statusCode = 200) => execute("Decide Queue Action", {
  $json: { statusCode, body },
  $: () => ({ first: () => ({ json: queueItem }) }),
}).json;
assert.equal(decide({
  state: "open",
  merged: false,
  user: { login: "renovate" },
  base: { ref: "main", sha: currentBase },
  head: { sha: currentHead },
  merge_base: "5".repeat(40),
}).ACTION, "update");
assert.equal(decide({
  state: "open",
  merged: false,
  user: { login: "renovate" },
  base: { ref: "main", sha: currentBase },
  head: { sha: currentHead },
  merge_base: currentBase,
}).ACTION, "snapshot");
assert.equal(decide({ merged: true }).ACTION, "merged");
assert.equal(decide({ state: "open", user: { login: "not-renovate" } }).ACTION, "block");

const entry = (path, sha) => ({ path, mode: "100644", type: "blob", sha });
const baseBlob = "6".repeat(40);
const headBlob = "7".repeat(40);
const delta = [{ path: "flake.lock", base: { mode: "100644", type: "blob", sha: baseBlob }, head: { mode: "100644", type: "blob", sha: headBlob } }];
queueItem.delta_digest = crypto.createHash("sha256").update(JSON.stringify(delta)).digest("hex");
const verifyDelta = (baseTree, headTree, truncated = false) => execute("Verify Queued Tree Delta", {
  $: (name) => ({
    first: () => ({
      json: name === "Decide Queue Action"
        ? queueItem
        : { statusCode: 200, body: { truncated, tree: name === "Get Current Queue Base Tree" ? baseTree : headTree } },
    }),
  }),
}).json;
assert.equal(verifyDelta([entry("flake.lock", baseBlob)], [entry("flake.lock", headBlob)]).DELTA_MATCHES, true);
assert.equal(verifyDelta([entry("flake.lock", baseBlob)], [entry("flake.lock", "8".repeat(40))]).DELTA_MATCHES, false);
assert.equal(verifyDelta([], [], true).DELTA_MATCHES, false);

const claim = nodes.get("Claim Renovate Queue Item");
assert.equal(claim.credentials.postgres.id, "reviewCapabilityPg");
assert.match(claim.parameters.query, /FOR UPDATE SKIP LOCKED/);
assert.match(claim.parameters.query, /lease_until = now\(\) \+ interval '45 seconds'/);
assert.match(claim.parameters.query, /ORDER BY approved_at/);

for (const name of ["Update Queued Renovate PR", "Merge Queued Renovate PR"]) {
  assert.equal(nodes.get(name).credentials.httpHeaderAuth.id, "multicaMerger01");
}
assert.match(nodes.get("Update Queued Renovate PR").parameters.url, /pulls.*update/);
const mergeFields = Object.fromEntries(nodes.get("Merge Queued Renovate PR")
  .parameters.bodyParameters.parameters.map((field) => [field.name, field.value]));
assert.equal(mergeFields.force_merge, undefined);
assert.equal(mergeFields.merge_when_checks_succeed, false);
assert.match(mergeFields.head_commit_id, /CURRENT_HEAD_SHA/);
assert.match(nodes.get("Record Queued Merge Result").parameters.query, /405, 409/);
assert.match(nodes.get("Record Queued Merge Result").parameters.query, /approval_jti::text/);
assert.equal(nodes.get("Get Queued Multica Dispatch").credentials.postgres.id, "reviewCapabilityPg");
const verifyMulticaRun = nodes.get("Verify Queued Multica Run").parameters.jsCode;
assert.match(verifyMulticaRun, /run\.id.*dispatch\.run_id/s);
assert.match(verifyMulticaRun, /run\.autopilot_id.*dispatch\.autopilot_id/s);
assert.doesNotMatch(verifyMulticaRun, /run\.status|completed/);
for (const name of ["Get Queued Multica Run", "Complete Queued Multica Issue"]) {
  assert.equal(nodes.get(name).credentials.httpHeaderAuth.id, "multicaCloser01");
}
assert.match(nodes.get("Complete Queued Multica Issue").parameters.jsonBody, /status: 'done'/);
assert.deepEqual(
  workflow.connections["Queue Merge Completed"].main.map((branch) =>
    branch.map(({ node }) => node)),
  [["Get Queued Multica Dispatch"], []],
);

const freshReview = nodes.get("Request Fresh Multica Review");
assert.equal(freshReview.parameters.method, "POST");
assert.match(freshReview.parameters.url, /^http:\/\/n8n:5678\/webhook/);
assert.match(freshReview.parameters.body, /action: 'synchronize'/);
assert.match(freshReview.parameters.body, /Get Queued Renovate PR/);
assert.match(
  JSON.stringify(freshReview.parameters.headerParameters),
  /FORGEJO_WEBHOOK_CREDENTIAL/,
);
assert.match(
  JSON.stringify(freshReview.parameters.headerParameters),
  /pull_request_review_merge_queue_rerequested/,
);
assert.deepEqual(
  workflow.connections["Block Changed Queue Delta"].main[0].map(({ node }) => node),
  ["Request Fresh Multica Review"],
);
assert.match(nodes.get("Block Changed Queue Delta").parameters.query, /approval_jti::text/);
assert.equal(nodes.get("Get Superseded Multica Dispatch").credentials.postgres.id, "reviewCapabilityPg");
for (const name of ["Get Superseded Multica Run", "Cancel Superseded Multica Issue"]) {
  assert.equal(nodes.get(name).credentials.httpHeaderAuth.id, "multicaCloser01");
}
assert.match(nodes.get("Cancel Superseded Multica Issue").parameters.jsonBody, /status: 'cancelled'/);
assert.deepEqual(
  workflow.connections["Request Fresh Multica Review"].main[0].map(({ node }) => node),
  ["Get Superseded Multica Dispatch"],
);

const renovate = JSON.parse(fs.readFileSync(new URL("../renovate.json", import.meta.url)));
const miseRule = renovate.packageRules.find((rule) => rule.matchManagers?.includes("mise"));
assert.equal(miseRule.groupName, "mise toolchain dependencies");

const kustomization = fs.readFileSync(new URL(
  "../wanxiang/kubernetes/apps/development/n8n/app/kustomization.yaml",
  import.meta.url,
), "utf8");
const helmRelease = fs.readFileSync(new URL(
  "../wanxiang/kubernetes/apps/development/n8n/app/helmrelease.yaml",
  import.meta.url,
), "utf8");
assert.match(kustomization, /renovate-merge-queue\.json=renovate-merge-queue\.workflow\.json/);
assert.match(helmRelease, /import:workflow --input=\/workflows\/renovate-merge-queue\.json/);
assert.match(helmRelease, /publish:workflow --id=renovateMergeQueue01/);
assert.match(helmRelease, /path: \/workflows\/renovate-merge-queue\.json/);
assert.match(helmRelease, /subPath: renovate-merge-queue\.json/);

console.log("Renovate merge queue workflow checks passed");
