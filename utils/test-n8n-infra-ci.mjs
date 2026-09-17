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

const queueRereview = execute("Normalize Forgejo Event", {
  $json: {
    headers: {
      "x-forgejo-event-type": "pull_request_review_merge_queue_rerequested",
      "x-forgejo-delivery": `merge-queue-rereview:infrastructure/infra:7:${event.PR_HEAD_SHA}`,
    },
    body: {
      action: "synchronize",
      repository: { full_name: "infrastructure/infra" },
      sender: { login: "multica-merger" },
      pull_request: {
        number: 7,
        user: { login: "renovate" },
        head: { sha: event.PR_HEAD_SHA },
        base: { ref: "main" },
      },
    },
  },
  $execution: { id: "queue-rereview-test" },
}).json;
assert.equal(queueRereview.IS_RENOVATE_PR, true);
assert.match(queueRereview.EVENT_KEY, /pull_request_review_merge_queue_rerequested:/);

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

const selfApprovalEvent = execute("Normalize Forgejo Event", {
  $json: {
    headers: { "x-forgejo-event": "issue" },
    body: {
      action: "created",
      repository: { full_name: "infrastructure/infra" },
      sender: { login: "beacon1096" },
      issue: { number: 8, pull_request: { merged: false } },
      comment: { id: 20, body: `/approve ${event.PR_HEAD_SHA}` },
    },
  },
  $execution: { id: "self-approval-execution" },
}).json;
assert.equal(selfApprovalEvent.SUPPORTED, true);
assert.equal(selfApprovalEvent.IS_HUMAN_APPROVAL_SIGNAL, true);
assert.equal(selfApprovalEvent.APPROVAL_KIND, "comment");
assert.equal(selfApprovalEvent.APPROVAL_COMMENT_ID, 20);
assert.equal(selfApprovalEvent.PR_HEAD_SHA, event.PR_HEAD_SHA);

const shortShaApproval = execute("Normalize Forgejo Event", {
  $json: {
    headers: { "x-forgejo-event": "issue" },
    body: {
      action: "created",
      repository: { full_name: "infrastructure/infra" },
      sender: { login: "beacon1096" },
      issue: { number: 8, pull_request: { merged: false } },
      comment: { id: 21, body: "/approve 0123456" },
    },
  },
  $execution: { id: "short-sha-approval-execution" },
}).json;
assert.equal(shortShaApproval.SUPPORTED, false);
assert.equal(shortShaApproval.IS_HUMAN_APPROVAL_SIGNAL, false);

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

const verifySelfApproval = (comment, headSha = event.PR_HEAD_SHA) =>
  execute("Verify Human Approval", {
    $json: { statusCode: 200, body: comment },
    $: (name) => ({
      item: {
        json: name === "Decide Event Transition"
          ? selfApprovalEvent
          : {
              statusCode: 200,
              body: {
                state: "open",
                html_url: "https://forgejo.beaco.works/infrastructure/infra/pulls/8",
                user: { login: "beacon1096" },
                base: { ref: "main" },
                head: { sha: headSha },
              },
            },
      },
    }),
  }).json;

assert.equal(verifySelfApproval({
  id: 20,
  body: `/approve ${event.PR_HEAD_SHA}`,
  user: { login: "beacon1096" },
}).HUMAN_APPROVAL_VALID, true);
assert.equal(verifySelfApproval({
  id: 20,
  body: "/approve aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  user: { login: "beacon1096" },
}).HUMAN_APPROVAL_VALID, false);
assert.equal(verifySelfApproval({
  id: 20,
  body: `/approve ${event.PR_HEAD_SHA}`,
  user: { login: "untrusted-reviewer" },
}).HUMAN_APPROVAL_VALID, false);
assert.equal(verifySelfApproval({
  id: 999,
  body: `/approve ${event.PR_HEAD_SHA}`,
  user: { login: "beacon1096" },
}).HUMAN_APPROVAL_VALID, false);
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
assert.equal(typeof execute("Create Review Capability", {
  $: () => ({ first: () => ({ json: event }) }),
  $env: { REVIEW_CAPABILITY_SECRET: secret },
}).json.REVIEW_JTI, "string");
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

