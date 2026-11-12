#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
products_dir="${1:-$repo_dir/build/DerivedData.noindex/Build/Products/Debug}"
dylib_dir="$products_dir/1Agent.app/Contents/MacOS"
test_dir="$(mktemp -d /private/tmp/oneagent-quick-command-sidebar.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/QuickCommandSidebarTests.app/Contents"
mkdir -p "$test_bundle/MacOS" "$test_dir/home"
ln -s "$products_dir/1Agent.app/Contents/Resources" "$test_bundle/Resources"
test_executable="$test_bundle/MacOS/quick-command-sidebar-tests"
developer_dir=/Applications/Xcode.app/Contents/Developer
swift_compiler="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk_dir="$(env DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path)"
"$swift_compiler" -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_dir" \
    -module-cache-path "$repo_dir/build/QuickCommandSidebarModuleCache.noindex" \
    -F "$products_dir" -Xlinker -rpath -Xlinker "$products_dir/1Agent.app/Contents/Frameworks" -I "$products_dir" -I "$products_dir/include/libghostty" \
    -Xlinker -rpath -Xlinker "$dylib_dir" \
    "$dylib_dir/1Agent.debug.dylib" "$repo_dir/Tests/QuickCommandSidebarTests.swift" \
    -o "$test_executable"
# 每次进程单独存储；失败仍保留真实退出码，不改变系统崩溃报告设置。
run_test() {
    local test_home
    test_home="$(mktemp -d "$test_dir/home/run.XXXXXX")"
    /usr/bin/sandbox-exec -p "(version 1) (allow default) (deny network*) (deny process-exec) (allow process-exec (literal \"/usr/bin/env\") (literal \"$test_executable\"))" \
        /usr/bin/env CFFIXED_USER_HOME="$test_home" ONEAGENT_TEST_HOME="$test_home" "$test_executable" "$@"
}

# 可选第二参数用于回归验证：断言/缺失对象/真实拖拽断言都必须正常失败。
if [[ "${2:-}" == "--verify-failure-reporting" ]]; then
    for scenario in assertion missing-object drag-delivery; do
        status=0
        run_test "--fail-$scenario" > "$test_dir/failure.log" 2>&1 || status=$?
        cat "$test_dir/failure.log"
        if [[ "$status" != 1 ]] || ! /usr/bin/grep -Eq 'QuickCommandSidebarTests failed: .*QuickCommandSidebarTests.swift:[0-9]+:' "$test_dir/failure.log"; then
            echo "FAIL $scenario: expected reported test failure with exit 1, got $status" >&2
            exit 1
        fi
        case "$scenario" in
            assertion) expected="验证断言失败正常退出" ;;
            missing-object) expected="验证缺失对象正常退出" ;;
            drag-delivery) expected="真实指令行拖入终端只投递一次" ;;
        esac
        /usr/bin/grep -Fq "$expected" "$test_dir/failure.log" || exit 1
        echo "PASS $scenario reports failure without a crash"
    done
elif [[ "${2:-}" == "--repeat" ]]; then
    repeats="${3:-10}"
    if [[ ! "$repeats" =~ ^[1-9][0-9]*$ ]]; then
        echo "重复次数必须是正整数" >&2
        exit 1
    fi
    for ((iteration=1; iteration<=repeats; iteration++)); do
        echo "Sidebar regression $iteration/$repeats"
        run_test
        run_test --background-drag
    done
else
    run_test "${@:2}"
fi
