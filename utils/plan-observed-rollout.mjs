#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";

const SHA_RE = /^[0-9a-f]{40}$/;
const SAFE_DOMAINS = new Set(["application", "documentation", "observability"]);
const SEPARATE_REVIEW_DOMAINS = new Set([
  "authentication",
  "control-plane",
  "network",
  "storage",
]);

function usage() {
  return "usage: node utils/plan-observed-rollout.mjs --plan PLAN.json --inventory INVENTORY.json [--output RESULT.json]";
}

function args(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!["--plan", "--inventory", "--output"].includes(flag) || !value) {
      throw new Error(usage());
    }
    parsed[flag.slice(2)] = value;
  }
  if (!parsed.plan || !parsed.inventory) throw new Error(usage());
  return parsed;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function timestamp(value) {
  if (typeof value !== "string") return null;
  const millis = Date.parse(value);
  return Number.isFinite(millis) ? millis : null;
}

function uniq(values) {
  return [...new Set(values)].sort();
}

function diagnostic(code, message, details = {}) {
  return { code, message, ...details };
}

function evaluate(plan, inventory) {
  const blockers = [];
  const notes = [];
  const separateReview = new Set();
  const usedEvidence = [];
  const evaluatedAt = timestamp(plan.evaluated_at);
  const maximumAge = Number(plan.maximum_evidence_age_seconds);
  const maximumFutureSkew = Number(plan.maximum_future_skew_seconds ?? 120);

  if (plan.schema_version !== 1 || inventory.schema_version !== 1) {
    blockers.push(diagnostic("unsupported-schema", "plan and inventory must use schema_version 1"));
  }
  if (plan.repository !== "infrastructure/infra-private") {
    blockers.push(diagnostic("repository-not-deploy-source", "only infrastructure/infra-private can be evaluated as a production rollout candidate"));
  }
  if (!SHA_RE.test(plan.candidate_sha ?? "") || !SHA_RE.test(plan.known_good_sha ?? "")) {
    blockers.push(diagnostic("invalid-revision", "candidate_sha and known_good_sha must be exact lowercase 40-character revisions"));
  } else if (plan.candidate_sha === plan.known_good_sha) {
    blockers.push(diagnostic("unchanged-revision", "candidate and known-good revisions must differ"));
  }
  if (evaluatedAt === null || !Number.isFinite(maximumAge) || maximumAge <= 0 || !Number.isFinite(maximumFutureSkew) || maximumFutureSkew < 0) {
    blockers.push(diagnostic("invalid-time-policy", "evaluated_at and positive evidence age bounds are required"));
  }

  const snapshot = inventory.snapshot ?? {};
  if (snapshot.repository !== plan.repository || snapshot.sha !== plan.candidate_sha) {
    blockers.push(diagnostic("inventory-source-mismatch", "inventory snapshot must bind the same repository and candidate SHA", {
      expected_repository: plan.repository,
      expected_sha: plan.candidate_sha,
      actual_repository: snapshot.repository ?? null,
      actual_sha: snapshot.sha ?? null,
    }));
  }
  const generatedAt = timestamp(snapshot.generated_at);
  if (evaluatedAt !== null && generatedAt !== null && generatedAt > evaluatedAt + maximumFutureSkew * 1000) {
    blockers.push(diagnostic("future-inventory", "inventory snapshot is later than the evaluation clock"));
  } else if (generatedAt === null) {
    blockers.push(diagnostic("invalid-inventory-time", "inventory snapshot needs a valid generated_at"));
  }

  const hostsByName = new Map();
  for (const host of inventory.hosts ?? []) {
    if (!host.name || hostsByName.has(host.name)) {
      blockers.push(diagnostic("invalid-host-inventory", "inventory host names must be present and unique", { host: host.name ?? null }));
      continue;
    }
    hostsByName.set(host.name, host);
    if (!Array.isArray(host.required_evidence) || host.required_evidence.length === 0) {
      blockers.push(diagnostic("missing-evidence-contract", "each host needs required evidence", { host: host.name }));
    }
    if (!host.independent_recovery?.channel || !Array.isArray(host.independent_recovery?.steps) || host.independent_recovery.steps.length === 0) {
      blockers.push(diagnostic("missing-independent-recovery", "each host needs a reviewed recovery channel and steps that do not depend on the release control plane", { host: host.name }));
    }
  }

  const changedPaths = uniq(plan.changed_paths ?? []);
  if (changedPaths.length === 0) blockers.push(diagnostic("missing-changed-paths", "at least one exact changed path is required"));

  const impactedHosts = new Set();
  const impactedServices = new Set();
  const pathImpact = [];
  for (const path of changedPaths) {
    const matches = (inventory.path_rules ?? []).filter((rule) => typeof rule.prefix === "string" && path.startsWith(rule.prefix));
    if (matches.length === 0) {
      blockers.push(diagnostic("unknown-path", "changed path has no reviewed impact rule", { path }));
      continue;
    }
    const pathHosts = new Set();
    const pathServices = new Set();
    for (const rule of matches) {
      const domain = rule.risk_domain;
      if (SEPARATE_REVIEW_DOMAINS.has(domain)) {
        separateReview.add(domain);
        blockers.push(diagnostic("separate-review-required", "risk domain cannot be promoted by this low-risk planner", { path, risk_domain: domain }));
      } else if (!SAFE_DOMAINS.has(domain)) {
        blockers.push(diagnostic("unknown-risk-domain", "path rule has an unknown risk domain", { path, risk_domain: domain ?? null }));
      }
      for (const host of rule.hosts ?? []) {
        if (!hostsByName.has(host)) blockers.push(diagnostic("unknown-impact-host", "path rule names a host absent from inventory", { path, host }));
        pathHosts.add(host);
        impactedHosts.add(host);
      }
      for (const service of rule.services ?? []) {
        pathServices.add(service);
        impactedServices.add(service);
      }
      if (rule.shared === true && (rule.hosts?.length ?? 0) < 2) {
        blockers.push(diagnostic("invalid-shared-impact", "a shared rule cannot collapse to a single host", { path, prefix: rule.prefix }));
      }
    }
    pathImpact.push({ path, hosts: uniq(pathHosts), services: uniq(pathServices) });
  }

  const evidence = Array.isArray(plan.evidence) ? plan.evidence : [];
  for (const hostName of uniq(impactedHosts)) {
    const host = hostsByName.get(hostName);
    if (!host) continue;
    for (const contract of host.required_evidence ?? []) {
      const matches = evidence.filter((entry) => entry.host === hostName && entry.kind === contract.kind);
      if (matches.length !== 1) {
        blockers.push(diagnostic(matches.length === 0 ? "missing-evidence" : "duplicate-evidence", "exactly one evidence record is required for each impacted host and kind", { host: hostName, kind: contract.kind, count: matches.length }));
        continue;
      }
      const entry = matches[0];
      usedEvidence.push({
        host: entry.host,
        kind: entry.kind,
        source: entry.source ?? null,
        repository: entry.repository ?? null,
        sha: entry.sha ?? null,
        status: entry.status ?? null,
        observed_at: entry.observed_at ?? null,
      });
      if (entry.source !== contract.source || entry.repository !== plan.repository || entry.sha !== plan.candidate_sha) {
        blockers.push(diagnostic("evidence-source-mismatch", "evidence source, repository, or SHA does not match its contract", {
          host: hostName,
          kind: contract.kind,
          expected_source: contract.source,
          actual_source: entry.source ?? null,
        }));
      }
      const observedAt = timestamp(entry.observed_at);
      if (observedAt === null || evaluatedAt === null) {
        blockers.push(diagnostic("invalid-evidence-time", "evidence needs a valid observed_at", { host: hostName, kind: contract.kind }));
      } else if (observedAt > evaluatedAt + maximumFutureSkew * 1000) {
        blockers.push(diagnostic("future-evidence", "evidence is later than the evaluation clock", { host: hostName, kind: contract.kind, observed_at: entry.observed_at }));
      } else if (evaluatedAt - observedAt > maximumAge * 1000) {
        blockers.push(diagnostic("stale-evidence", "evidence is older than the configured maximum", { host: hostName, kind: contract.kind, observed_at: entry.observed_at }));
      }
      if (entry.status !== "healthy") {
        blockers.push(diagnostic(entry.status ? "unhealthy-evidence" : "unknown-evidence", "only an explicit healthy observation is eligible", { host: hostName, kind: contract.kind, status: entry.status ?? null }));
      }
    }
  }

  const expectedHosts = uniq(impactedHosts);
  const batchHosts = [];
  for (const [index, batch] of (plan.batches ?? []).entries()) {
    if (!batch.name || !Array.isArray(batch.hosts) || batch.hosts.length === 0) {
      blockers.push(diagnostic("invalid-batch", "each rollout batch needs a name and at least one host", { index }));
      continue;
    }
    batchHosts.push(...batch.hosts);
  }
  const duplicateBatchHosts = uniq(batchHosts.filter((host, index) => batchHosts.indexOf(host) !== index));
  if (duplicateBatchHosts.length > 0 || JSON.stringify(uniq(batchHosts)) !== JSON.stringify(expectedHosts)) {
    blockers.push(diagnostic("batch-impact-mismatch", "batches must contain every impacted host exactly once and no other host", {
      impacted_hosts: expectedHosts,
      batch_hosts: uniq(batchHosts),
      duplicate_hosts: duplicateBatchHosts,
    }));
  }
  if ((plan.batches?.[0]?.hosts?.length ?? 0) !== 1 && expectedHosts.length > 1) {
    blockers.push(diagnostic("missing-canary", "the first batch must contain exactly one host when more than one host is affected"));
  }

  const stopConditions = uniq(plan.stop_conditions ?? []);
  const requiredStopConditions = [
    "candidate-revision-drift",
    "control-channel-unavailable",
    "evidence-unhealthy-or-missing",
    "host-or-service-regression",
  ];
  for (const condition of requiredStopConditions) {
    if (!stopConditions.includes(condition)) blockers.push(diagnostic("missing-stop-condition", "required rollout stop condition is absent", { condition }));
  }

  if (blockers.length === 0) {
    notes.push(diagnostic("candidate-only", "all offline checks passed; this is only a candidate for the existing human release review"));
  }
  return {
    schema_version: 1,
    recommendation: blockers.length === 0 ? "candidate-for-human-review" : "blocked",
    authorized: false,
    repository: plan.repository ?? null,
    candidate_sha: plan.candidate_sha ?? null,
    known_good_sha: plan.known_good_sha ?? null,
    evaluated_at: plan.evaluated_at ?? null,
    impact: {
      paths: changedPaths,
      hosts: expectedHosts,
      services: uniq(impactedServices),
      path_details: pathImpact,
    },
    batches: plan.batches ?? [],
    observations: usedEvidence.sort((left, right) => `${left.host}/${left.kind}`.localeCompare(`${right.host}/${right.kind}`)),
    stop_conditions: stopConditions,
    separate_review_domains: uniq(separateReview),
    recovery: expectedHosts.map((hostName) => ({
      host: hostName,
      ...hostsByName.get(hostName)?.independent_recovery,
    })),
    blockers,
    notes,
  };
}

let output;
let outputPath;
try {
  const cli = args(process.argv.slice(2));
  outputPath = cli.output;
  output = evaluate(readJson(cli.plan), readJson(cli.inventory));
} catch (error) {
  output = {
    schema_version: 1,
    recommendation: "blocked",
    authorized: false,
    blockers: [diagnostic("invalid-input", error.message)],
  };
}

const rendered = `${JSON.stringify(output, null, 2)}\n`;
if (outputPath) writeFileSync(outputPath, rendered);
else process.stdout.write(rendered);
process.exitCode = output.recommendation === "candidate-for-human-review" ? 0 : 2;
