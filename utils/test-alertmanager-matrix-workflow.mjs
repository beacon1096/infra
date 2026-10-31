import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);

const workflowSource = fs.readFileSync(
  new URL("../wanxiang/kubernetes/apps/development/n8n/app/alertmanager-matrix.workflow.json", import.meta.url),
  "utf8",
);
const workflowDocument = JSON.parse(workflowSource);
assert.equal(
  workflowSource,
  `${JSON.stringify(workflowDocument, null, 2)}\n`,
  "Alertmanager Matrix workflow JSON must use canonical two-space formatting",
);
assert.equal(workflowDocument.length, 1);
const workflow = workflowDocument[0];
const nodes = new Map(workflow.nodes.map((node) => [node.name, node]));

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

// Raw execution data must never persist: success, error, manual and progress saves are off.
assert.equal(workflow.settings.saveDataSuccessExecution, "none");
assert.equal(workflow.settings.saveDataErrorExecution, "none");
assert.equal(workflow.settings.saveManualExecutions, false);
assert.equal(workflow.settings.saveExecutionProgress, false);
assert.equal(workflow.settings.availableInMCP, false);

const webhooks = workflow.nodes.filter((node) => node.type === "n8n-nodes-base.webhook");
assert.equal(webhooks.length, 1, "exactly one webhook trigger");
assert.equal(webhooks[0].parameters.responseMode, "responseNode");
assert.equal(webhooks[0].parameters.path, webhooks[0].webhookId);

// Only the authenticated branch may reach the Matrix sender; rejection must not.
const ifConnections = workflow.connections["Token Valid"].main;
assert.equal(ifConnections[1][0].node, "Reject Unauthenticated");
assert.equal(workflow.connections["Reject Unauthenticated"], undefined);
const matrixSender = "Send Alertmanager Matrix Notification";
let sender = null;
for (const [source, outputs] of Object.entries(workflow.connections)) {
  for (const output of outputs.main ?? []) {
    for (const connection of output) {
      if (connection.node === matrixSender) sender = source;
    }
  }
}
assert.equal(sender, "Build Matrix Message");

const execute = (name, context) =>
  vm.runInNewContext(`(function () { ${nodes.get(name).parameters.jsCode} })()`, {
    Buffer,
    Date,
    URL,
    crypto,
    require,
    ...context,
  });

// 1. Authentication. The JWT-authenticated gateway entry verifies the token,
// removes Authorization, and forwards only the `sub` claim as the user header;
// the node accepts the claim alone and fails closed without it.
const CLAIM = "wanxiang-alertmanager";
const ok = execute("Authenticate Alertmanager Webhook", {
  $json: { headers: { "x-alertmanager-user": CLAIM }, body: { status: "firing", alerts: [] } },
  $env: {},
});
assert.equal(ok.json.AUTHENTICATED, true);
assert.equal(ok.json.body.status, "firing");
assert.equal("headers" in ok.json, false, "authenticated output must not carry raw headers");
assert.equal(JSON.stringify(ok.json).includes(CLAIM), false, "the gateway claim must not leak into forwarded data");

for (const [label, nodeHeaders] of [
  ["no gateway claim (direct n8n or unauthenticated access must fail closed)", {}],
  ["wrong user", { "x-alertmanager-user": "attacker" }],
  ["empty claim", { "x-alertmanager-user": "" }],
  ["case spoofing", { "x-alertmanager-user": "WANXIANG-ALERTMANAGER" }],
  ["credential not stripped by gateway (bypass attempt)", { "x-alertmanager-user": CLAIM, authorization: "Bearer leaked" }],
  ["valid JWT without gateway (direct svc access)", { authorization: "Bearer leaked" }],
]) {
  const denied = execute("Authenticate Alertmanager Webhook", {
    $json: { headers: nodeHeaders, body: { status: "firing", alerts: [] } },
    $env: {},
  });
  assert.equal(denied.json.AUTHENTICATED, false, `must reject: ${label}`);
  assert.equal(JSON.stringify(denied.json).includes("leaked"), false);
}