const treeEntry = (path, sha, mode = "100644", type = "blob") => ({
  path,
  mode,
  type,
  sha,
});
const baseBlob = "1".repeat(40);
const approvedBlob = "2".repeat(40);
const unrelatedBlob = "3".repeat(40);
const mergeBase = "4".repeat(40);
const approvedHead = "5".repeat(40);
const buildDelta = (baseTree, headTree) => execute("Build Approved Tree Delta", {
  $: (name) => ({
    first: () => ({
      json: name === "Verify Current Renovate PR"
        ? { ...valid, HEAD_SHA: approvedHead }
        : name === "Get Current Renovate PR"
          ? { body: { merge_base: mergeBase } }
          : name === "Get Approved Base Tree"
            ? { statusCode: 200, body: { truncated: false, tree: baseTree } }
            : { statusCode: 200, body: { truncated: false, tree: headTree } },
    }),
  }),
}).json;
const originalDelta = buildDelta(
  [treeEntry("flake.lock", baseBlob)],
  [treeEntry("flake.lock", approvedBlob)],
);
const rebasedEquivalentDelta = buildDelta(
  [treeEntry("flake.lock", baseBlob), treeEntry("README.md", unrelatedBlob)],
  [treeEntry("flake.lock", approvedBlob), treeEntry("README.md", unrelatedBlob)],
);
assert.equal(originalDelta.DELTA_VALID, true);
assert.equal(originalDelta.DELTA_COUNT, 1);
assert.equal(originalDelta.DELTA_DIGEST, rebasedEquivalentDelta.DELTA_DIGEST);
assert.notEqual(
  originalDelta.DELTA_DIGEST,
  buildDelta(
    [treeEntry("flake.lock", baseBlob)],
    [treeEntry("flake.lock", unrelatedBlob)],
  ).DELTA_DIGEST,
);
assert.equal(
  execute("Build Approved Tree Delta", {
    $: (name) => ({
      first: () => ({
        json: name === "Verify Current Renovate PR"
          ? { ...valid, HEAD_SHA: approvedHead }
          : name === "Get Current Renovate PR"
            ? { body: { merge_base: mergeBase } }
            : { statusCode: 200, body: { truncated: true, tree: [] } },
      }),
    }),
  }).json.DELTA_VALID,
  false,
);

assert.equal(nodes.get("Get Active Renovate Queue").credentials.postgres.id, "reviewCapabilityPg");
assert.match(nodes.get("Get Active Renovate Queue").parameters.query, /renovate_merge_queue/);
assert.match(nodes.get("Store Renovate Merge Queue").parameters.query, /delta_digest/);
assert.match(nodes.get("Store Renovate Merge Queue").parameters.query, /state = 'queued'/);
assert.deepEqual(
  workflow.connections["Renovate Review Already Queued"].main.map((branch) =>
    branch.map(({ node }) => node)),
  [[], ["Create Review Capability"]],
);
assert.deepEqual(
  workflow.connections["Multica Review Approved"].main.map((branch) =>
    branch.map(({ node }) => node)),
  [["Get Approved Base Tree"], ["Build Policy Notice"]],
);

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

const dependencyFailureNotice = execute("Build Policy Notice", {
  $json: {},
  $: (name) => ({
    first: () => ({
      json: name === "Verify Current Renovate PR"
        ? { PR_READ_FAILED: true, REPO: event.REPO, PR_NUMBER: 999999 }
        : {},
    }),
  }),
  $execution: { id: "dependency-failure-test" },
}).json;
assert.equal(dependencyFailureNotice.RESPONSE_CODE, 424);
assert.equal(
  dependencyFailureNotice.RESPONSE_BODY.error,
  "failed to read current Forgejo PR",
);

for (const name of [
  "Renovate Merge Status Can Proceed",
  "Human Merge Status Can Proceed",
]) {
  const branches = workflow.connections[name].main.map((branch) =>
    branch.map(({ node }) => node));
  assert.equal(branches[1][0], "Build Policy Notice");
}

for (const name of [
  "Get Current Renovate PR",
  "Get Current Human PR",
  "Get Human PR Reviews",
  "Get Renovate Merge Status",
  "Get Human Merge Status",
]) {
  assert.equal(nodes.get(name).alwaysOutputData, true);
}
assert.match(nodes.get("Get Current Renovate PR").parameters.url, /\.first\(\)/);
assert.match(nodes.get("Respond Policy Event").parameters.responseBody, /\.first\(\)/);
assert.equal(
  nodes.get("Create Review Capability").parameters.jsCode
    .includes('$("Decide Event Transition").item'),
  false,
);
const multicaTrigger = nodes.get("Trigger Multica Renovate Autopilot");
assert.equal(multicaTrigger.parameters.body.includes('$("Decide Event Transition").item'), false);
assert.match(multicaTrigger.parameters.body, /User-Agent: Multica-Review-Callback\/1\.0/);
assert.match(multicaTrigger.parameters.body, /rejects Python-urllib/);
assert.match(multicaTrigger.parameters.body, /intentionally has no Forgejo PAT/);
assert.match(multicaTrigger.parameters.body, /must not by itself cause human_required/);
assert.match(multicaTrigger.parameters.body, /n8n independently re-reads the open PR, exact head SHA, and required checks/);
assert.equal(
  multicaTrigger.parameters.headerParameters.parameters[1].value
    .includes('$("Decide Event Transition").item'),
  false,
);

assert.deepEqual(
  workflow.connections["Build Policy Notice"].main[0].map(({ node }) => node).sort(),
  ["Notify Matrix Policy Event", "Respond Policy Event"].sort(),
);

