#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
from http.client import IncompleteRead
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote
from urllib.request import Request, urlopen


def download_snapshot(repo, revision, staging):
    repository = quote(repo, safe="/")
    try:
        with urlopen(
            f"https://huggingface.co/api/models/{repository}/revision/{revision}?blobs=true",
            timeout=120,
        ) as response:
            metadata = json.load(response)
    except OSError:
        raise ValueError("could not retrieve model metadata") from None
    if metadata.get("sha") != revision:
        raise ValueError("model metadata revision does not match manifest")
    files = metadata.get("siblings")
    if not isinstance(files, list) or not files:
        raise ValueError("model metadata contains no files")
    seen = set()
    entries = []
    for entry in files:
        name = entry.get("rfilename")
        if (not isinstance(name, str) or "\\" in name or "\x00" in name
                or any(part in ("", ".", "..") for part in name.split("/"))):
            raise ValueError("unsafe model file path")
        if name in seen:
            raise ValueError("duplicate model file path")
        seen.add(name)
        size = entry.get("size")
        if type(size) is not int or size < 0:
            raise ValueError(f"missing model file size: {name}")
        lfs = entry.get("lfs")
        if lfs is not None:
            digest = lfs.get("sha256")
            if lfs.get("size") != size:
                raise ValueError(f"inconsistent model file size: {name}")
            algorithm = "sha256"
        else:
            digest = entry.get("blobId")
            algorithm = "sha1"
        length = 64 if algorithm == "sha256" else 40
        if not isinstance(digest, str) or not re.fullmatch(f"[0-9a-f]{{{length}}}", digest):
            raise ValueError(f"missing model file checksum: {name}")
        entries.append((name, size, algorithm, digest))

    def download_file(entry):
        name, size, algorithm, expected = entry
        destination = staging / name
        if destination.is_symlink():
            raise ValueError(f"model file is a symlink: {name}")
        for parent in destination.relative_to(staging).parents:
            if (staging / parent).is_symlink():
                raise ValueError(f"model file parent is a symlink: {name}")
        destination.parent.mkdir(parents=True, exist_ok=True)

        def new_digest():
            digest = hashlib.new(algorithm)
            if algorithm == "sha1":
                digest.update(f"blob {size}\0".encode())
            return digest

        digest = new_digest()
        received = 0
        if destination.exists():
            with destination.open("rb") as previous:
                while chunk := previous.read(1024 * 1024):
                    digest.update(chunk)
                    received += len(chunk)
            if received == size and digest.hexdigest() == expected:
                print(f"Verified {name}", flush=True)
                return
            if received >= size:
                destination.unlink()
                digest = new_digest()
                received = 0
        print(f"Downloading {name}", flush=True)
        for attempt in range(4):
            request = Request(
                f"https://huggingface.co/{repository}/resolve/{revision}/{quote(name, safe='/')}",
                headers={"Range": f"bytes={received}-"} if received else {},
            )
            try:
                with urlopen(request, timeout=120) as response:
                    if received and response.status == 200:
                        received = 0
                        digest = new_digest()
                    elif response.status == 206:
                        content_range = response.headers.get("Content-Range", "")
                        match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", content_range)
                        if not match or int(match[1]) != received or int(match[3]) != size:
                            raise ValueError(f"invalid download range: {name}")
                    elif response.status != 200:
                        raise ValueError(f"unexpected download status: {name}")
                    with destination.open("ab" if received else "wb") as output:
                        while chunk := response.read(1024 * 1024):
                            received += len(chunk)
                            if received > size:
                                destination.unlink()
                                raise ValueError(f"model file exceeds expected size: {name}")
                            digest.update(chunk)
                            output.write(chunk)
            except (OSError, IncompleteRead):
                if attempt == 3:
                    raise ValueError(f"could not download model file: {name}") from None
            else:
                if received == size:
                    break
                if attempt == 3:
                    raise ValueError(f"model file download incomplete: {name}")
            print(f"Retrying {name} ({attempt + 1}/3)", flush=True)
        if digest.hexdigest() != expected:
            destination.unlink()
            raise ValueError(f"model file failed integrity check: {name}")
        print(f"Verified {name}", flush=True)

    with ThreadPoolExecutor(max_workers=3) as pool:
        for _ in pool.map(download_file, entries):
            pass


def read_json(path, default):
    if not path.exists():
        return default
    with path.open() as stream:
        return json.load(stream)


def write_json(path, data, backup=False):
    if path.exists() and read_json(path, None) == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if backup and path.exists():
            shutil.copy2(path, path.with_name(path.name + ".bak"))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate(manifest):
    models = manifest.get("models")
    if not isinstance(models, dict):
        raise ValueError("manifest.models must be an object")
    for name, model in models.items():
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
            raise ValueError(f"invalid model directory: {name!r}")
        if not isinstance(model, dict):
            raise ValueError(f"invalid model entry: {name}")
        if not isinstance(model.get("repo"), str) or not model["repo"]:
            raise ValueError(f"missing repository: {name}")
        if not re.fullmatch(r"[0-9a-fA-F]{40}", model.get("revision", "")):
            raise ValueError(f"revision must be a full commit hash: {name}")
        if not isinstance(model.get("settings", {}), dict):
            raise ValueError(f"settings must be an object: {name}")
    return models


def sync(models, model_dir, base_path, download=True, configure=True):
    marker_path = base_path / "model_revisions.json"
    markers = read_json(marker_path, {})
    if not isinstance(markers, dict):
        raise ValueError("model_revisions.json must be an object")
    for name, model in models.items():
        destination = model_dir / name
        expected = {"repo": model["repo"], "revision": model["revision"]}
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_dir():
                raise ValueError(f"model path is not a regular directory: {destination}")
            if markers.get(name) != expected:
                raise ValueError(f"existing model has a different or unknown revision: {name}")
            continue
        if not download:
            raise ValueError(f"model has not been downloaded: {name}")
        model_dir.mkdir(parents=True, exist_ok=True)
        staging = model_dir / f".{name}.{model['revision']}.partial"
        if staging.is_symlink():
            raise ValueError(f"model staging path is a symlink: {name}")
        staging.mkdir(mode=0o700, exist_ok=True)
        download_snapshot(model["repo"], model["revision"], staging)
        if destination.exists() or destination.is_symlink():
            raise ValueError(f"model destination appeared during download: {name}")
        staging.rename(destination)
        markers[name] = expected
        write_json(marker_path, markers)
    if configure:
        settings_path = base_path / "model_settings.json"
        settings = read_json(settings_path, {"version": 1, "models": {}})
        if not isinstance(settings, dict) or not isinstance(settings.get("models"), dict):
            raise ValueError("model_settings.json must contain a models object")
        if settings.get("version", 1) != 1:
            raise ValueError("unsupported model_settings.json version")
        settings["version"] = 1
        for name, model in models.items():
            existing = settings["models"].setdefault(name, {})
            if not isinstance(existing, dict):
                raise ValueError(f"existing settings must be an object: {name}")
            existing.update(model.get("settings", {}))
        write_json(settings_path, settings, backup=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--base-path", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--download-only", action="store_true")
    mode.add_argument("--configure-only", action="store_true")
    args = parser.parse_args()
    try:
        models = validate(read_json(args.manifest, {}))
        args.base_path.mkdir(parents=True, exist_ok=True)
        with (args.base_path / ".model-sync.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sync(models, args.model_dir, args.base_path,
                 download=not args.configure_only, configure=not args.download_only)
    except (ValueError, OSError) as error:
        parser.exit(1, f"omlx-sync: {error}\n")


if __name__ == "__main__":
    main()
