#!/usr/bin/env python3
"""Validate the disconnected Grafana OIDC preparation package."""

from __future__ import annotations

import pathlib
import subprocess
import sys

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[1]
AUTH_PREP = ROOT / "wanxiang/kubernetes/apps/identity/authentik/grafana-oidc-prep"
MONITORING_PREP = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/grafana-oidc-prep"
AUTH_APP = ROOT / "wanxiang/kubernetes/apps/identity/authentik/app"
MONITORING_APP = ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/app"


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


def main() -> None:
    blueprint = load(AUTH_PREP / "blueprints/grafana-oidc.yaml", BlueprintLoader)
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
        if "grafana-oidc-prep" in parent.read_text(encoding="utf-8"):
            fail(f"live Flux reference found in {parent}")
    if load(ROOT / "wanxiang/kubernetes/apps/identity/authentik/ks.yaml")["spec"]["path"] != "./wanxiang/kubernetes/apps/identity/authentik/app":
        fail("the live Authentik Flux path must remain the app path")
    if load(ROOT / "wanxiang/kubernetes/apps/monitoring/prometheus-stack/ks.yaml")["spec"]["path"] != "./wanxiang/kubernetes/apps/monitoring/prometheus-stack/app":
        fail("the live monitoring Flux path must remain the app path")

    for prep in (AUTH_PREP, MONITORING_PREP):
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

    print("Grafana OIDC preparation passed: schema, closed references, fail-closed secrets, group restriction, and disconnected renders")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, KeyError, TypeError, yaml.YAMLError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
