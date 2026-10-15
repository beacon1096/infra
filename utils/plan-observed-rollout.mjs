#!/usr/bin/env node

import { createHash } from "node:crypto";
import { posix } from "node:path";
import { readFileSync, writeFileSync } from "node:fs";

const SHA_RE = /^[0-9a-f]{40}$/;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const STORE_PATH_RE = /^\/nix\/store\/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+$/;
const SAFE_DOMAINS = new Set(["application", "documentation", "observability"]);
const SEPARATE_REVIEW_DOMAINS = new Set(["authentication", "control-plane", "network", "storage"]);
const KNOWN_DOMAINS = new Set([...SAFE_DOMAINS, ...SEPARATE_REVIEW_DOMAINS, "unclassified"]);
const INDEPENDENT_FROM = ["comin", "forgejo", "n8n", "production-network"];

function usage() {
  return "usage: node utils/plan-observed-rollout.mjs --plan PLAN.json --inventory INVENTORY.json [--output RESULT.json]";
}

function args(argv) {
  const parsed = {};
  if (argv.length % 2 !== 0) throw new Error(usage());
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!["--plan", "--inventory", "--output"].includes(flag) || !value) throw new Error(usage());
    parsed[flag.slice(2)] = value;
  }
  if (!parsed.plan || !parsed.inventory) throw new Error(usage());
  return parsed;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function timestamp(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(value)) return null;
  const millis = Date.parse(value);
  return Number.isFinite(millis) ? millis : null;
}

function uniq(values) {
  return [...new Set(values)].sort();
}

