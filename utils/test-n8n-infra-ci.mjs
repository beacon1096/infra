import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);

const workflow = JSON.parse(
  fs.readFileSync(
    new URL("../wanxiang/kubernetes/apps/development/n8n/app/infra-ci.workflow.json", import.meta.url),
    "utf8",
  ),
)[0];
const nodes = new Map(workflow.nodes.map((node) => [node.name, node]));
const secret = "review-capability-secret-used-only-for-tests";
const event = {
  REPO: "infrastructure/infra",
  PR_NUMBER: "7",
  PR_HEAD_SHA: "0123456789abcdef0123456789abcdef01234567",
};

assert.equal(nodes.size, workflow.nodes.length, "node names must be unique");
assert.equal(
  new Set(workflow.nodes.map((node) => node.id)).size,
  workflow.nodes.length,
  "node IDs must be unique",
);
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
    Buffer,
    Date,
    require,
    ...context,
  });

const authenticated = execute("Authenticate Forgejo Webhook", {
  $json: { headers: { authorization: "Bearer webhook-secret" } },
  $env: { FORGEJO_WEBHOOK_CREDENTIAL: "webhook-secret" },
});
assert.deepEqual(authenticated.json.headers, { authorization: "Bearer webhook-secret" });
assert.throws(() =>
  execute("Authenticate Forgejo Webhook", {
    $json: { headers: { authorization: "Bearer wrong" } },
    $env: { FORGEJO_WEBHOOK_CREDENTIAL: "webhook-secret" },
  }),
);

const normalized = execute("Normalize Forgejo Event", {
  $json: {
    headers: { "x-forgejo-event": "pull_request" },
    body: {
      action: "synchronize",
      repository: { full_name: "infrastructure/infra" },
      sender: { login: "human-reviewer" },
      pull_request: {
        number: 7,
        user: { login: "renovate" },
        head: { sha: event.PR_HEAD_SHA },
        base: { ref: "main" },
      },
    },
  },
  $execution: { id: "test-execution" },
}).json;
assert.equal(normalized.ACTOR, "human-reviewer");
assert.equal(normalized.PR_AUTHOR, "renovate");
assert.equal(normalized.IS_RENOVATE_PR, true);

const capability = execute("Create Review Capability", {
  $: () => ({ first: () => ({ json: event }) }),
  $env: { REVIEW_CAPABILITY_SECRET: secret },
}).json.REVIEW_CAPABILITY;

const validate = (candidate, verdict = "approve") =>
  execute("Validate Multica Review", {
    $json: {
      body: {
        capability: candidate,
        verdict,
        summary: "reviewed",
        evidence_url: "https://multica.beaco.works/issues/BEACO-1",
      },
    },
    $env: { REVIEW_CAPABILITY_SECRET: secret },
  }).json;

const valid = validate(capability);
assert.equal(valid.REVIEW_VALID, true);
assert.equal(valid.REPO, event.REPO);
assert.equal(valid.PR_NUMBER, Number(event.PR_NUMBER));
assert.equal(valid.HEAD_SHA, event.PR_HEAD_SHA);
assert.equal(validate(capability, "human_required").REVIEW_VALID, true);
assert.equal(validate(capability, "unknown").REVIEW_VALID, false);

const [encoded, signature] = capability.split(".");
const tamperedSignature = `${signature[0] === "A" ? "B" : "A"}${signature.slice(1)}`;
assert.equal(validate(`${encoded}.${tamperedSignature}`).REVIEW_VALID, false);

const expiredClaims = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
expiredClaims.iat -= 86401;
expiredClaims.exp -= 86401;
const expiredEncoded = Buffer.from(JSON.stringify(expiredClaims)).toString("base64url");
const expiredSignature = crypto
  .createHmac("sha256", secret)
  .update(expiredEncoded)
  .digest("base64url");
assert.equal(validate(`${expiredEncoded}.${expiredSignature}`).REVIEW_VALID, false);

const merge = nodes.get("Merge Approved Renovate PR");
assert.equal(merge.credentials.httpHeaderAuth.id, "multicaMerger01");
const mergeFields = Object.fromEntries(
  merge.parameters.bodyParameters.parameters.map((field) => [field.name, field.value]),
);
assert.equal(mergeFields.force_merge, undefined);
assert.equal(mergeFields.merge_when_checks_succeed, true);
assert.match(mergeFields.head_commit_id, /HEAD_SHA/);

const reviewStatus = nodes.get("Set Multica Review Status");
const reviewStatusFields = Object.fromEntries(
  reviewStatus.parameters.bodyParameters.parameters.map((field) => [field.name, field.value]),
);
assert.match(reviewStatusFields.state, /human_required|pending/);

const approvalCondition = nodes.get("Multica Review Approved")
  .parameters.conditions.conditions[0];
assert.equal(approvalCondition.rightValue, "approve");

console.log("n8n infra CI workflow checks passed");