const claimHeaders = execute("Authenticate Alertmanager Webhook", {
  $json: { headers: { "X-AlertManager-User": CLAIM }, body: {} },
  $env: {},
});
assert.equal(claimHeaders.json.AUTHENTICATED, true, "header names are case-insensitive per RFC 7230");

// 2. Fixed safe template. Raw annotations must never render; label values and
// alert names outside the strict allow patterns are omitted, so no arbitrary
// operator text and no credential-shaped string has a syntax to survive in.
const env = (overrides = {}) => ({
  ALERTMANAGER_MATRIX_ROOM_ID: "",
  ...overrides,
});
const mixed = execute("Build Matrix Message", {
  $json: {
    body: {
      status: "firing",
      alerts: [
        {
          status: "firing",
          labels: { alertname: "DiskFull", severity: "critical", namespace: "storage", instance: "host:9100", secret_token: "must-not-render" },
          annotations: { summary: "disk full on /data", description: "df says 99%" },
          startsAt: "2026-10-31T12:00:00Z",
          generatorURL: "https://grafana.beaco.works/alert/list?token=abc#frag",
        },
        {
          status: "resolved",
          labels: { alertname: "CertExpiry" },
          annotations: { summary: "<script>alert(1)</script>" },
          startsAt: "2026-10-30T10:00:00Z",
          generatorURL: "http://10.55.0.1:9090/alert?internal=1",
        },
      ],
    },
  },
  $env: env(),
});
assert.equal(mixed.json.STATUS, "firing");
assert.equal(mixed.json.ALERT_COUNT, 2);
assert.equal(mixed.json.FIRING_COUNT, 1);
assert.equal(mixed.json.RESOLVED_COUNT, 1);
assert.equal(mixed.json.ROOM, "!GfJXfhwgQXrmCRRjlf:beaco.works", "default room");
assert.match(mixed.json.MESSAGE_HTML, /✅/u);
assert.match(mixed.json.MESSAGE_HTML, /🔥/u);
assert.match(mixed.json.MESSAGE_HTML, /1 firing, 1 resolved/u);
assert.match(mixed.json.MESSAGE_TEXT, /✅ CertExpiry/u);
assert.match(mixed.json.MESSAGE_TEXT, /🔥 DiskFull/u);
assert.match(mixed.json.MESSAGE_TEXT, /2026-10-31 12:00Z/u);
assert.match(mixed.json.MESSAGE_TEXT, /severity=critical/u);
assert.equal(JSON.stringify(mixed.json).includes("disk full"), false, "raw annotations must never render");
assert.equal(JSON.stringify(mixed.json).includes("99%"), false, "raw annotations must never render");
assert.equal(JSON.stringify(mixed.json).includes("<script>"), false);
assert.equal(JSON.stringify(mixed.json).includes("must-not-render"), false);
assert.equal(JSON.stringify(mixed.json).includes("host:9100"), false, "non-whitelisted labels must not render");
assert.equal(JSON.stringify(mixed.json).includes("internal=1"), false, "non-allowlisted generator URL must be dropped");
assert.match(mixed.json.MESSAGE_HTML, /grafana\.beaco\.works\/alert\/list/u);
assert.equal(JSON.stringify(mixed.json).includes("token=abc"), false, "link query must be stripped");
assert.equal(JSON.stringify(mixed.json).includes("#frag"), false, "link fragment must be stripped");

