#!/usr/bin/env bash
# =============================================================================
# sync_native_to_flutter.sh — 原生层 -> Flutter 副本 的「单一事实源」同步工具
#
# 背景（架构治理）：
#   xbridge 采用三层独立分发：原生层（xbridge-android / xbridge-ios 独立 SDK）
#   与 Flutter 层（xbridge_flutter，内含原生代码副本）。二者表达同一份原生能力，
#   但源码物理复制了两份，若各自独立演进必然漂移。为此确立：
#
#     唯一事实源 = packages/xbridge-android + packages/xbridge-ios
#     副本       = packages/xbridge_flutter/android + packages/xbridge_flutter/ios
#
#   副本必须由本脚本从源"单向同步"得到，禁止在副本内直接改原生逻辑。
#   CI（.github/workflows/native-sync-check.yml）以 --check 模式校验，防止漂移。
#
# 用法：
#   scripts/sync_native_to_flutter.sh            # 同步（把源复制到副本，单向）
#   scripts/sync_native_to_flutter.sh --check    # 仅校验是否一致，不一致返回非零
#
# 说明：
#   - 采用「显式白名单映射表」，逐文件声明"源->副本"路径，可读可审计。
#   - 新增源文件且未加入白名单时，脚本会打印样例并警告（不允许静默漏同步）。
#   - 死代码 / 副本刻意不包含的文件（如 XBridgeOriginRuleSanitizer.kt）
#     通过 SYNC_EXCLUSIONS 显式排除。
# =============================================================================
set -euo pipefail

# 仓库根（脚本位于 <repo>/scripts/ 下）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="${1:-sync}"
CHECK_MODE=0
case "$MODE" in
  --check) CHECK_MODE=1 ;;
  sync)    CHECK_MODE=0 ;;
  *) echo "用法: $0 [sync|--check]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# 1) 白名单映射表：<源文件相对仓库根> | <副本文件的绝对路径>
#    —— 这条映射表就是「哪些原生代码被统一管理」的文档化契约。
# ---------------------------------------------------------------------------
# Android：xbridge-android（源）-> xbridge_flutter/android（副本）
#   xbridge-flutter 模块：Flutter 插件 glue（XBridgePlugin / PluginRegistry）
#   xbridge-core 模块：纯 Kotlin 核心（SyncInterface / NativeBridge / SecurityPolicy / WS JNI）
ANDROID_MAP=(
  "packages/xbridge-android/xbridge-flutter/src/main/java/io/xbridge/XBridgePlugin.kt|packages/xbridge_flutter/android/src/main/kotlin/io/xbridge/XBridgePlugin.kt"
  "packages/xbridge-android/xbridge-flutter/src/main/java/io/xbridge/plugin/XBridgePluginRegistry.kt|packages/xbridge_flutter/android/src/main/kotlin/io/xbridge/plugin/XBridgePluginRegistry.kt"
  "packages/xbridge-android/xbridge-core/src/main/java/io/xbridge/XBridgeNativeBridge.kt|packages/xbridge_flutter/android/src/main/kotlin/io/xbridge/XBridgeNativeBridge.kt"
  "packages/xbridge-android/xbridge-core/src/main/java/io/xbridge/XBridgeSecurityPolicy.kt|packages/xbridge_flutter/android/src/main/kotlin/io/xbridge/XBridgeSecurityPolicy.kt"
  "packages/xbridge-android/xbridge-core/src/main/java/io/xbridge/XBridgeSyncInterface.kt|packages/xbridge_flutter/android/src/main/kotlin/io/xbridge/XBridgeSyncInterface.kt"
  "packages/xbridge-android/xbridge-core/src/main/java/io/xbridge/ws/LocalWsServerJni.kt|packages/xbridge_flutter/android/src/main/kotlin/io/xbridge/ws/LocalWsServerJni.kt"
)

# iOS：xbridge-ios（源）-> xbridge_flutter/ios（副本）
IOS_MAP=(
  "packages/xbridge-ios/Sources/XBridgeiOS/Security/XBridgeSecurityPolicy.swift|packages/xbridge_flutter/ios/Classes/Security/XBridgeSecurityPolicy.swift"
  "packages/xbridge-ios/Sources/XBridgeiOS/WebSocket/LocalWsServerBridge.swift|packages/xbridge_flutter/ios/Classes/WebSocket/LocalWsServerBridge.swift"
  "packages/xbridge-ios/Sources/XBridgeiOS/WebSocket/module.modulemap|packages/xbridge_flutter/ios/Classes/WebSocket/module.modulemap"
  "packages/xbridge-ios/Sources/XBridgeiOS/WebSocket/xbridge_core.h|packages/xbridge_flutter/ios/Classes/WebSocket/xbridge_core.h"
  "packages/xbridge-ios/Sources/XBridgeiOS/XBridgeNativeBridge.swift|packages/xbridge_flutter/ios/Classes/XBridgeNativeBridge.swift"
  "packages/xbridge-ios/Sources/XBridgeiOS/XBridgePlugin.swift|packages/xbridge_flutter/ios/Classes/XBridgePlugin.swift"
  "packages/xbridge-ios/Sources/XBridgeiOS/XBridgeSyncHandler.swift|packages/xbridge_flutter/ios/Classes/XBridgeSyncHandler.swift"
)

