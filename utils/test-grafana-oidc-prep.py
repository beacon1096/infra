#!/usr/bin/env python3
"""Validate the disconnected Grafana OIDC preparation package."""

from __future__ import annotations

import copy
import importlib.util
import pathlib
import subprocess
import sys

import yaml

sys.dont_write_bytecode = True


ROOT = pathlib.Path(__file__).resolve().parents[1]
AUTH_PREP = ROOT / "wanxiang/kubernetes/apps/identity/authentik/grafana-oidc-prep"
AUTH_REENTRY_PREP = ROOT / "wanxiang/kubernetes/apps/identity/authentik/grafana-oidc-reentry-prep"
AUTH_ROLLBACK = ROOT / "wanxiang/kubernetes/apps/identity/authentik/grafana-oidc-rollback"
MONITORING_PREP = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/grafana-oidc-prep"
MONITORING_ROLLBACK = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/grafana-oidc-rollback"
AUTH_APP = ROOT / "wanxiang/kubernetes/apps/identity/authentik/app"
MONITORING_APP = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/app"
CONTRACT_PATH = ROOT / "utils/check_grafana_oidc_contract.py"


CONTRACT_SPEC = importlib.util.spec_from_file_location("grafana_oidc_contract", CONTRACT_PATH)
CONTRACT = importlib.util.module_from_spec(CONTRACT_SPEC)
assert CONTRACT_SPEC.loader is not None
CONTRACT_SPEC.loader.exec_module(CONTRACT)


class BlueprintLoader(yaml.SafeLoader):
    pass


def blueprint_tag(loader, node):
    if isinstance(node, yaml.SequenceNode):
        return [loader.construct_object(item) for item in node.value]
    return loader.construct_scalar(node)


for tag in ("!Context", "!Env", "!Find", "!KeyOf"):
    BlueprintLoader.add_constructor(tag, blueprint_tag)


def load(path: pathlib.Path, loader=yaml.SafeLoader):
    return yaml.load(path.read_text(encoding="utf-8"), Loader=loader)


def fail(message: str) -> None:
    raise AssertionError(message)


def entry_map(blueprint):
    return {entry["id"]: entry for entry in blueprint["entries"]}