const dispatchStore = nodes.get("Store Multica Review Dispatch");
assert.equal(dispatchStore.credentials.postgres.id, "reviewCapabilityPg");
assert.match(dispatchStore.parameters.query, /multica_review_dispatches/);
assert.match(dispatchStore.parameters.query, /run_id uuid NOT NULL UNIQUE/);
assert.doesNotMatch(dispatchStore.parameters.query, /\$json|\$\(/);

const supersededDispatches = nodes.get("Get Superseded Multica Dispatches");
assert.equal(supersededDispatches.credentials.postgres.id, "reviewCapabilityPg");
assert.match(supersededDispatches.parameters.query, /repo = \$1/);
assert.match(supersededDispatches.parameters.query, /pr_number = \$2::bigint/);
assert.match(supersededDispatches.parameters.query, /head_sha <> \$3/);
assert.match(supersededDispatches.parameters.query, /run_id <> \$4::uuid/);
assert.doesNotMatch(supersededDispatches.parameters.query, /\$json|\$\(/);

for (const name of [
  "Get Superseded Multica Run",
  "Cancel Superseded Multica Run",
  "Get Superseded Multica Issue",
  "Cancel Superseded Multica Issue",
]) {
  assert.equal(nodes.get(name).credentials.httpHeaderAuth.id, "multicaCloser01");
}
assert.equal(nodes.get("Cancel Superseded Multica Run").parameters.method, "POST");
assert.match(nodes.get("Cancel Superseded Multica Run").parameters.url, /\/api\/tasks\/.*\/cancel/);
assert.match(
  nodes.get("Superseded Multica Run Is Active").parameters.conditions.conditions[0].leftValue,
  /queued.*dispatched.*running.*waiting_local_directory.*deferred/,
);
assert.match(nodes.get("Cancel Superseded Multica Issue").parameters.jsonBody, /status: 'cancelled'/);
assert.deepEqual(
  workflow.connections["Store Multica Review Dispatch"].main[0].map(({ node }) => node),
  ["Get Superseded Multica Dispatches"],
);
assert.deepEqual(
  workflow.connections["Superseded Multica Run Is Active"].main.map((branch) =>
    branch.map(({ node }) => node)),
  [["Cancel Superseded Multica Run"], ["Get Superseded Multica Issue"]],
);
assert.deepEqual(
  workflow.connections["Cancel Superseded Multica Run"].main[0].map(({ node }) => node),
  ["Get Superseded Multica Issue"],
);
assert.deepEqual(
  workflow.connections["Superseded Multica Issue Is Active"].main.map((branch) =>
    branch.map(({ node }) => node)),
  [["Cancel Superseded Multica Issue"], []],
);

const supersededRun = execute("Verify Superseded Multica Run", {
  $json: {
    id: "22222222-2222-4222-8222-222222222222",
    autopilot_id: "11111111-1111-4111-8111-111111111111",
    issue_id: "44444444-4444-4444-8444-444444444444",
    status: "running",
  },
  $: () => ({ item: { json: {
    autopilot_id: "11111111-1111-4111-8111-111111111111",
    run_id: "22222222-2222-4222-8222-222222222222",
  } } }),
}).json;
assert.equal(supersededRun.ISSUE_ID, "44444444-4444-4444-8444-444444444444");
assert.equal(supersededRun.RUN_ID, "22222222-2222-4222-8222-222222222222");
assert.equal(supersededRun.RUN_STATUS, "running");
assert.throws(() => execute("Verify Superseded Multica Run", {
  $json: {
    id: "55555555-5555-4555-8555-555555555555",
    autopilot_id: "11111111-1111-4111-8111-111111111111",
    issue_id: "44444444-4444-4444-8444-444444444444",
  },
  $: () => ({ item: { json: {
    autopilot_id: "11111111-1111-4111-8111-111111111111",
    run_id: "22222222-2222-4222-8222-222222222222",
  } } }),
}));

assert.equal(
  nodes.get("Trigger Multica Renovate Autopilot").parameters.options.response,
  undefined,
);
const validatedDispatch = execute("Validate Multica Dispatch", {
  $json: {
    status: "accepted",
    autopilot_id: "11111111-1111-4111-8111-111111111111",
    run_id: "22222222-2222-4222-8222-222222222222",
  },
  $: () => ({ first: () => ({ json: {
    REVIEW_JTI: "33333333-3333-4333-8333-333333333333",
    REPO: event.REPO,
    PR_NUMBER: Number(event.PR_NUMBER),
    PR_HEAD_SHA: event.PR_HEAD_SHA,
  } }) }),
}).json;
assert.equal(validatedDispatch.RUN_ID, "22222222-2222-4222-8222-222222222222");
assert.throws(() => execute("Validate Multica Dispatch", {
  $json: { status: "rejected" },
  $: () => ({ first: () => ({ json: {} }) }),
}));

for (const name of ["Get Multica Autopilot Run", "Complete Multica Review Issue"]) {
  assert.equal(nodes.get(name).credentials.httpHeaderAuth.id, "multicaCloser01");
}
assert.match(nodes.get("Complete Multica Review Issue").parameters.jsonBody, /status: 'done'/);
assert.deepEqual(
  workflow.connections["Renovate Merge Completed"].main.map((branch) =>
    branch.map(({ node }) => node)),
  [["Get Multica Review Dispatch"], []],
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
