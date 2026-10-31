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

const TOKEN = "synthetic-token-for-tests-only";
const headers = (authorization) => ({ authorization });

// 1. Authentication
const ok = execute("Authenticate Alertmanager Webhook", {
  $json: { headers: headers(`Bearer ${TOKEN}`), body: { status: "firing", alerts: [] } },
  $env: { ALERTMANAGER_WEBHOOK_TOKEN: TOKEN },
});
assert.equal(ok.json.AUTHENTICATED, true);
assert.equal(ok.json.body.status, "firing");
assert.equal("headers" in ok.json, false, "authenticated output must not carry raw headers");
assert.equal(JSON.stringify(ok.json).includes(TOKEN), false, "token must not survive into forwarded data");

for (const [label, authorization] of [
  ["wrong token", `Bearer ${TOKEN.slice(0, 20)}${TOKEN.length - 20}`],
  ["missing scheme", TOKEN],
  ["empty header", ""],
]) {
  const denied = execute("Authenticate Alertmanager Webhook", {
    $json: { headers: headers(authorization), body: { status: "firing", alerts: [] } },
    $env: { ALERTMANAGER_WEBHOOK_TOKEN: TOKEN },
  });
  assert.equal(denied.json.AUTHENTICATED, false, `must reject: ${label}`);
}
assert.throws(
  () =>
    execute("Authenticate Alertmanager Webhook", {
      $json: { headers: headers(`Bearer ${TOKEN}`), body: {} },
      $env: {},
    }),
  undefined,
  "missing token configuration must fail closed (throw)",
);

// 2. Message building
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
assert.match(mixed.json.MESSAGE_HTML, /✅<\/b>|✅/u);
assert.match(mixed.json.MESSAGE_HTML, /🔥/u);
assert.match(mixed.json.MESSAGE_HTML, /1 firing, 1 resolved/u);
assert.match(mixed.json.MESSAGE_TEXT, /✅ CertExpiry/u);
assert.match(mixed.json.MESSAGE_TEXT, /🔥 DiskFull/u);
assert.match(mixed.json.MESSAGE_TEXT, /2026-10-31 12:00Z/u);
assert.match(mixed.json.MESSAGE_TEXT, /severity=critical/u);
assert.match(mixed.json.MESSAGE_TEXT, /disk full on \/data/u);
assert.match(mixed.json.MESSAGE_HTML, /&lt;script&gt;/u);
assert.equal(mixed.json.MESSAGE_HTML.includes("<script>"), false);
assert.equal(mixed.json.MESSAGE_HTML.includes("instance=host:9100"), false, "non-whitelisted labels must not render");
assert.equal(JSON.stringify(mixed.json).includes("must-not-render"), false);
assert.equal(JSON.stringify(mixed.json).includes("internal=1"), false, "non-allowlisted generator URL must be dropped");
assert.match(mixed.json.MESSAGE_HTML, /grafana\.beaco\.works\/alert\/list/u);
assert.equal(mixed.json.MESSAGE_HTML.includes("token=abc"), false, "link query must be stripped");
assert.equal(JSON.stringify(mixed.json).includes("#frag"), false, "link fragment must be stripped");

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
const summaryLine = noisy.json.MESSAGE_TEXT.split("\n").find((line) => line.includes("line1"));
assert(summaryLine !== undefined, "summary line present");
assert.equal(summaryLine.trim().length <= 160, true, `summary must be length-limited (got ${summaryLine.trim().length})`);
assert.equal(summaryLine.includes("\u0000"), false);
assert.equal(JSON.stringify(noisy.json).includes("x".repeat(301)), false, "no annotation may exceed its cap");

const empty = execute("Build Matrix Message", { $json: { body: {} }, $env: env() });
assert.equal(empty.json.ALERT_COUNT, 0);
assert.match(empty.json.MESSAGE_TEXT, /no alert details/u);
const junk = execute("Build Matrix Message", {
  $json: { body: { status: "firing", alerts: [{ generatorURL: 12345 }, null] } },
  $env: env(),
});
assert.equal(junk.json.ALERT_COUNT, 2);
assert.match(junk.json.MESSAGE_TEXT, /- 🔥 alert/u);

console.log("Alertmanager Matrix workflow: 18+ assertions passed (persistence, auth, rendering, links, limits)");
