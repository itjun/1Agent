#!/bin/bash
set -euo pipefail
[[ "${CONFIGURATION:-}" == Release ]] || exit 0
if [[ "${CODE_SIGN_IDENTITY:-}" != 'Developer ID Application:'* || "${CODE_SIGNING_ALLOWED:-YES}" == NO ]]; then
    echo 'error: Release 必须使用 Developer ID Application 签名' >&2
    exit 1
fi
python3 - <<'PY'
import base64, os, sys
try:
    assert len(base64.b64decode(os.environ.get('SPARKLE_PUBLIC_KEY', ''), validate=True)) == 32
except Exception:
    sys.exit('error: Release 缺少有效的 SPARKLE_PUBLIC_KEY')
PY