# 副本刻意不包含的源文件（死代码 / 独立分发专用），用于漏同步检测时报例外。
SYNC_EXCLUSIONS_ANDROID=(
  "packages/xbridge-android/xbridge-core/src/main/java/io/xbridge/XBridgeOriginRuleSanitizer.kt"
)
SYNC_EXCLUSIONS_IOS=(
)

# ---------------------------------------------------------------------------
# 2) 源目录根（用于「漏同步检测」：扫描源里所有受管源码，确认都被白名单覆盖）
# ---------------------------------------------------------------------------
ANDROID_SRC_ROOTS=(
  "packages/xbridge-android/xbridge-core/src/main/java/io/xbridge"
  "packages/xbridge-android/xbridge-flutter/src/main/java/io/xbridge"
)
IOS_SRC_ROOT="packages/xbridge-ios/Sources/XBridgeiOS"

fail=0

# 校验并（可选）同步一个映射对
sync_one() {
  local rel_src="$1" abs_dst="$2"
  local abs_src="$REPO_ROOT/$rel_src"

  if [ ! -f "$abs_src" ]; then
    echo "[ERROR] 源文件缺失: $rel_src" >&2
    fail=1
    return
  fi

  if [ ! -f "$abs_dst" ]; then
    # 副本缺失：可能是新增文件或误删，一律按失败处理，强制人工确认
    echo "[ERROR] 副本缺失(未同步): $rel_src -> $abs_dst" >&2
    fail=1
    return
  fi

  if ! diff -q "$abs_src" "$abs_dst" >/dev/null 2>&1; then
    if [ "$CHECK_MODE" = "1" ]; then
      echo "[DIFF] $rel_src 与副本不一致" >&2
      echo "      请先运行: scripts/sync_native_to_flutter.sh" >&2
      fail=1
    else
      cp "$abs_src" "$abs_dst"
      echo "[SYNC] $rel_src -> $abs_dst"
    fi
  fi
}

# 漏同步检测：源目录里的源码文件必须都被白名单的源路径覆盖（区分死代码例外）。
# 这是 CI 门禁的关键：新增源文件若未同步到副本，就是新一轮「漂移」的起点。
check_no_new_source() {
  local src_root_rel="$1"
  shift
  local -a exclusions=("$@")
  local -a mapped_srcs=()
  local pair
  for pair in "${mapped_all[@]}"; do
    mapped_srcs+=("${pair%%|*}")
  done

  local abs_root="$REPO_ROOT/$src_root_rel"
  [ -d "$abs_root" ] || return 0

  while IFS= read -r abs_file; do
    local rel_file="${abs_file#$REPO_ROOT/}"
    local skip=0
    for ex in "${exclusions[@]}"; do
      if [ "$rel_file" = "$ex" ]; then skip=1; break; fi
    done
    [ "$skip" = "1" ] && continue

    local found=0
    local s
    for s in "${mapped_srcs[@]}"; do
      if [ "$rel_file" = "$s" ]; then found=1; break; fi
    done
    if [ "$found" = "0" ]; then
      # 源里新增但未声明映射：一律视为漂移（同步模式下提示如何加入白名单）
      echo "[ERROR] 源新增文件未进入同步白名单: $rel_file" >&2
      echo "       请在 scripts/sync_native_to_flutter.sh 的映射表声明其 -> 副本 路径" >&2
      fail=1
    fi
  done < <(find "$abs_root" -type f \( -name "*.kt" -o -name "*.swift" -o -name "*.h" -o -name "*.modulemap" \))
}

# 汇总所有映射对，供漏同步检测复用
mapped_all=()
for pair in "${ANDROID_MAP[@]}" "${IOS_MAP[@]}"; do
  mapped_all+=("$pair")
done

# ---------------------------------------------------------------------------
# 3) 执行同步/校验
# ---------------------------------------------------------------------------
for pair in "${ANDROID_MAP[@]}" "${IOS_MAP[@]}"; do
  src="${pair%%|*}"
  dst="${pair#*|}"
  sync_one "$src" "$REPO_ROOT/$dst"
done

# 漏同步检测（同步/校验各平台源目录）
if [ -d "$REPO_ROOT/packages/xbridge-android" ]; then
  check_no_new_source "packages/xbridge-android/xbridge-core/src/main/java/io/xbridge" "${SYNC_EXCLUSIONS_ANDROID[@]}"
  check_no_new_source "packages/xbridge-android/xbridge-flutter/src/main/java/io/xbridge" ""
fi
if [ -d "$REPO_ROOT/packages/xbridge-ios/Sources/XBridgeiOS" ]; then
  check_no_new_source "packages/xbridge-ios/Sources/XBridgeiOS" "${SYNC_EXCLUSIONS_IOS[@]}"
fi

if [ "$fail" = "1" ]; then
  exit 1
fi

if [ "$CHECK_MODE" = "1" ]; then
  echo "OK: Flutter 原生副本与唯一事实源完全一致。"
else
  echo "Done: 同步完成（如无 [SYNC] 行则本已一致）。"
fi