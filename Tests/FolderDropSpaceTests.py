#!/usr/bin/env python3
"""Folder drops create spaces via createNewSpace; files are ignored."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
drag = (ROOT / "Sources/GooseAgent/SpaceRowDrag.swift").read_text()
sidebar = (ROOT / "Sources/GooseAgent/SidebarView.swift").read_text()
assert "enum SidebarFolderDrop" in drag
assert "static func directoryPaths(from urls: [URL])" in drag
assert "onFolderDrop: { paths in" in sidebar
assert "model.createNewSpace(device: .local, directory: path, label: nil)" in sidebar
assert "model.createNewSpace(device: .local, directory: url.path, label: nil)" in sidebar
assert ".onDrop(of: [.fileURL], isTargeted: nil)" in sidebar
assert "folderPaths(from: sender)" in drag

method = drag[drag.index("enum SidebarFolderDrop"):drag.index("/// NSMenu")]
harness = "import Foundation\n" + method + r"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("folder-drop-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let dir = tmp.appendingPathComponent("proj")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let file = tmp.appendingPathComponent("readme.txt")
try "x".write(to: file, atomically: true, encoding: .utf8)
let paths = SidebarFolderDrop.directoryPaths(from: [file, dir])
assert(paths == [dir.path], paths.joined(separator: ","))
assert(SidebarFolderDrop.directoryPaths(from: [file]).isEmpty)
try? FileManager.default.removeItem(at: tmp)
print("PASS: folder drop keeps directories and ignores files")
"""
with tempfile.TemporaryDirectory(prefix="folder-drop-") as directory:
    swift = Path(directory) / "Check.swift"
    swift.write_text(harness)
    subprocess.run(["swift", str(swift)], check=True)
