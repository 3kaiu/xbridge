#!/usr/bin/env bash
# =============================================================================
# version.sh — 全仓版本号「单一事实源」工具
#
# 背景（版本治理）：
#   xbridge 是「一个 SDK、多生态分发」：JS(npm) / Dart(pub) / Rust(cargo) /
#   Android(gradle) / iOS(cocoapods)。每个生态的版本号都写死在自己的 manifest
#   里，手工改 10+ 文件极易漏改、改错（历史上出现过 iOS 副本 podspec 停在
#   0.1.0、iOS tag 忘加 `v` 前缀导致发布拉不到 tag 的漂移）。
#
#   约定：
#     单一事实源  = git release tag（带 `v` 前缀，如 v0.1.5）
#     所有 manifest = 由本脚本从该 tag 单向同步写入
#
#   统一策略：JS 与原生/Flutter 用同一版本号（一条版本线，一个 SDK 一个版本）。
#
# 用法：
#   scripts/version.sh <VERSION>   # 把 <VERSION>（可带可不带 v）写入全部 manifest
#   scripts/version.sh --check     # 校验全部 manifest == 最新 git tag；不等则非零
#   scripts/version.sh --check <VERSION>   # 用指定版本作为期望值比对
#   scripts/version.sh help        # 本帮助
#
# 说明：
#   - iOS podspec 的 source tag 统一带 `v` 前缀（与仓库 tag 约定一致）。
#   - 本脚本只改版本号，不提交、不打 tag（发布动作由人显式执行）。
#   - xbridge-js/package-lock.json 顶层 version 一并同步，避免 npm 报不一致。
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-help}"
CHECK_MODE=0
case "$MODE" in
  --check) CHECK_MODE=1; VER="${2:-}" ;;
  help|-h|--help)
    echo "用法:"
    echo "  scripts/version.sh <VERSION>   把版本写入全部 manifest（可带/不带 v 前缀）"
    echo "  scripts/version.sh --check     校验全部 manifest == 最新 git tag"
    echo "  scripts/version.sh --check <VERSION>  用指定版本做为期望值"
    echo "  scripts/version.sh help        本帮助"
    exit 0 ;;
  *) CHECK_MODE=0; VER="$MODE" ;;
esac

# SemVer 归一：去掉可选 v 前缀
norm() { local v="$1"; echo "${v#v}"; }

validate() {
  local v="$1"
  if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误：非法版本号 '$v' —— 须为 X.Y.Z（如 0.1.5）" >&2
    exit 2
  fi
}

latest_tag() {
  local tag
  tag="$(git tag --list 'v[0-9]*' --sort=-creatordate | head -n1 || true)"
  if [ -z "$tag" ]; then
    echo "错误：仓库没有 vX.Y.Z 标签" >&2
    exit 3
  fi
  norm "$tag"
}

# ---------------------------------------------------------------------------
# 版本线：所有包统一为同一版本。
# 每个目标： <相对路径> | <文件内版本占位符的样子>（用于 sed 精确替换版本串）
#
# sed 替换策略：把文件中形如 "0.1.x" / '0.1.x' / version: 0.1.x 的版本串，
# 替换为新版本。为避免误伤，针对每种 manifest 用专门的正则对「版本所在行」做替换。
# ---------------------------------------------------------------------------