// Credential-shaped text embedded in allowed structural fields and in the
// omitted annotations: none of it may appear anywhere in the output.
const SECRETS = [
  'password="synthetic-canary"',
  '{"token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.fake.fake"}',
  "Basic c2hvcnQtdmFsdWU=",
  "Bearer abcdefgh.1234567890.abcdefghij",
  "deadbeefdeadbeefdeadbeefdeadbeefcafe",
];
for (const [index, secret] of SECRETS.entries()) {
  const leaked = execute("Build Matrix Message", {
    $json: {
      body: {
        status: "firing",
        alerts: [
          {
            status: "firing",
            labels: {
              alertname: `LeakFixture${index}`,
              severity: secret,
              namespace: `ns-${index}`,
              node: secret.replace(/[^A-Za-z0-9._:/-]/g, ""),
            },
            annotations: { summary: `rotated ${secret} please check`, description: `context ${secret} end` },
            generatorURL: `https://grafana.beaco.works/d/${index}?q=${encodeURIComponent(secret)}`,
            startsAt: "2026-01-01T00:00:00Z",
          },
        ],
      },
    },
    $env: env(),
  });
  assert.equal(JSON.stringify(leaked.json).includes(secret), false, `secret fixture ${index} leaked: ${JSON.stringify(leaked.json).slice(0, 200)}`);
  for (const rendered of [leaked.json.MESSAGE_HTML, leaked.json.MESSAGE_TEXT]) {
    assert.equal(rendered.includes(secret), false, `fixture ${index} must not survive into rendered text`);
  }
  // invalid label values are omitted (only the key-valid structural parts remain)
  assert.match(leaked.json.MESSAGE_TEXT, /LeakFixture/u);
}

const strictness = execute("Build Matrix Message", {
  $json: {
    body: {
      status: "firing",
      alerts: [
        {
          status: "firing",
          labels: { alertname: "1BadName", severity: "warning=oops", namespace: "storage", node: "ms01 c!bad", pod: "valid-pod-1" },
          annotations: { summary: "text" },
          startsAt: "not-a-time",
          generatorURL: "https://grafana.beaco.works/d/abc/../x",
        },
      ],
    },
  },
  $env: env(),
});
assert.match(strictness.json.MESSAGE_TEXT, /- 🔥 alert/u, "bad alertname collapses to template default");
assert.equal(strictness.json.MESSAGE_TEXT.includes("severity=warning=oops"), false, "invalid label value must be omitted");
assert.equal(strictness.json.MESSAGE_TEXT.includes("namespace=storage"), true, "valid label value renders");
assert.equal(strictness.json.MESSAGE_TEXT.includes("ms01 c!bad"), false, "invalid node label must be omitted");
assert.match(strictness.json.MESSAGE_TEXT, /pod=valid-pod-1/u);
assert.equal(strictness.json.MESSAGE_TEXT.includes("not-a-time"), false, "invalid start time must be omitted");
assert.equal(strictness.json.MESSAGE_HTML.includes("../x"), false, "traversal-shaped link path must be dropped");

const roomOverride = execute("Build Matrix Message", {
  $json: { body: { status: "resolved", alerts: [{ status: "resolved", labels: { alertname: "A" }, startsAt: "2026-01-01T00:00:00Z" }] } },
  $env: env({ ALERTMANAGER_MATRIX_ROOM_ID: "!custom:beaco.works" }),
});
assert.equal(roomOverride.json.ROOM, "!custom:beaco.works");
assert.match(roomOverride.json.MESSAGE_TEXT, /✅ A/u);
assert.match(roomOverride.json.MESSAGE_TEXT, /Alertmanager: 0 firing, 1 resolved/u);

const linkOverride = execute("Build Matrix Message", {
  $json: {
    body: {
      status: "firing",
      alerts: [{ status: "firing", labels: { alertname: "A" }, generatorURL: "https://trace.example/one/two?q=1", startsAt: "2026-01-01T00:00:00Z" }],
    },
  },
  $env: env({ ALERTMANAGER_LINK_HOSTS: "trace.example" }),
});
assert.match(linkOverride.json.MESSAGE_HTML, /href="https:\/\/trace\.example\/one\/two"/u);

const noisy = execute("Build Matrix Message", {
  $json: {
    body: {
      status: "firing",
      alerts: [
        {
          status: "firing",
          labels: { alertname: "A", severity: "warning\twith\u0000null" },
          annotations: { summary: `line1\nline2 ${"x".repeat(300)}` },
          startsAt: "2026-01-01T00:00:00Z",
        },
      ],
    },
  },
  $env: env(),
});
assert.equal(JSON.stringify(noisy.json).includes("line1"), false, "annotations never render");
assert.equal(JSON.stringify(noisy.json).includes("\u0000"), false);
assert.equal(JSON.stringify(noisy.json).includes("x".repeat(301)), false);