function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function digest(value) {
  return `sha256:${createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
}

function diagnostic(code, message, details = {}) {
  return { code, message, ...details };
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function checkShape(value, where, required, allowed, blockers) {
  if (!isObject(value)) {
    blockers.push(diagnostic("invalid-schema", `${where} must be an object`, { where }));
    return false;
  }
  for (const key of required) {
    if (!Object.hasOwn(value, key)) blockers.push(diagnostic("missing-field", `${where}.${key} is required`, { where, field: key }));
  }
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) blockers.push(diagnostic("unknown-field", `${where}.${key} is not allowed`, { where, field: key }));
  }
  return true;
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() === value && value.length > 0;
}

function canonicalPath(value, { directory = false } = {}) {
  if (!nonEmptyString(value) || value.startsWith("/") || value.includes("\\") || value.includes("\0")) return false;
  const candidate = directory && value.endsWith("/") ? value.slice(0, -1) : value;
  if (!candidate || candidate.split("/").some((part) => part === "" || part === "." || part === "..")) return false;
  if (posix.normalize(candidate) !== candidate) return false;
  return directory ? value.endsWith("/") : !value.endsWith("/");
}

function validateTime(value, evaluatedAt, maximumAgeSeconds, maximumFutureSkewSeconds, codes, details, blockers) {
  const observedAt = timestamp(value);
  if (observedAt === null || evaluatedAt === null) blockers.push(diagnostic(codes.invalid, "timestamp is not strict RFC3339 UTC", details));
  else if (observedAt > evaluatedAt + maximumFutureSkewSeconds * 1000) blockers.push(diagnostic(codes.future, "timestamp is later than the evaluation clock", { ...details, observed_at: value }));
  else if (evaluatedAt - observedAt > maximumAgeSeconds * 1000) blockers.push(diagnostic(codes.stale, "timestamp is older than the configured maximum", { ...details, observed_at: value }));
}

function inferredRisk(path) {
  const segments = path.toLowerCase().split("/");
  const basename = segments.at(-1);
  if (basename === "disko.nix" || segments.some((part) => ["longhorn", "storage"].includes(part))) return "storage";
  if (segments.some((part) => ["auth", "authentication", "keycloak", "secrets", "sops"].includes(part))) return "authentication";
  if (segments.some((part) => ["dns", "network", "networking", "router", "routing", "tailscale"].includes(part))) return "network";
  if (path.startsWith(".forgejo/workflows/") || path.endsWith("infra-ci.workflow.json") || path === "modules/nixos/comin.nix" || path === "modules/darwin/comin.nix") return "control-plane";
  return null;
}

function evaluate(plan, inventory) {
  const blockers = [];
  const notes = [];
  const separateReview = new Set();
  const usedEvidence = [];
  const evaluatedAt = timestamp(plan?.evaluated_at);
  const maximumAge = Number(plan?.maximum_evidence_age_seconds);
  const maximumRecoveryAge = Number(plan?.maximum_recovery_age_seconds);
  const maximumFutureSkew = Number(plan?.maximum_future_skew_seconds);
  const declaredChangedPaths = Array.isArray(plan?.changed_paths) ? uniq(plan.changed_paths) : [];

  const planFields = ["schema_version", "repository", "base_source_sha", "candidate_sha", "known_good_sha", "evaluated_at", "maximum_evidence_age_seconds", "maximum_recovery_age_seconds", "maximum_future_skew_seconds", "changed_paths", "evidence", "batches", "stop_conditions", "recovery", "rollout"];
  checkShape(plan, "plan", planFields, planFields, blockers);
  const inventoryFields = ["schema_version", "snapshot", "attestation", "hosts", "path_rules"];
  checkShape(inventory, "inventory", inventoryFields, inventoryFields, blockers);
  if (plan?.schema_version !== 2 || inventory?.schema_version !== 2) blockers.push(diagnostic("unsupported-schema", "plan and inventory must use schema_version 2"));
  if (plan?.repository !== "infrastructure/infra-private") blockers.push(diagnostic("repository-not-deploy-source", "only infrastructure/infra-private can be evaluated as a production rollout candidate"));
  if (!SHA_RE.test(plan?.base_source_sha ?? "") || !SHA_RE.test(plan?.candidate_sha ?? "") || !SHA_RE.test(plan?.known_good_sha ?? "")) blockers.push(diagnostic("invalid-revision", "base_source_sha, candidate_sha, and known_good_sha must be exact lowercase 40-character revisions"));
  else if (plan.candidate_sha === plan.known_good_sha) blockers.push(diagnostic("unchanged-revision", "candidate and known-good revisions must differ"));
  if (plan?.base_source_sha === plan?.candidate_sha) blockers.push(diagnostic("unchanged-source-revision", "candidate source must differ from its reviewed diff base"));
  if (evaluatedAt === null || !Number.isFinite(maximumAge) || maximumAge <= 0 || !Number.isFinite(maximumRecoveryAge) || maximumRecoveryAge <= 0 || !Number.isFinite(maximumFutureSkew) || maximumFutureSkew < 0) blockers.push(diagnostic("invalid-time-policy", "strict evaluated_at and positive evidence/recovery age bounds are required"));

  const snapshot = inventory?.snapshot ?? {};
  checkShape(snapshot, "inventory.snapshot", ["repository", "sha", "generated_at"], ["repository", "sha", "generated_at"], blockers);
  if (snapshot.repository !== plan?.repository || snapshot.sha !== plan?.candidate_sha) blockers.push(diagnostic("inventory-source-mismatch", "inventory snapshot must bind the same repository and candidate SHA", { expected_repository: plan?.repository ?? null, expected_sha: plan?.candidate_sha ?? null, actual_repository: snapshot.repository ?? null, actual_sha: snapshot.sha ?? null }));
  validateTime(snapshot.generated_at, evaluatedAt, maximumAge, maximumFutureSkew, { invalid: "invalid-inventory-time", future: "future-inventory", stale: "stale-inventory" }, {}, blockers);

  const attestation = inventory?.attestation ?? {};
  const attestationFields = ["method", "reviewed_by", "reviewed_at", "source_paths", "diff_base_sha", "changed_paths_sha256", "scope_sha256"];
  checkShape(attestation, "inventory.attestation", attestationFields, attestationFields, blockers);
  if (attestation.method !== "nix-eval-and-human-review" || !nonEmptyString(attestation.reviewed_by)) blockers.push(diagnostic("invalid-inventory-attestation", "inventory must record Nix evaluation plus an identified human review"));
  if (!Array.isArray(attestation.source_paths) || attestation.source_paths.length === 0 || attestation.source_paths.some((path) => !canonicalPath(path))) blockers.push(diagnostic("invalid-inventory-attestation", "inventory attestation needs canonical, non-empty source_paths"));
  validateTime(attestation.reviewed_at, evaluatedAt, maximumRecoveryAge, maximumFutureSkew, { invalid: "invalid-review-time", future: "future-review", stale: "stale-review" }, {}, blockers);
  if (attestation.diff_base_sha !== plan?.base_source_sha || attestation.changed_paths_sha256 !== digest(declaredChangedPaths)) blockers.push(diagnostic("changed-path-set-mismatch", "reviewed git diff path set does not match the plan", { expected_base: attestation.diff_base_sha ?? null, actual_base: plan?.base_source_sha ?? null, expected_paths_sha256: attestation.changed_paths_sha256 ?? null, actual_paths_sha256: digest(declaredChangedPaths) }));
  const actualScopeDigest = digest({ hosts: inventory?.hosts ?? [], path_rules: inventory?.path_rules ?? [] });
  if (!DIGEST_RE.test(attestation.scope_sha256 ?? "") || attestation.scope_sha256 !== actualScopeDigest) blockers.push(diagnostic("inventory-scope-mismatch", "reviewed inventory scope digest does not match hosts and path rules", { expected: attestation.scope_sha256 ?? null, actual: actualScopeDigest }));

  const hostsByName = new Map();
  if (!Array.isArray(inventory?.hosts) || inventory.hosts.length === 0) blockers.push(diagnostic("empty-host-inventory", "inventory must contain reviewed hosts"));
  for (const [index, host] of (inventory?.hosts ?? []).entries()) {
    const where = `inventory.hosts[${index}]`;
    const hostFields = ["name", "platform", "required_evidence", "recovery_channels", "staged_delivery"];
    checkShape(host, where, hostFields, hostFields, blockers);
    if (!nonEmptyString(host.name) || hostsByName.has(host.name)) {
      blockers.push(diagnostic("invalid-host-inventory", "inventory host names must be present and unique", { host: host.name ?? null }));
      continue;
    }
    hostsByName.set(host.name, host);
    if (host.platform !== "nixos") blockers.push(diagnostic("unsupported-staged-platform", "only NixOS hosts have the prepared Comin testing-branch mechanism", { host: host.name, platform: host.platform ?? null }));
    if (!Array.isArray(host.required_evidence) || host.required_evidence.length === 0) blockers.push(diagnostic("missing-evidence-contract", "each host needs required evidence", { host: host.name }));
    const evidenceKeys = new Set();
    for (const [contractIndex, contract] of (host.required_evidence ?? []).entries()) {
      const fields = ["kind", "source", "revision_role"];
      checkShape(contract, `${where}.required_evidence[${contractIndex}]`, fields, fields, blockers);
      if (!nonEmptyString(contract.kind) || !nonEmptyString(contract.source) || !["candidate", "known-good"].includes(contract.revision_role)) blockers.push(diagnostic("invalid-evidence-contract", "evidence kind/source/revision_role must be explicit", { host: host.name, index: contractIndex }));
      if (evidenceKeys.has(contract.kind)) blockers.push(diagnostic("duplicate-evidence-contract", "evidence kinds must be unique per host", { host: host.name, kind: contract.kind ?? null }));
      evidenceKeys.add(contract.kind);
    }
    if (!Array.isArray(host.recovery_channels) || host.recovery_channels.length === 0) blockers.push(diagnostic("missing-recovery-channel", "each host needs an independently verified recovery channel", { host: host.name }));
    const channelIds = new Set();
    for (const [channelIndex, channel] of (host.recovery_channels ?? []).entries()) {
      const fields = ["id", "kind", "independent_of", "verified_at", "available"];
      checkShape(channel, `${where}.recovery_channels[${channelIndex}]`, fields, fields, blockers);
      if (!nonEmptyString(channel.id) || channelIds.has(channel.id) || !["local-console", "out-of-band-console"].includes(channel.kind)) blockers.push(diagnostic("invalid-recovery-channel", "recovery channel must have a unique id and be local or out-of-band", { host: host.name, id: channel.id ?? null }));
      channelIds.add(channel.id);
      if (channel.available !== true || !Array.isArray(channel.independent_of) || INDEPENDENT_FROM.some((dependency) => !channel.independent_of.includes(dependency))) blockers.push(diagnostic("dependent-recovery-channel", "recovery channel must be available independently of Forgejo, n8n, Comin, and the production network", { host: host.name, id: channel.id ?? null }));
      validateTime(channel.verified_at, evaluatedAt, maximumRecoveryAge, maximumFutureSkew, { invalid: "invalid-recovery-channel-time", future: "future-recovery-channel", stale: "stale-recovery-channel" }, { host: host.name, channel: channel.id ?? null }, blockers);
    }
    const delivery = host.staged_delivery ?? {};
    const deliveryFields = ["mechanism", "service", "known_good_revision", "verified_at", "state"];
    checkShape(delivery, `${where}.staged_delivery`, deliveryFields, deliveryFields, blockers);
    if (delivery.mechanism !== "comin-service-hold" || delivery.service !== "comin.service" || delivery.known_good_revision !== plan?.known_good_sha || delivery.state !== "active") blockers.push(diagnostic("staged-delivery-not-ready", "host must have active Comin at the known-good revision before an approved service hold", { host: host.name }));
    validateTime(delivery.verified_at, evaluatedAt, maximumRecoveryAge, maximumFutureSkew, { invalid: "invalid-delivery-time", future: "future-delivery", stale: "stale-delivery" }, { host: host.name }, blockers);
  }

  const pathRules = Array.isArray(inventory?.path_rules) ? inventory.path_rules : [];
  if (pathRules.length === 0) blockers.push(diagnostic("empty-path-rules", "inventory must contain reviewed path rules"));
  for (const [index, rule] of pathRules.entries()) {
    const where = `inventory.path_rules[${index}]`;
    const ruleFields = ["match_kind", "prefix", "hosts", "services", "risk_domain", "runtime_impact", "shared", "consumer_basis"];
    checkShape(rule, where, ruleFields, ruleFields, blockers);
    if (!["file", "directory"].includes(rule.match_kind) || !canonicalPath(rule.prefix, { directory: rule.match_kind === "directory" })) blockers.push(diagnostic("invalid-path-rule", "path rules must distinguish a canonical exact file from a slash-terminated directory", { index, prefix: rule.prefix ?? null }));
    if (!Array.isArray(rule.hosts) || !Array.isArray(rule.services) || rule.hosts.some((host) => !nonEmptyString(host)) || rule.services.some((service) => !nonEmptyString(service))) blockers.push(diagnostic("invalid-path-impact", "path rule hosts and services must be string arrays", { index }));
    if (![true, false].includes(rule.runtime_impact)) blockers.push(diagnostic("invalid-runtime-impact", "runtime_impact must be explicit", { index }));
    if (rule.runtime_impact === true && ((rule.hosts?.length ?? 0) === 0 || (rule.services?.length ?? 0) === 0)) blockers.push(diagnostic("empty-runtime-impact", "runtime changes require at least one host and service", { index }));
    if (rule.runtime_impact === false && (rule.risk_domain !== "documentation" || (rule.hosts?.length ?? 0) !== 0 || (rule.services?.length ?? 0) !== 0)) blockers.push(diagnostic("invalid-no-runtime-impact", "documentation-only rules must explicitly have no hosts or services", { index }));
    if (!KNOWN_DOMAINS.has(rule.risk_domain)) blockers.push(diagnostic("unknown-risk-domain", "path rule has an unknown risk domain", { index, risk_domain: rule.risk_domain ?? null }));
    for (const host of rule.hosts ?? []) if (!hostsByName.has(host)) blockers.push(diagnostic("unknown-impact-host", "path rule names a host absent from inventory", { index, host }));
    const basis = rule.consumer_basis ?? {};
    const basisFields = ["method", "revision", "complete", "source_paths", "consumer_set_sha256"];
    checkShape(basis, `${where}.consumer_basis`, basisFields, basisFields, blockers);
    if (basis.method !== "nix-import-closure" || basis.revision !== plan?.candidate_sha || basis.complete !== true || !Array.isArray(basis.source_paths) || basis.source_paths.length === 0 || basis.source_paths.some((path) => !canonicalPath(path))) blockers.push(diagnostic("incomplete-consumer-basis", "every path rule needs a complete Nix import closure bound to the candidate revision", { index }));
    const consumerDigest = digest(uniq(rule.hosts ?? []));
    if (!DIGEST_RE.test(basis.consumer_set_sha256 ?? "") || basis.consumer_set_sha256 !== consumerDigest) blockers.push(diagnostic("consumer-set-mismatch", "path rule consumer set differs from its reviewed digest", { index, expected: basis.consumer_set_sha256 ?? null, actual: consumerDigest }));
    if (rule.shared === true && (rule.hosts?.length ?? 0) < 2) blockers.push(diagnostic("invalid-shared-impact", "a shared rule cannot collapse to a single host", { index }));
  }

  const changedPaths = declaredChangedPaths;
  if (!Array.isArray(plan?.changed_paths) || changedPaths.length === 0 || changedPaths.some((path) => !canonicalPath(path))) blockers.push(diagnostic("invalid-changed-paths", "changed_paths must be a non-empty array of canonical repository-relative file paths"));
  const impactedHosts = new Set();
  const impactedServices = new Set();
  const pathImpact = [];
  for (const path of changedPaths) {
    if (!canonicalPath(path)) continue;
    const matches = pathRules.filter((rule) => rule.match_kind === "file" ? path === rule.prefix : path.startsWith(rule.prefix));
    if (matches.length === 0) {
      blockers.push(diagnostic("unknown-path", "changed path has no reviewed impact rule", { path }));
      continue;
    }
    const pathHosts = new Set();
    const pathServices = new Set();
    const semanticRisk = inferredRisk(path);
    if (semanticRisk) {
      separateReview.add(semanticRisk);
      blockers.push(diagnostic("separate-review-required", "path is in a protected risk domain", { path, risk_domain: semanticRisk }));
    }
    for (const rule of matches) {
      if (rule.risk_domain === "unclassified") blockers.push(diagnostic("unclassified-risk", "broad directory rules cannot establish a low-risk change; add an exact reviewed rule", { path, prefix: rule.prefix }));
      if (SEPARATE_REVIEW_DOMAINS.has(rule.risk_domain)) {
        separateReview.add(rule.risk_domain);
        blockers.push(diagnostic("separate-review-required", "risk domain cannot be promoted by this low-risk planner", { path, risk_domain: rule.risk_domain }));
      }
      for (const host of rule.hosts ?? []) { pathHosts.add(host); impactedHosts.add(host); }
      for (const service of rule.services ?? []) { pathServices.add(service); impactedServices.add(service); }
    }
    pathImpact.push({ path, hosts: uniq(pathHosts), services: uniq(pathServices) });
  }
  const expectedHosts = uniq(impactedHosts);
  if (pathImpact.some(({ hosts, services }) => hosts.length === 0 || services.length === 0)) blockers.push(diagnostic("empty-effective-impact", "every runtime path must resolve to hosts and services"));

  const evidence = Array.isArray(plan?.evidence) ? plan.evidence : [];
  if (!Array.isArray(plan?.evidence)) blockers.push(diagnostic("invalid-evidence", "evidence must be an array"));
  for (const [index, entry] of evidence.entries()) {
    const fields = ["host", "kind", "source", "repository", "sha", "status", "observed_at"];
    checkShape(entry, `plan.evidence[${index}]`, fields, fields, blockers);
    if (![entry.host, entry.kind, entry.source, entry.repository, entry.sha, entry.status, entry.observed_at].every(nonEmptyString)) blockers.push(diagnostic("invalid-evidence-record", "evidence fields must be explicit non-empty strings", { index }));
  }
  for (const hostName of expectedHosts) {
    const host = hostsByName.get(hostName);
    if (!host) continue;
    for (const contract of host.required_evidence ?? []) {
      if (!nonEmptyString(contract.kind) || !nonEmptyString(contract.source)) continue;
      const matches = evidence.filter((entry) => entry.host === hostName && entry.kind === contract.kind);
      if (matches.length !== 1) {
        blockers.push(diagnostic(matches.length === 0 ? "missing-evidence" : "duplicate-evidence", "exactly one evidence record is required for each impacted host and kind", { host: hostName, kind: contract.kind, count: matches.length }));
        continue;
      }
      const entry = matches[0];
      usedEvidence.push({ host: entry.host, kind: entry.kind, source: entry.source, repository: entry.repository, sha: entry.sha, status: entry.status, observed_at: entry.observed_at });
      const expectedSha = contract.revision_role === "known-good" ? plan.known_good_sha : plan.candidate_sha;
      if (entry.source !== contract.source || entry.repository !== plan.repository || entry.sha !== expectedSha) blockers.push(diagnostic("evidence-source-mismatch", "evidence source, repository, or role-bound SHA does not match its contract", { host: hostName, kind: contract.kind, expected_source: contract.source, expected_sha: expectedSha, actual_source: entry.source ?? null, actual_sha: entry.sha ?? null }));
      validateTime(entry.observed_at, evaluatedAt, maximumAge, maximumFutureSkew, { invalid: "invalid-evidence-time", future: "future-evidence", stale: "stale-evidence" }, { host: hostName, kind: contract.kind }, blockers);
      if (entry.status !== "healthy") blockers.push(diagnostic(entry.status ? "unhealthy-evidence" : "unknown-evidence", "only an explicit healthy observation is eligible", { host: hostName, kind: contract.kind, status: entry.status ?? null }));
    }
  }

  const batches = Array.isArray(plan?.batches) ? plan.batches : [];
  if (!Array.isArray(plan?.batches)) blockers.push(diagnostic("invalid-batches", "batches must be an array"));
  const batchHosts = [];
  for (const [index, batch] of batches.entries()) {
    const fields = ["name", "hosts", "minimum_observation_seconds"];
    checkShape(batch, `plan.batches[${index}]`, fields, fields, blockers);
    if (!nonEmptyString(batch.name) || !Array.isArray(batch.hosts) || batch.hosts.length === 0 || !Number.isInteger(batch.minimum_observation_seconds) || batch.minimum_observation_seconds < 300) blockers.push(diagnostic("invalid-batch", "each rollout batch needs a name, hosts, and at least a 300-second observation window", { index }));
    else batchHosts.push(...batch.hosts);
  }
  const duplicateBatchHosts = uniq(batchHosts.filter((host, index) => batchHosts.indexOf(host) !== index));
  if (duplicateBatchHosts.length > 0 || JSON.stringify(uniq(batchHosts)) !== JSON.stringify(expectedHosts)) blockers.push(diagnostic("batch-impact-mismatch", "batches must contain every impacted host exactly once and no other host", { impacted_hosts: expectedHosts, batch_hosts: uniq(batchHosts), duplicate_hosts: duplicateBatchHosts }));
  if ((batches[0]?.hosts?.length ?? 0) !== 1 && expectedHosts.length > 1) blockers.push(diagnostic("missing-canary", "the first batch must contain exactly one host when more than one host is affected"));

  const recoveryEntries = Array.isArray(plan?.recovery) ? plan.recovery : [];
  if (!Array.isArray(plan?.recovery)) blockers.push(diagnostic("invalid-recovery", "recovery must be an array"));
  for (const [index, recovery] of recoveryEntries.entries()) {
    const fields = ["host", "known_good_sha", "channel_id", "stop_service", "generation", "verified_at", "available"];
    checkShape(recovery, `plan.recovery[${index}]`, fields, fields, blockers);
    const stopFields = ["executable", "args"];
    checkShape(recovery.stop_service ?? {}, `plan.recovery[${index}].stop_service`, stopFields, stopFields, blockers);
    const generationFields = ["number", "revision", "store_path", "executable", "args"];
    checkShape(recovery.generation ?? {}, `plan.recovery[${index}].generation`, generationFields, generationFields, blockers);
  }
  for (const hostName of expectedHosts) {
    const entries = recoveryEntries.filter((entry) => entry.host === hostName);
    if (entries.length !== 1) {
      blockers.push(diagnostic(entries.length === 0 ? "missing-recovery-evidence" : "duplicate-recovery-evidence", "exactly one recovery record is required per impacted host", { host: hostName, count: entries.length }));
      continue;
    }
    const recovery = entries[0];
    const host = hostsByName.get(hostName);
    const channel = host?.recovery_channels?.find((candidate) => candidate.id === recovery.channel_id);
    const generation = recovery.generation ?? {};
    if (recovery.known_good_sha !== plan.known_good_sha || generation.revision !== plan.known_good_sha) blockers.push(diagnostic("recovery-revision-mismatch", "recovery and local generation must bind the plan known-good revision", { host: hostName }));
    if (!channel) blockers.push(diagnostic("unknown-recovery-channel", "recovery references an unreviewed channel", { host: hostName, channel: recovery.channel_id ?? null }));
    if (recovery.stop_service?.executable !== "/run/current-system/sw/bin/systemctl" || JSON.stringify(recovery.stop_service?.args) !== JSON.stringify(["stop", "comin.service"])) blockers.push(diagnostic("invalid-recovery-stop", "host-local recovery must stop Comin before switching the known-good generation", { host: hostName }));
    if (recovery.available !== true || !Number.isInteger(generation.number) || generation.number <= 0 || !STORE_PATH_RE.test(generation.store_path ?? "")) blockers.push(diagnostic("invalid-local-generation", "recovery needs an available positive local generation and exact Nix store path", { host: hostName }));
    const expectedExecutable = `${generation.store_path}/bin/switch-to-configuration`;
    if (generation.executable !== expectedExecutable || JSON.stringify(generation.args) !== JSON.stringify(["switch"])) blockers.push(diagnostic("invalid-recovery-command", "NixOS recovery must execute switch-to-configuration from the verified local generation", { host: hostName, expected_executable: expectedExecutable }));
    validateTime(recovery.verified_at, evaluatedAt, maximumRecoveryAge, maximumFutureSkew, { invalid: "invalid-recovery-time", future: "future-recovery", stale: "stale-recovery" }, { host: hostName }, blockers);
  }
  const extraRecoveryHosts = uniq(recoveryEntries.map(({ host }) => host).filter((host) => !expectedHosts.includes(host)));
  if (extraRecoveryHosts.length > 0) blockers.push(diagnostic("unexpected-recovery", "recovery contains hosts outside the effective impact", { hosts: extraRecoveryHosts }));

  const stopConditions = Array.isArray(plan?.stop_conditions) ? uniq(plan.stop_conditions) : [];
  for (const condition of ["candidate-revision-drift", "control-channel-unavailable", "evidence-unhealthy-or-missing", "host-or-service-regression"]) if (!stopConditions.includes(condition)) blockers.push(diagnostic("missing-stop-condition", "required rollout stop condition is absent", { condition }));

  const rollout = plan?.rollout ?? {};
  const rolloutFields = ["mechanism", "main_branch", "control_channel_status", "candidate_prod_sha", "promotion_source_sha", "promotion_observed_at"];
  checkShape(rollout, "plan.rollout", rolloutFields, rolloutFields, blockers);
  if (rollout.mechanism !== "comin-service-hold" || rollout.main_branch !== "prod") blockers.push(diagnostic("invalid-rollout-mechanism", "staged rollout must hold non-current Comin services and retain the existing prod release path"));
  if (rollout.control_channel_status !== "available") blockers.push(diagnostic("control-channel-unavailable", "no release or later Comin batch may advance while the control channel is unavailable"));
  const promotionPending = rollout.candidate_prod_sha === null && rollout.promotion_source_sha === null && rollout.promotion_observed_at === null;
  if (!promotionPending) {
    if (!SHA_RE.test(rollout.candidate_prod_sha ?? "") || rollout.candidate_prod_sha === plan?.known_good_sha || rollout.promotion_source_sha !== plan?.candidate_sha) blockers.push(diagnostic("invalid-promotion-evidence", "candidate prod revision must be exact, differ from known-good, and carry the candidate Source-Commit"));
    validateTime(rollout.promotion_observed_at, evaluatedAt, maximumAge, maximumFutureSkew, { invalid: "invalid-promotion-time", future: "future-promotion", stale: "stale-promotion" }, {}, blockers);
  }

  const expectedDeployment = (host, useCandidate) => useCandidate ? {
    host,
    prod_revision: rollout.candidate_prod_sha,
    source_revision: plan.candidate_sha,
    state: promotionPending ? "awaiting-exact-promotion-proof" : "candidate-promotion",
  } : {
    host,
    prod_revision: plan.known_good_sha,
    source_revision: null,
    state: "held-known-good",
  };

  const stages = [];
  const canaryHosts = new Set(batches[0]?.hosts ?? []);
  const initiallyHeld = expectedHosts.filter((host) => !canaryHosts.has(host));
  stages.push({
    name: "pre-release-hold",
    minimum_observation_seconds: 0,
    actions: rollout.control_channel_status === "available" ? initiallyHeld.map((host) => ({ action: "stop-service", host, service: "comin.service", requires_existing_human_approval: true })) : [],
    expected_revisions: expectedHosts.map((host) => expectedDeployment(host, false)),
    held_hosts: initiallyHeld,
    success_conditions: ["held Comin services are inactive", "all hosts still report known-good", "canary Comin remains active"],
  });
  const advanced = new Set(canaryHosts);
  if (batches[0]) {
    stages.push({
      name: batches[0].name,
      minimum_observation_seconds: batches[0].minimum_observation_seconds,
      actions: rollout.control_channel_status === "available" ? [{ action: "use-existing-production-release", repository: plan.repository, revision: plan.candidate_sha, branch: "prod", requires_existing_human_approval: true }] : [],
      expected_revisions: expectedHosts.map((host) => expectedDeployment(host, advanced.has(host))),
      held_hosts: expectedHosts.filter((host) => !advanced.has(host)),
      success_conditions: ["canary reports the exact prod promotion whose Source-Commit is the candidate", "required evidence remains healthy for the full observation window", "held hosts remain at known-good"],
    });
  }
  for (const batch of batches.slice(1)) {
    for (const host of batch.hosts ?? []) advanced.add(host);
    stages.push({
      name: batch.name,
      minimum_observation_seconds: batch.minimum_observation_seconds,
      actions: rollout.control_channel_status === "available" ? (batch.hosts ?? []).map((host) => ({ action: "start-service", host, service: "comin.service", expected_revision: plan.candidate_sha, requires_existing_human_approval: true })) : [],
      expected_revisions: expectedHosts.map((host) => expectedDeployment(host, advanced.has(host))),
      held_hosts: expectedHosts.filter((host) => !advanced.has(host)),
      success_conditions: ["current batch reports the exact verified prod promotion", "required evidence remains healthy for the full observation window", "still-held hosts remain at known-good"],
    });
  }

  if (blockers.length === 0) notes.push(diagnostic("candidate-only", "all offline checks passed; this is only a candidate for the existing human release review"));
  return {
    schema_version: 2,
    recommendation: blockers.length === 0 ? "candidate-for-human-review" : "blocked",
    authorized: false,
    repository: plan?.repository ?? null,
    candidate_sha: plan?.candidate_sha ?? null,
    known_good_sha: plan?.known_good_sha ?? null,
    evaluated_at: plan?.evaluated_at ?? null,
    inventory_attestation: { scope_sha256: attestation.scope_sha256 ?? null, method: attestation.method ?? null, reviewed_by: attestation.reviewed_by ?? null, reviewed_at: attestation.reviewed_at ?? null },
    impact: { paths: changedPaths, hosts: expectedHosts, services: uniq(impactedServices), path_details: pathImpact },
    observations: usedEvidence.sort((left, right) => `${left.host}/${left.kind}`.localeCompare(`${right.host}/${right.kind}`)),
    rollout: {
      mechanism: rollout.mechanism ?? null,
      main_branch: rollout.main_branch ?? null,
      invariant: `all non-canary Comin services are stopped before the existing production release advances prod from ${plan?.known_good_sha ?? "unknown"}; only the current batch is started afterward`,
      stages,
      final_completion: { action: "verify-all-services-restored", prod_revision: rollout.candidate_prod_sha ?? null, source_revision: plan?.candidate_sha ?? null, requires_existing_human_approval: true },
      on_control_failure: "stop; do not start another Comin service; use only the verified host-local stop-and-generation recovery records below",
    },
    stop_conditions: stopConditions,
    separate_review_domains: uniq(separateReview),
    recovery: recoveryEntries.map((entry) => ({ host: entry.host ?? null, known_good_sha: entry.known_good_sha ?? null, channel_id: entry.channel_id ?? null, stop_service: entry.stop_service ?? null, generation: entry.generation ?? null, verified_at: entry.verified_at ?? null, available: entry.available ?? null })),
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
  output = { schema_version: 2, recommendation: "blocked", authorized: false, blockers: [diagnostic("invalid-input", error.message)] };
}

const rendered = `${JSON.stringify(output, null, 2)}\n`;
if (outputPath) writeFileSync(outputPath, rendered);
else process.stdout.write(rendered);
process.exitCode = output.recommendation === "candidate-for-human-review" ? 0 : 2;
