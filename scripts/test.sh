#!/bin/bash
# 运行 FileMerge 测试套件。
#
# 背景：本机 CommandLineTools 的 swift-testing 宏插件布局损坏（plugins/testing/ 下
# 缺少同级语法库），dlopen libTestingMacros.dylib 失败表现为
# "plugin for module 'TestingMacros' not found"。
# 解决方案（2026-10-07 第二次修正，稳定有效）：
#   1) /tmp/fm2/swift/host 镜像补齐语法库（XcodeDefaultTools-6.4.0.34.1 必须是真实空目录）
#   2) 用 -Xfrontend 透传 -load-resolved-plugin 加载镜像内自包含插件副本
#      （镜像副本的 @loader_path/.. 命中镜像语法库；直接 -Xswiftc 传
#      -load-resolved-plugin 会被 SwiftPM 对 emit-module 任务剥离，不可靠）
#   3) --disable-sandbox：SwiftPM seatbelt 会拦截插件 dlopen
# 若 /tmp 镜像被系统清理，需按上述布局重建（语法库可从
# /Library/Developer/CommandLineTools/usr/lib/swift/host/ 拷贝）。

set -euo pipefail
cd "$(dirname "$0")/.."

exec swift test --disable-sandbox \
  -Xswiftc -Xfrontend -Xswiftc -load-resolved-plugin \
  -Xswiftc -Xfrontend -Xswiftc "/tmp/fm2/swift/host/plugins/testing/libTestingMacros.dylib##TestingMacros" \
  "$@"
