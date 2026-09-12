#!/usr/bin/env python3
import argparse
import pathlib
import re
import subprocess
import sys

import yaml


PRIVATE_KEY = re.compile(
    r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY" r" BLOCK-----"
    r"|AGE-SECRET-KEY-[A-Z0-9]{20,}"
)
ENCRYPTED = re.compile(r"ENC\[AES256_GCM,data:[^,]*,iv:[^,]+,tag:[^,]+,type:[^\]]+\]")
PLACEHOLDER = re.compile(r"replace-me|tskey-auth-\.\.\.|(?:hk\.tails\.|forgejo\.|zot\.|attic\.)?\$\{SECRET_[A-Z0-9_]+\}")
TEMPLATE = re.compile(r"#\{\s*(?:[a-z_][a-z0-9_]*(?:\(\))?|age_key\('private'\))\s*\}#")
KNOWN_HOST = re.compile(r"[a-zA-Z0-9.*,-]+ (?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+")


def git(*args):
    return subprocess.check_output(["git", *args])


def fields(node):
    if isinstance(node, yaml.MappingNode):
        result = {}
        for key, value in node.value:
            if not isinstance(key, yaml.ScalarNode) or key.value in result:
                raise ValueError("ambiguous YAML key")
            result[key.value] = value
        return result
    return {}


def leaves(node, ancestors=()):
    if isinstance(node, yaml.MappingNode):
        for key, value in fields(node).items():
            yield from leaves(value, (*ancestors, key))
    elif isinstance(node, yaml.SequenceNode):
        for value in node.value:
            yield from leaves(value, ancestors)
    else:
        yield ancestors, node


def check(path, data):
    issues = set()

    def report(line, reason):
        issues.add((line, reason))

    text = data.decode("utf-8", errors="replace")
    for match in PRIVATE_KEY.finditer(text):
        report(text.count("\n", 0, match.start()) + 1, "private key material")

    name = pathlib.PurePosixPath(path)
    secret_file = path.startswith("secrets/")
    example = name.name.endswith(".example.yaml")
    template = path.startswith("wanxiang/templates/") and name.name.endswith(".yaml.j2")
    sops_file = not name.name.startswith(".") and ".sops." in name.name and name.suffix in {".yaml", ".yml", ".json"}
    if name.name in {"kubeconfig", "talosconfig", "age.key"} or name.suffix in {
        ".kubeconfig", ".talosconfig", ".agekey", ".key", ".p12", ".pfx",
    } or "clusterconfig" in name.parts:
        report(1, "local credential file must not be tracked")

    structured = name.suffix in {".yaml", ".yml", ".json", ".conf"} or not name.suffix or template
    credential_shape = bool(re.search(r"(?m)^\s*(?:kind:\s*(?:Config|Secret|List)|contexts:|client-key-data:)", text))
    if not structured and not credential_shape:
        if secret_file and not (name.name == ".gitkeep" and not data):
            report(1, "unsupported secret format; use SOPS YAML or JSON")
        return issues

    try:
        documents = list(yaml.compose_all(text, Loader=yaml.SafeLoader))
        for document in documents:
            root = fields(document)
            metadata = fields(root.get("sops"))
            protected = secret_file or sops_file
            if protected and not example:
                mac = metadata.get("mac")
                if not mac or not ENCRYPTED.fullmatch(mac.value):
                    report(1, "missing SOPS encrypted MAC")
            if metadata.keys() - {
                "age", "pgp", "kms", "gcp_kms", "azure_kv", "hc_vault", "key_groups",
                "shamir_threshold", "lastmodified", "mac", "version", "encrypted_regex",
                "unencrypted_suffix", "encrypted_suffix", "unencrypted_regex",
                "encrypted_comment_regex", "unencrypted_comment_regex", "mac_only_encrypted",
            }:
                report(1, "unexpected SOPS metadata field")

            kind = root.get("kind")
            kubernetes_secret = kind is not None and kind.value == "Secret"
            kubeconfig = kind is not None and kind.value == "Config" and "users" in root
            talosconfig = "contexts" in root and "context" in root
            for key, value in root.items():
                if key == "sops":
                    continue
                for ancestors, leaf in leaves(value, (key,)):
                    required = protected and (secret_file or not kubernetes_secret or key in {"data", "stringData"})
                    required |= kubernetes_secret and key in {"data", "stringData"}
                    required |= kubeconfig and key == "users" and ancestors[-1] in {
                        "token", "password", "client-key-data", "client-certificate-data",
                    }
                    required |= talosconfig and key == "contexts" and ancestors[-1] in {"key", "crt"}
                    if required and leaf.value and leaf.tag != "tag:yaml.org,2002:null" and not ENCRYPTED.fullmatch(leaf.value):
                        if example and PLACEHOLDER.fullmatch(leaf.value):
                            continue
                        if template:
                            value = re.sub(r"(?m)^\s*#% (?:filter indent\(width=4, first=False\)|endfilter) %#\s*$", "", leaf.value).strip()
                            if TEMPLATE.fullmatch(value):
                                continue
                            if ancestors[-1] == "known_hosts" and all(KNOWN_HOST.fullmatch(line) for line in value.splitlines()):
                                continue
                        report(leaf.start_mark.line + 1, "unencrypted protected value")
            for ancestors, leaf in leaves(document):
                if ancestors and ancestors[-1] in {"client-key-data", "client-certificate-data"}:
                    if leaf.value and not ENCRYPTED.fullmatch(leaf.value):
                        report(leaf.start_mark.line + 1, "plaintext client credential")
            if kind is not None and kind.value == "List":
                items = root.get("items")
                if isinstance(items, yaml.SequenceNode):
                    documents.extend(items.value)
    except (yaml.YAMLError, ValueError, TypeError, AttributeError, RecursionError, re.error):
        if secret_file or sops_file or (structured and credential_shape):
            report(1, "cannot safely parse YAML/JSON for secret checks")
    return issues


def main():
    parser = argparse.ArgumentParser(description="Check Git content without printing secret values")
    parser.add_argument("--staged", action="store_true", help="check staged additions and modifications")
    args = parser.parse_args()
    if args.staged:
        paths = git("diff", "--cached", "--name-only", "--diff-filter=ACMRT", "-z").split(b"\0")
        prefix = ":"
    else:
        paths = git("ls-tree", "-r", "--name-only", "-z", "HEAD").split(b"\0")
        prefix = "HEAD:"
    failed = False
    for raw_path in paths:
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", errors="surrogateescape")
        for line, reason in sorted(check(path, git("show", prefix + path))):
            print(f"{path!r}:{line}: {reason}", file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
