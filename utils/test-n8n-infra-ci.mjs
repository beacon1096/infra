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

const humanReviewEvent = execute("Normalize Forgejo Event", {
  $json: {
    headers: {
      "x-forgejo-event": "pull_request",
      "x-forgejo-event-type": "pull_request_review_approved",
    },
    body: {
      action: "reviewed",
      review: { id: 10, type: "approved" },
      repository: { full_name: "infrastructure/infra" },
      sender: { login: "beacon1096" },
      pull_request: {
        number: 8,
        user: { login: "contributor" },
        head: { sha: event.PR_HEAD_SHA },
        base: { ref: "main" },
      },
    },
  },
  $execution: { id: "human-review-execution" },
}).json;
assert.equal(humanReviewEvent.SUPPORTED, true);
assert.equal(humanReviewEvent.IS_HUMAN_APPROVAL_SIGNAL, true);
assert.equal(humanReviewEvent.IS_RENOVATE_PR, false);
assert.match(humanReviewEvent.EVENT_KEY, /pull_request_review_approved:10$/);

const verifyHumanApproval = (reviews, headSha = event.PR_HEAD_SHA) =>
  execute("Verify Human Approval", {
    $json: { statusCode: 200, body: reviews },
    $: (name) => ({
      item: {
        json: name === "Decide Event Transition"
          ? { ...humanReviewEvent, PR_HEAD_SHA: event.PR_HEAD_SHA }
          : {
              statusCode: 200,
              body: {
                state: "open",
                html_url: "https://forgejo.beaco.works/infrastructure/infra/pulls/8",
                user: { login: "contributor" },
                base: { ref: "main" },
                head: { sha: headSha },
              },
            },
      },
    }),
  }).json;

assert.equal(verifyHumanApproval([{
  id: 10,
  state: "APPROVED",
  commit_id: event.PR_HEAD_SHA,
  user: { login: "beacon1096" },
}]).HUMAN_APPROVAL_VALID, true);
assert.equal(verifyHumanApproval([{
  id: 11,
  state: "APPROVED",
  commit_id: event.PR_HEAD_SHA,
  user: { login: "untrusted-reviewer" },
}]).HUMAN_APPROVAL_VALID, false);
assert.equal(verifyHumanApproval([{
  id: 12,
  state: "APPROVED",
  commit_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  user: { login: "beacon1096" },
}]).HUMAN_APPROVAL_VALID, false);
assert.equal(verifyHumanApproval([{
  id: 13,
  state: "APPROVED",
  commit_id: event.PR_HEAD_SHA,
  dismissed: true,
  user: { login: "beacon1096" },
}]).HUMAN_APPROVAL_VALID, false);

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
assert.equal(valid.JTI.length > 0, true);
assert.equal(Number.isInteger(valid.EXPIRES_AT), true);
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
assert.match(mergeFields.merge_when_checks_succeed, /Get Renovate Merge Status/);
assert.match(mergeFields.merge_when_checks_succeed, /state !== 'success'/);
assert.match(mergeFields.head_commit_id, /HEAD_SHA/);

const reviewStatus = nodes.get("Set Multica Review Status");
const reviewStatusFields = Object.fromEntries(
  reviewStatus.parameters.bodyParameters.parameters.map((field) => [field.name, field.value]),
);
assert.match(reviewStatusFields.state, /human_required|pending/);

const approvalCondition = nodes.get("Multica Review Approved")
  .parameters.conditions.conditions[0];
assert.equal(approvalCondition.rightValue, "approve");

const humanMerge = nodes.get("Merge Human-Approved PR");
assert.equal(humanMerge.credentials.httpHeaderAuth.id, "multicaMerger01");
const humanMergeFields = Object.fromEntries(
  humanMerge.parameters.bodyParameters.parameters.map((field) => [field.name, field.value]),
);
assert.equal(humanMergeFields.force_merge, undefined);
assert.match(humanMergeFields.merge_when_checks_succeed, /Get Human Merge Status/);
assert.match(humanMergeFields.merge_when_checks_succeed, /state !== 'success'/);
assert.match(humanMergeFields.head_commit_id, /Verify Human Approval/);

assert.match(nodes.get("Check Renovate Merge Result").parameters.jsCode, /\[200, 201\]/);
assert.match(nodes.get("Check Human Merge Result").parameters.jsCode, /\[200, 201\]/);

const replayNotice = execute("Build Policy Notice", {
  $json: { capability_consumed: false },
  $: () => ({ first: () => ({ json: {} }) }),
  $execution: { id: "policy-notice-test" },
}).json;
assert.equal(replayNotice.RESPONSE_CODE, 409);
assert.equal(
  replayNotice.RESPONSE_BODY.error,
  "review capability has already been consumed",
);
assert.match(replayNotice.MESSAGE_TEXT, /capability replay blocked/);
assert.doesNotMatch(replayNotice.MESSAGE_TEXT, /capability=/);

const blockedMergeNotice = execute("Build Policy Notice", {
  $json: { statusCode: 200, body: { state: "failure" } },
  $: () => ({ first: () => ({ json: {} }) }),
  $execution: { id: "merge-blocked-test" },
}).json;
assert.equal(blockedMergeNotice.RESPONSE_CODE, 409);
assert.match(blockedMergeNotice.MESSAGE_TEXT, /merge blocked/);

for (const name of [
  "Renovate Merge Status Can Proceed",
  "Human Merge Status Can Proceed",
]) {
  const branches = workflow.connections[name].main.map((branch) =>
    branch.map(({ node }) => node));
  assert.equal(branches[1][0], "Build Policy Notice");
}

assert.deepEqual(
  workflow.connections["Build Policy Notice"].main[0].map(({ node }) => node).sort(),
  ["Notify Matrix Policy Event", "Respond Policy Event"].sort(),
);

const consumeCapability = nodes.get("Consume Review Capability");
assert.equal(consumeCapability.credentials.postgres.id, "reviewCapabilityPg");
assert.match(consumeCapability.parameters.query, /jti uuid PRIMARY KEY/);
assert.match(consumeCapability.parameters.query, /ON CONFLICT \(jti\) DO NOTHING/);
assert.match(consumeCapability.parameters.query, /SELECT EXISTS/);
assert.doesNotMatch(consumeCapability.parameters.query, /\$json|\$\(/);
assert.match(consumeCapability.parameters.options.queryReplacement, /JTI/);
assert.deepEqual(
  workflow.connections["Multica Review Is Valid"].main[0].map(({ node }) => node),
  ["Consume Review Capability"],
);
assert.deepEqual(
  workflow.connections["Capability Was Consumed"].main.map((branch) =>
    branch.map(({ node }) => node)),
  [["Get Current Renovate PR"], ["Build Policy Notice"]],
);

console.log("n8n infra CI workflow checks passed");