# 对每个文件应用「版本串替换」。返回 0=该文件等价于期望版本（无需写）/已写；1=校验失败。
apply() {
  local newver="$1"; shift
  local ok=1  # 默认：校验通过

  for pair in "$@"; do
    local file="${pair%%|*}"
    file="$(printf '%s' "$file" | sed -E 's/[[:space:]]+$//')"
    local kind="${pair##*|}"

    if [ ! -f "$file" ]; then
      echo "  [缺失]  $file"
      ok=0; continue
    fi

    # 找到字段所在行，再从该行抽取纯版本串（如 0.1.4）。
    local field_line cur
    field_line="$(grep -E "$kind" "$file" | head -n1 || true)"
    if [ -z "$field_line" ]; then
      echo "  [未命中] $file (kind=$kind)"
      ok=0; continue
    fi
    cur="$(printf '%s' "$field_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    if [ -z "$cur" ]; then
      echo "  [无版本号] $file"
      ok=0; continue
    fi

    if [ "$cur" = "$newver" ]; then
      echo "  [已一致] $file"
      continue
    fi

    if [ "$CHECK_MODE" -eq 1 ]; then
      echo "  [失配]   $file : 期望 $newver, 当前 $cur"
      ok=0
    else
      # BSD sed (macOS)：`-i ''`（空备份后缀）原地写，不产生 .E 备份文件。
      sed -i '' -E "s/$cur/$newver/g" "$file"
      echo "  [写入]   $file : $cur -> $newver"
    fi
  done
  return $(( ! ok ))
}

# 每种 manifest 的「版本串」提取正则（只匹配版本数字本身，形如 0.1.x）：
#   npm            "version": "0.1.x"
#   pubspec        version: 0.1.x
#   cargo          version = "0.1.x"
#   gradle         version = '0.1.x'
#   podspec        s.version = '0.1.x'
get_pairs() {
  local v="$1"
  local x="${v%%.*}"

  cat <<PAIRS
packages/xbridge-js/package.json|\\"version\\":\\s*\\"[0-9]+\\.[0-9]+\\.[0-9]+\\"
packages/xbridge-js/package-lock.json|\\"version\\":\\s*\\"[0-9]+\\.[0-9]+\\.[0-9]+\\"
packages/xbridge_flutter/pubspec.yaml|^version:\\s*[0-9]+\\.[0-9]+\\.[0-9]+
packages/xbridge_protocol/pubspec.yaml|^version:\\s*[0-9]+\\.[0-9]+\\.[0-9]+
packages/xbridge_platform_interface/pubspec.yaml|^version:\\s*[0-9]+\\.[0-9]+\\.[0-9]+
rust/xbridge_core/Cargo.toml|^version\\s*=\\s*\\"[0-9]+\\.[0-9]+\\.[0-9]+\\"
packages/xbridge-android/xbridge-core/build.gradle|^version\\s*=\\s*\\'[0-9]+\\.[0-9]+\\.[0-9]+\\'
packages/xbridge-android/xbridge-flutter/build.gradle|^version\\s*=\\s*\\'[0-9]+\\.[0-9]+\\.[0-9]+\\'
packages/xbridge_flutter/android/build.gradle|^version\\s*=\\s*\\'[0-9]+\\.[0-9]+\\.[0-9]+\\'
packages/xbridge-ios/XBridgeiOS.podspec|s\\.version\\s*=\\s*\\'[0-9]+\\.[0-9]+\\.[0-9]+\\'
packages/xbridge_flutter/ios/xbridge_flutter.podspec|s\\.version\\s*=\\s*\\'[0-9]+\\.[0-9]+\\.[0-9]+\\'
PAIRS
}

main() {
  if [ "$CHECK_MODE" -eq 1 ]; then
    local target
    if [ -n "$VER" ]; then
      target="$(norm "$VER")"; validate "$target"
    else
      target="$(latest_tag)"
    fi
    echo "[check] 期望版本：$target"
    local pairs; pairs="$(get_pairs "$target")"
    local o; o=0
    apply "$target" $pairs || o=1
    if [ "$o" -eq 0 ]; then
      echo "OK：全部 manifest 与版本 $target 一致。"
    else
      echo "版本不一致。请先 scripts/version.sh $target 同步。" >&2
    fi
    exit "$o"
  fi

  local version; version="$(norm "$VER")"; validate "$version"
  echo "[version] 统一版本号 → $version"
  local pairs; pairs="$(get_pairs "$version")"
  apply "$version" $pairs
  echo "完成。请提交后打 git tag v$(norm "$VER")（iOS podspec 依赖带 v 的 tag）。"
}

main