const empty = execute("Build Matrix Message", { $json: { body: {} }, $env: env() });
assert.equal(empty.json.ALERT_COUNT, 0);
assert.match(empty.json.MESSAGE_TEXT, /no alert details/u);
const junk = execute("Build Matrix Message", {
  $json: { body: { status: "firing", alerts: [{ generatorURL: 12345 }, null] } },
  $env: env(),
});
assert.equal(junk.json.ALERT_COUNT, 2);
assert.match(junk.json.MESSAGE_TEXT, /- 🔥 alert/u);

// Wiring evidence for downstream-failure semantics: the Matrix sender is only
// reachable from the build node (single incoming connection) and feeds an
// acceptance check, because on n8n 2.18.4 the Matrix node does NOT throw on
// 4xx/5xx homeserver answers — it resolves with the errcode body, so the
// workflow must classify it explicitly. The success responder only runs after
// the sender AND an accepted answer; a dedicated 502 responder makes an
// unaccepted answer surface to Alertmanager as a retryable failure. The
// rejection responder sends 401.
const respondNode = nodes.get("Respond to Alertmanager");
assert.equal(String(respondNode.parameters.options?.responseCode ?? 200), "200");
const failNode = nodes.get("Report Delivery Failure");
assert.equal(String(failNode.parameters.options?.responseCode), "502");
const rejectNode = nodes.get("Reject Unauthenticated");
assert.equal(String(rejectNode.parameters.options?.responseCode ?? 401), "401");
const matrixNode = nodes.get(matrixSender);
assert.equal(matrixNode.type, "n8n-nodes-base.matrix");
assert.equal(matrixNode.parameters.messageFormat, "org.matrix.custom.html");
const acceptedNode = nodes.get("Matrix Accepted?");
assert.equal(acceptedNode.type, "n8n-nodes-base.if");
assert.match(acceptedNode.parameters.conditions.conditions[0].leftValue, /errcode/);
assert.match(acceptedNode.parameters.conditions.conditions[0].leftValue, /event_id/);

// Gateway wiring: JWT auth with claim injection and header removal on the
// internal host, claim guard on n8n's external route, and credential strip on
// the webhook paths when reached via the legacy external host.
const appDir = "../wanxiang/kubernetes/apps/development/n8n/app/";
const hookDoc = fs.readFileSync(new URL(appDir + "alertmanager-hook.yaml", import.meta.url), "utf8");
assert.match(hookDoc, /^  jwt:/m, "internal host must require a JWT");
// Without extractFrom.headers EG 1.7.2 also accepts ?access_token=<jwt> and
// Envoy forwards that query; extraction must be pinned to the header.
assert.match(hookDoc, /extractFrom:/, "JWT extraction must be restricted");
assert.match(hookDoc, /name: Authorization/, "JWT extraction pinned to Authorization");
assert.match(hookDoc, /valuePrefix: "Bearer "/, "JWT extraction pinned to Bearer prefix");
assert.match(hookDoc, /x-alertmanager-user/, "internal host must forward the sub claim");
assert.match(hookDoc, /- authorization/, "internal host must strip the JWT bearer header after auth");
const guardDoc = fs.readFileSync(new URL(appDir + "n8n-webhook-claim-guard.yaml", import.meta.url), "utf8");
assert.match(guardDoc, /defaultAction: Allow/, "claim guard must allow everything except forged claims");
assert.match(guardDoc, /wanxiang-alertmanager/, "claim guard must deny the known claim value");
const hrDoc = fs.readFileSync(new URL(appDir + "helmrelease.yaml", import.meta.url), "utf8");
assert.equal(
  (hrDoc.match(/webhook(-test)?\/03dbae25-586b-4e53-b38b-5a23293d5228/g) ?? []).length,
  2,
  "webhook and webhook-test prefixes must each have a strip rule",
);
assert.equal(
  (hrDoc.match(/- x-alertmanager-user/g) ?? []).length,
  2,
  "each strip rule must remove the identity claim header too",
);
assert.match(hrDoc, /- authorization/, "webhook strip rules must remove caller credentials");

console.log("Alertmanager Matrix workflow: assertions passed (persistence, gateway-claim auth, fixed template, links, strictness, gateway wiring)");
