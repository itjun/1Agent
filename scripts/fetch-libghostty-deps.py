#!/usr/bin/env python3
"""Populate Zig's package directory using curl when Zig cannot use a proxy."""
import concurrent.futures
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).resolve()
packages = source / "zig-pkg"
downloads = pathlib.Path(sys.argv[2]).resolve()
packages.mkdir(parents=True, exist_ok=True)
downloads.mkdir(parents=True, exist_ok=True)
pattern = re.compile(r'\.url\s*=\s*"((?:git\+)?https://[^\"]+)"\s*,\s*\.hash\s*=\s*"([^\"]+)"')


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def fetch(item):
    url, expected = item
    destination = packages / expected
    if destination.is_dir():
        return
    with tempfile.TemporaryDirectory(dir=downloads) as temporary:
        tmp = pathlib.Path(temporary)
        if url.startswith("git+"):
            repository, revision = url[4:].rsplit("#", 1)
            checkout = tmp / "checkout"
            run(["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout", repository, str(checkout)])
            run(["git", "-C", str(checkout), "checkout", "--quiet", revision])
            result = run(["zig", "fetch", str(checkout)], capture_output=True).stdout.strip().splitlines()[-1]
            if result != expected:
                raise RuntimeError(f"Zig package checksum mismatch: {expected}")
            archive = tmp / "source.tar"
            with archive.open("wb") as stream:
                subprocess.run(["git", "-C", str(checkout), "archive", "HEAD"], check=True, stdout=stream)
            strip = False
        else:
            archive = tmp / url.rsplit("/", 1)[-1]
            run(["curl", "-fsSL", "--retry", "3", "--max-time", "180", "-o", str(archive), url])
            result = run(["zig", "fetch", str(archive)], capture_output=True).stdout.strip().splitlines()[-1]
            if result != expected:
                raise RuntimeError(f"Zig package checksum mismatch: {expected}")
            names = run(["tar", "-tf", str(archive)], capture_output=True).stdout.splitlines()
            strip = len({name.split("/")[0] for name in names if name}) == 1
        extracted = tmp / "package"
        extracted.mkdir()
        command = ["tar", "-xf", str(archive), "-C", str(extracted)]
        if strip:
            command.append("--strip-components=1")
        run(command)
        shutil.move(str(extracted), str(destination))
        print(f"→ fetched {expected}", flush=True)


while True:
    manifests = [source / "build.zig.zon", *source.glob("pkg/**/build.zig.zon"), *packages.glob("*/build.zig.zon")]
    dependencies = {}
    for manifest in manifests:
        text = "\n".join(line for line in manifest.read_text().splitlines() if not line.lstrip().startswith("//"))
        for url, digest in pattern.findall(text):
            dependencies.setdefault(digest, url)
    missing = [(url, digest) for digest, url in dependencies.items() if not (packages / digest).is_dir()]
    if not missing:
        break
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        list(executor.map(fetch, missing))
