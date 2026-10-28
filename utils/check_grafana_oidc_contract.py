#!/usr/bin/env python3
"""Check non-secret Authentik evidence before using a Grafana OIDC Blueprint."""

from __future__ import annotations

import json
import pathlib
import sys
from collections.abc import Mapping

sys.dont_write_bytecode = True


EXPECTED_GROUP = "Grafana Viewers"
EXPECTED_PROVIDER = "Grafana @ Beacoworks"
EXPECTED_APPLICATION = "Grafana @ Beacoworks"
EXPECTED_SLUG = "grafana"
EXPECTED_REDIRECT = [
    {"matching_mode": "strict", "url": "https://grafana.beaco.works/login/generic_oauth"}
]
EXPECTED_BINDING = {
    "target": EXPECTED_SLUG,
    "group": EXPECTED_GROUP,
    "user": None,
    "policy": None,
    "order": 0,
    "enabled": True,
    "negate": False,
}


class ContractError(ValueError):
    pass


def _mapping(value, field: str) -> Mapping:
    if not isinstance(value, Mapping):
        raise ContractError(f"{field} must be an object")
    return value


def _text(value, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{field} must be a non-empty string")
    return value


def _object(objects: Mapping, name: str) -> Mapping:
    return _mapping(objects.get(name), f"objects.{name}")


def _existing(obj: Mapping, field: str) -> bool:
    value = obj.get("exists")
    if not isinstance(value, bool):
        raise ContractError(f"{field}.exists must be boolean")
    return value


def _check_target_metadata(objects: Mapping) -> tuple[Mapping, Mapping, Mapping]:
    expected_objects = {"group", "provider", "application"}
    if set(objects) != expected_objects:
        raise ContractError("objects must contain exactly group, provider, and application")

    group = _object(objects, "group")
    if group.get("name") != EXPECTED_GROUP:
        raise ContractError("group name does not match the Grafana OIDC contract")
    if group.get("is_superuser") is not False:
        raise ContractError("Grafana group must explicitly be non-superuser")
    members = group.get("members")
    if not isinstance(members, list) or not all(isinstance(member, str) for member in members):
        raise ContractError("group.members must be a list of opaque non-secret IDs")

    provider = _object(objects, "provider")
    if provider.get("name") != EXPECTED_PROVIDER:
        raise ContractError("provider name does not match the Grafana OIDC contract")
    if provider.get("client_type") != "confidential":
        raise ContractError("provider must be confidential")
    if provider.get("application_slug") != EXPECTED_SLUG:
        raise ContractError("provider/application relationship is not exact")
    if provider.get("redirect_uris") != EXPECTED_REDIRECT:
        raise ContractError("provider redirect URI is not the exact strict callback")
    if provider.get("property_mappings") != ["openid", "profile", "email"]:
        raise ContractError("provider scopes are not the reviewed openid/profile/email set")
    if provider.get("issuer_mode") != "per_provider" or provider.get("sub_mode") != "hashed_user_id":
        raise ContractError("provider issuer or subject mode is not reviewed")

    application = _object(objects, "application")
    if application.get("name") != EXPECTED_APPLICATION:
        raise ContractError("application name does not match the Grafana OIDC contract")
    if application.get("slug") != EXPECTED_SLUG:
        raise ContractError("application slug does not match the Grafana OIDC contract")
    if application.get("provider_name") != EXPECTED_PROVIDER:
        raise ContractError("application/provider relationship is not exact")
    if application.get("policy_engine_mode") != "any":
        raise ContractError("application policy_engine_mode must be any")
    if not isinstance(application.get("bindings"), list):
        raise ContractError("application.bindings must be a list")

    return group, provider, application


def validate_evidence(document: object) -> None:
    evidence = _mapping(document, "evidence")
    if evidence.get("schema_version") != 1:
        raise ContractError("schema_version must be 1")
    if evidence.get("source") != "authentik-read-only-metadata":
        raise ContractError("source must identify a read-only Authentik metadata export")
    _text(evidence.get("observed_at"), "observed_at")
    if evidence.get("owner") != "grafana-oidc-prep":
        raise ContractError("owner must be grafana-oidc-prep")
    if evidence.get("approval_ref") != "BEACO-247":
        raise ContractError("approval_ref must identify BEACO-247")
    ownership = _mapping(evidence.get("ownership"), "ownership")
    if (
        ownership.get("scope") != "grafana-oidc"
        or ownership.get("managed_by") != "grafana-oidc-prep"
        or ownership.get("verified") is not True
    ):
        raise ContractError("Grafana OIDC ownership must be explicitly verified")
    ownership_ids = ownership.get("object_ids")
    if not isinstance(ownership_ids, Mapping):
        raise ContractError("ownership.object_ids must be an object")

    mode = evidence.get("mode")
    if mode not in {"create", "reentry"}:
        raise ContractError("mode must be create or reentry")

    objects = _mapping(evidence.get("objects"), "objects")
    group, provider, application = _check_target_metadata(objects)
    existing = {
        "group": _existing(group, "objects.group"),
        "provider": _existing(provider, "objects.provider"),
        "application": _existing(application, "objects.application"),
    }

    if mode == "create":
        if any(existing.values()):
            raise ContractError("create mode rejects every existing target object")
        if any("id" in obj for obj in (group, provider, application)):
            raise ContractError("create mode must not carry existing object IDs")
        if ownership_ids:
            raise ContractError("create mode must not carry existing object IDs")
        if group["members"] or application["bindings"]:
            raise ContractError("create mode requires empty membership and bindings evidence")
        return

    if not all(existing.values()):
        raise ContractError("reentry mode requires all target objects to exist")
    if set(ownership_ids) != {"group", "provider", "application"}:
        raise ContractError("reentry ownership must name exactly the three target objects")
    for name, obj in (("group", group), ("provider", provider), ("application", application)):
        _text(obj.get("id"), f"objects.{name}.id")
        if ownership_ids.get(name) != obj["id"]:
            raise ContractError(f"ownership.object_ids.{name} does not match the observed object")
    if group["members"]:
        raise ContractError("reentry rejects a non-empty Grafana group")
    if application["bindings"] != [EXPECTED_BINDING]:
        raise ContractError("reentry requires exactly one group-only application binding")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"Usage: {argv[0]} EVIDENCE.json", file=sys.stderr)
        return 2
    try:
        document = json.loads(pathlib.Path(argv[1]).read_text(encoding="utf-8"))
        validate_evidence(document)
    except (OSError, json.JSONDecodeError, ContractError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print("Grafana OIDC preflight passed: non-secret ownership, target metadata, empty group, and unique binding")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