def render(path: pathlib.Path):
    result = subprocess.run(
        ["kubectl", "kustomize", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return list(yaml.safe_load_all(result.stdout))


def named(documents, kind, name):
    for document in documents:
        if document and document.get("kind") == kind and document.get("metadata", {}).get("name") == name:
            return document
    fail(f"missing {kind}/{name}")


def has_named(documents, kind, name):
    return any(
        document
        and document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
        for document in documents
    )


def preflight_evidence(mode):
    objects = {
        "group": {
            "exists": mode == "reentry",
            "name": "Grafana Viewers",
            "is_superuser": False,
            "members": [],
        },
        "provider": {
            "exists": mode == "reentry",
            "name": "Grafana @ Beacoworks",
            "client_type": "confidential",
            "application_slug": "grafana",
            "property_mappings": ["openid", "profile", "email"],
            "issuer_mode": "per_provider",
            "sub_mode": "hashed_user_id",
            "redirect_uris": [
                {"matching_mode": "strict", "url": "https://grafana.beaco.works/login/generic_oauth"}
            ],
        },
        "application": {
            "exists": mode == "reentry",
            "name": "Grafana @ Beacoworks",
            "slug": "grafana",
            "provider_name": "Grafana @ Beacoworks",
            "policy_engine_mode": "any",
            "bindings": [],
        },
    }
    if mode == "reentry":
        for index, obj in enumerate(objects.values(), start=1):
            obj["id"] = f"opaque-object-{index}"
        objects["application"]["bindings"] = [
            {
                "target": "grafana",
                "group": "Grafana Viewers",
                "user": None,
                "policy": None,
                "order": 0,
                "enabled": True,
                "negate": False,
            }
        ]
    ownership_ids = {}
    if mode == "reentry":
        ownership_ids = {name: obj["id"] for name, obj in objects.items()}
    return {
        "schema_version": 1,
        "source": "authentik-read-only-metadata",
        "observed_at": "2026-10-28T10:00:00Z",
        "owner": "grafana-oidc-prep",
        "approval_ref": "BEACO-247",
        "ownership": {
            "scope": "grafana-oidc",
            "managed_by": "grafana-oidc-prep",
            "verified": True,
            "object_ids": ownership_ids,
        },
        "mode": mode,
        "objects": objects,
    }


def assert_contract_rejects(evidence, message):
    try:
        CONTRACT.validate_evidence(evidence)
    except CONTRACT.ContractError:
        return
    fail(message)


def main() -> None:
    blueprint = load(AUTH_PREP / "blueprints/grafana-oidc.yaml", BlueprintLoader)
    reentry_blueprint = load(AUTH_REENTRY_PREP / "blueprints/grafana-oidc.yaml", BlueprintLoader)
    if blueprint["version"] != 1:
        fail("unexpected blueprint version")
    auth_chart = load(AUTH_APP / "ocirepository.yaml")
    if auth_chart["spec"]["ref"]["tag"] != "2026.2.2":
        fail("the Blueprint contract must be reviewed against Authentik chart 2026.2.2")
    if blueprint["context"] != {
        "client_id": ["AUTHENTIK_GRAFANA_OIDC_CLIENT_ID", None],
        "client_secret": ["AUTHENTIK_GRAFANA_OIDC_CLIENT_SECRET", None],
    }:
        fail("blueprint credentials must be required environment inputs")

    entries = entry_map(blueprint)
    reentry_entries = entry_map(reentry_blueprint)
    if {entry["state"] for entry in entries.values()} != {"must_created"}:
        fail("the create Blueprint must reject every existing target object")
    if {entry["state"] for entry in reentry_entries.values()} != {"present"}:
        fail("the reentry Blueprint must be separate from the create mode")
    if set(entries) != set(reentry_entries):
        fail("create/reentry Blueprint entries drifted")
    for entry_id in entries:
        create_entry = copy.deepcopy(entries[entry_id])
        reentry_entry = copy.deepcopy(reentry_entries[entry_id])
        create_entry.pop("state")
        reentry_entry.pop("state")
        if create_entry != reentry_entry:
            fail(f"create/reentry Blueprint drifted for {entry_id}")

    CONTRACT.validate_evidence(preflight_evidence("create"))
    CONTRACT.validate_evidence(preflight_evidence("reentry"))
    nonempty_group = preflight_evidence("reentry")
    nonempty_group["objects"]["group"]["members"] = ["opaque-user-1"]
    assert_contract_rejects(nonempty_group, "non-empty same-name groups must be rejected")
    extra_binding = preflight_evidence("reentry")
    extra_binding["objects"]["application"]["bindings"].append(
        {"target": "grafana", "group": "Other Group", "user": None, "policy": None, "order": 1, "enabled": True, "negate": False}
    )
    assert_contract_rejects(extra_binding, "extra application bindings must be rejected")
    missing_evidence = preflight_evidence("reentry")
    del missing_evidence["objects"]["application"]["bindings"]
    assert_contract_rejects(missing_evidence, "missing preflight evidence must be rejected")

    group = entries["grafana-viewers"]
    if group["model"] != "authentik_core.group" or group["identifiers"] != {"name": "Grafana Viewers"}:
        fail("unexpected Grafana access group")
    if group["attrs"] != {"is_superuser": False}:
        fail("Grafana access group must not grant superuser access or memberships")

    provider = entries["grafana-provider"]
    provider_attrs = provider["attrs"]
    if provider_attrs["client_id"] != "client_id" or provider_attrs["client_secret"] != "client_secret":
        fail("provider credentials must come from worker environment")
    if provider_attrs["redirect_uris"] != [
        {"matching_mode": "strict", "url": "https://grafana.beaco.works/login/generic_oauth"}
    ]:
        fail("redirect URI is not exact and strict")
    if provider_attrs["client_type"] != "confidential":
        fail("Grafana provider must be confidential")
    if provider_attrs["property_mappings"] != [
        ["authentik_providers_oauth2.scopemapping", ["managed", "goauthentik.io/providers/oauth2/scope-openid"]],
        ["authentik_providers_oauth2.scopemapping", ["managed", "goauthentik.io/providers/oauth2/scope-profile"]],
        ["authentik_providers_oauth2.scopemapping", ["managed", "goauthentik.io/providers/oauth2/scope-email"]],
    ]:
        fail("OIDC property mappings are not the reviewed openid/profile/email set")

    application = entries["grafana-application"]
    if application["identifiers"] != {"slug": "grafana"}:
        fail("unexpected Grafana application slug")
    binding = entries["grafana-access-binding"]
    if binding["identifiers"]["group"] != "grafana-viewers" or binding["identifiers"]["target"] != "grafana-application":
        fail("Grafana application is not restricted to the named group")

    auth_patch = load(AUTH_PREP / "authentik-helmrelease.patch.yaml")
    auth_values = auth_patch["spec"]["values"]
    if auth_values["blueprints"]["configMaps"] != ["authentik-grafana-oidc-blueprint"]:
        fail("Auth worker blueprint ConfigMap reference is not closed")
    if auth_values["worker"]["envFrom"] != [{"secretRef": {"name": "authentik-grafana-oidc"}}]:
        fail("Auth worker Secret reference is not worker-local")

    grafana_patch = load(MONITORING_PREP / "grafana-helmrelease.patch.yaml")
    if grafana_patch["spec"]["values"]["grafana"]["envFromSecret"] != "grafana-oidc":
        fail("Grafana Secret reference is not closed")

    grafana_values = load(MONITORING_APP / "helmrelease.yaml")["spec"]["values"]["grafana"]
    if grafana_values["envFromSecret"] != "grafana-oidc":
        fail("live Grafana contract drifted from grafana-oidc")
    if grafana_values["grafana.ini"]["auth.generic_oauth"]["enabled"] is not True:
        fail("live Grafana OIDC is not enabled")
    if grafana_values["grafana.ini"]["auth.anonymous"]["enabled"] is not False:
        fail("live Grafana anonymous access must remain disabled")
    if grafana_values["grafana.ini"]["users"]["auto_assign_org_role"] != "Viewer":
        fail("live Grafana default role must remain Viewer")

    for parent in (
        ROOT / "wanxiang/kubernetes/apps/identity/kustomization.yaml",
        ROOT / "wanxiang/kubernetes/apps/identity/authentik/ks.yaml",
        ROOT / "wanxiang/kubernetes/apps/monitoring/kustomization.yaml",
        ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/ks.yaml",
    ):
        parent_text = parent.read_text(encoding="utf-8")
        if any(overlay in parent_text for overlay in ("grafana-oidc-prep", "grafana-oidc-reentry-prep", "grafana-oidc-rollback")):
            fail(f"live Flux reference found in {parent}")
    if load(ROOT / "wanxiang/kubernetes/apps/identity/authentik/ks.yaml")["spec"]["path"] != "./wanxiang/kubernetes/apps/identity/authentik/app":
        fail("the live Authentik Flux path must remain the app path")
    if load(ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/ks.yaml")["spec"]["path"] != "./wanxiang/kubernetes/apps/monitoring/prometheus-stack/app":
        fail("the live monitoring Flux path must remain the app path")

    for prep in (AUTH_PREP, AUTH_REENTRY_PREP, MONITORING_PREP, AUTH_ROLLBACK, MONITORING_ROLLBACK):
        documents = render(prep)
        if any(
            document
            and document.get("kind") == "Secret"
            and document.get("metadata", {}).get("name") in {"authentik-grafana-oidc", "grafana-oidc"}
            for document in documents
        ):
            fail(f"{prep} must not create a credential Secret before approval")

    auth_documents = render(AUTH_PREP)
    auth_release = named(auth_documents, "HelmRelease", "authentik")
    if auth_release["spec"]["values"]["worker"]["envFrom"] != [
        {"secretRef": {"name": "authentik-grafana-oidc"}}
    ]:
        fail("rendered Auth worker Secret reference drifted")
    if auth_release["spec"]["values"]["blueprints"]["configMaps"] != [
        "authentik-grafana-oidc-blueprint"
    ]:
        fail("rendered Auth blueprint reference drifted")

    monitoring_documents = render(MONITORING_PREP)
    monitoring_release = named(monitoring_documents, "HelmRelease", "kube-prometheus-stack")
    if monitoring_release["spec"]["values"]["grafana"]["envFromSecret"] != "grafana-oidc":
        fail("rendered Grafana Secret reference drifted")

    reentry_documents = render(AUTH_REENTRY_PREP)
    reentry_release = named(reentry_documents, "HelmRelease", "authentik")
    if reentry_release["spec"]["values"]["worker"]["envFrom"] != [
        {"secretRef": {"name": "authentik-grafana-oidc"}}
    ]:
        fail("rendered reentry Auth worker Secret reference drifted")

    rollback_auth_documents = render(AUTH_ROLLBACK)
    rollback_auth_release = named(rollback_auth_documents, "HelmRelease", "authentik")
    rollback_auth_values = rollback_auth_release["spec"]["values"]
    if rollback_auth_values["blueprints"]["configMaps"] != [] or rollback_auth_values["worker"]["envFrom"] != []:
        fail("Auth rollback must remove the Blueprint and worker Secret consumer")
    if has_named(rollback_auth_documents, "ConfigMap", "authentik-grafana-oidc-blueprint"):
        fail("Auth rollback must not render the Grafana Blueprint ConfigMap")

    rollback_monitoring_documents = render(MONITORING_ROLLBACK)
    rollback_monitoring_release = named(rollback_monitoring_documents, "HelmRelease", "kube-prometheus-stack")
    rollback_grafana = rollback_monitoring_release["spec"]["values"]["grafana"]
    if rollback_grafana["enabled"] is not False or rollback_grafana.get("envFromSecret") is not None:
        fail("Grafana rollback must disable the workload and Secret reference")
    if has_named(rollback_monitoring_documents, "HTTPRoute", "grafana"):
        fail("Grafana rollback must remove the public route")
    base_values = load(MONITORING_APP / "helmrelease.yaml")["spec"]["values"]
    rollback_values = rollback_monitoring_release["spec"]["values"]
    for workload in ("prometheus", "alertmanager"):
        if rollback_values[workload] != base_values[workload]:
            fail(f"Grafana rollback must not change {workload}")

    print("Grafana OIDC preparation passed: static contract, preflight negatives, closed references, and disconnected renders")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, TypeError, yaml.YAMLError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
