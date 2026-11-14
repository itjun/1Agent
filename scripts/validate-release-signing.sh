#!/bin/bash
set -euo pipefail
[[ "${CONFIGURATION:-}" == Release ]] || exit 0
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == NO ]]; then
    echo 'error: Release 必须签名，支持 ad-hoc 或 Developer ID Application' >&2
    exit 1
fi
case "${CODE_SIGN_IDENTITY:-}" in
    -|'Developer ID Application:'*) ;;
    *) echo 'error: Release 必须使用 ad-hoc 或 Developer ID Application 签名' >&2; exit 1 ;;
esac
python3 - <<'PYTHON'
import base64, os, pathlib, plistlib, sys
try:
    if len(base64.b64decode(os.environ.get('SPARKLE_PUBLIC_KEY', ''), validate=True)) != 32:
        raise ValueError('公钥长度错误')
except Exception:
    sys.exit('error: Release 缺少有效的 SPARKLE_PUBLIC_KEY')
if os.environ.get('CODE_SIGN_IDENTITY') == '-':
    try:
        path = pathlib.Path(os.environ['CODE_SIGN_ENTITLEMENTS'])
        if not path.is_absolute():
            path = pathlib.Path(os.environ.get('SRCROOT', '.')) / path
        with path.open('rb') as stream:
            entitlements = plistlib.load(stream)
        if entitlements.get('com.apple.security.cs.disable-library-validation') is not True:
            raise ValueError('缺少动态库加载权限')
    except Exception:
        sys.exit('error: ad-hoc Release 必须配置允许加载 Sparkle 的签名权限')
PYTHON
