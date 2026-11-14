#!/usr/bin/env python3
"""验证发布构建拒绝缺失签名、公钥和 ad-hoc 动态库加载权限。"""
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = {
    **os.environ,
    "CONFIGURATION": "Release",
    "CODE_SIGNING_ALLOWED": "YES",
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_ENTITLEMENTS": "Resources/AdHoc.entitlements",
    "SPARKLE_PUBLIC_KEY": base64.b64encode(bytes(range(32))).decode(),
    "SRCROOT": str(ROOT),
}


def check(name, is_expected_success, **overrides):
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/validate-release-signing.sh")],
        cwd="/tmp", env={**BASE, **overrides}, capture_output=True, text=True,
    )
    assert (result.returncode == 0) == is_expected_success, (name, result.stderr)
    print(f"PASS: {name}")


check("ad-hoc Release 带有效公钥和动态库加载权限", True)
check("Developer ID Release 无需 ad-hoc 权限", True,
      CODE_SIGN_IDENTITY="Developer ID Application: Test", CODE_SIGN_ENTITLEMENTS="")
check("Debug 不要求发布公钥", True, CONFIGURATION="Debug", SPARKLE_PUBLIC_KEY="")
check("拒绝关闭代码签名", False, CODE_SIGNING_ALLOWED="NO")
check("拒绝缺少签名身份", False, CODE_SIGN_IDENTITY="")
check("拒绝未知签名类型", False, CODE_SIGN_IDENTITY="Local Test Certificate")
check("拒绝缺失更新公钥", False, SPARKLE_PUBLIC_KEY="")
check("拒绝格式错误的更新公钥", False, SPARKLE_PUBLIC_KEY="invalid key")
check("拒绝长度错误的更新公钥", False,
      SPARKLE_PUBLIC_KEY=base64.b64encode(bytes(31)).decode())
check("拒绝 ad-hoc Release 缺失权限文件", False, CODE_SIGN_ENTITLEMENTS="")
with tempfile.TemporaryDirectory(prefix="oneagent-signing-test-") as folder:
    path = Path(folder) / "test.entitlements"
    for value in [False, "true"]:
        path.write_bytes(plistlib.dumps({"com.apple.security.cs.disable-library-validation": value}))
        check(f"拒绝无效动态库加载权限 {value!r}", False, CODE_SIGN_ENTITLEMENTS=str(path))
