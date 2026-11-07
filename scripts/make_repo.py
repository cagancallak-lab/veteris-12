#!/usr/bin/env python3
"""Turn built .deb files into a minimal Cydia/Sileo repository.

    python3 scripts/make_repo.py --output repo xcbuild/*.deb

Produces:
    repo/Packages        (index Cydia reads)
    repo/Packages.gz
    repo/Release
    repo/debs/*.deb
    repo/index.html      (human landing page)

The repository root is what GitHub Pages publishes, so the Cydia source URL is
https://<user>.github.io/<repo>/.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import pathlib
import shutil
import sys
import tarfile

AR_MAGIC = b"!<arch>\n"
FIELD_ORDER = (
    "Package",
    "Name",
    "Version",
    "Architecture",
    "Depends",
    "Conflicts",
    "Replaces",
    "Provides",
    "Section",
    "Priority",
    "Maintainer",
    "Author",
    "Description",
    "Homepage",
    "Depiction",
    "Icon",
    "Compatibility",
    "Installed-Size",
)


def ar_members(data: bytes) -> dict[str, bytes]:
    if not data.startswith(AR_MAGIC):
        raise ValueError("not an ar archive")
    pos = len(AR_MAGIC)
    members: dict[str, bytes] = {}
    while pos + 60 <= len(data):
        header = data[pos : pos + 60]
        name = header[0:16].decode("ascii", "replace").strip()
        size = int(header[48:58].decode("ascii").strip())
        members[name] = data[pos + 60 : pos + 60 + size]
        pos += 60 + size + (size % 2)
    return members


def deb_control(deb: pathlib.Path) -> str:
    members = ar_members(deb.read_bytes())
    control_tar = next((body for name, body in members.items() if name.startswith("control.tar")), None)
    if control_tar is None:
        raise ValueError(f"{deb}: no control.tar member")
    with tarfile.open(fileobj=io.BytesIO(control_tar), mode="r:*") as tf:
        member = tf.extractfile("./control") or tf.extractfile("control")
        if member is None:
            raise ValueError(f"{deb}: no control file")
        return member.read().decode("utf-8", "replace")


def parse_control(text: str) -> list[tuple[str, str]]:
    fields: list[tuple[str, str]] = []
    current_key = None
    for line in text.splitlines():
        if line.startswith((" ", "\t")) and current_key:
            fields[-1] = (current_key, fields[-1][1] + "\n" + line)
        elif ":" in line:
            key, value = line.split(":", 1)
            current_key = key.strip()
            fields.append((current_key, value.strip()))
    return fields


def format_stanza(fields: list[tuple[str, str]]) -> str:
    values = dict(fields)
    ordered = [key for key in FIELD_ORDER if key in values] + [
        key for key, _ in fields if key not in FIELD_ORDER
    ]
    lines = []
    seen = set()
    for key in ordered:
        if key in seen:
            continue
        seen.add(key)
        lines.append(f"{key}: {values[key]}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="repo", type=pathlib.Path)
    parser.add_argument("--origin", default="cagancallak-lab")
    parser.add_argument("--label", default="Veteris iOS 12")
    parser.add_argument("debs", nargs="+", type=pathlib.Path)
    args = parser.parse_args()

    out: pathlib.Path = args.output
    debs_dir = out / "debs"
    debs_dir.mkdir(parents=True, exist_ok=True)

    stanzas = []
    for deb in args.debs:
        if not deb.is_file():
            print(f"skip missing {deb}", file=sys.stderr)
            continue
        control = dict(parse_control(deb_control(deb)))
        package = control.get("Package")
        version = control.get("Version")
        if not package or not version:
            print(f"skip {deb}: control has no Package/Version", file=sys.stderr)
            continue
        target_name = f"{package}_{version}_iphoneos-arm.deb"
        target = debs_dir / target_name
        shutil.copyfile(deb, target)
        data = target.read_bytes()
        control["Filename"] = f"./debs/{target_name}"
        control["Size"] = str(len(data))
        control["MD5sum"] = hashlib.md5(data).hexdigest()
        control["SHA1"] = hashlib.sha1(data).hexdigest()
        control["SHA256"] = hashlib.sha256(data).hexdigest()
        stanzas.append(format_stanza(list(control.items())))
        print(f"added {target_name} ({len(data)} bytes)")

    if not stanzas:
        print("no packages to index", file=sys.stderr)
        return 1

    packages = "\n\n".join(stanzas) + "\n"
    (out / "Packages").write_text(packages, encoding="utf-8")
    with open(out / "Packages.gz", "wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as fh:
            fh.write(packages.encode("utf-8"))

    release = (
        f"Origin: {args.origin}\n"
        f"Label: {args.label}\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: ios12\n"
        "Architectures: iphoneos-arm\n"
        "Components: main\n"
        "Description: Veteris arm64 build for iOS 12\n"
    )
    (out / "Release").write_text(release, encoding="utf-8")

    (out / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>Veteris iOS 12</title>"
        "<h1>Veteris for iOS 12</h1>"
        "<p>Add this URL as a Cydia/Sileo source:</p>"
        "<pre>https://cagancallak-lab.github.io/veteris-12/</pre>"
        "<p>Package: <code>com.victorlobe.veteris</code></p>",
        encoding="utf-8",
    )
    print(f"wrote {out}/Packages ({len(stanzas)} package(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
