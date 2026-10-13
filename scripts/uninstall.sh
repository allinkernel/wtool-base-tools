#!/bin/sh
# wtool-base-tools 的卸载器 —— 撤销 ./install.sh 做的事。（2026-10-13 前这个项目叫 bootstrap）
#
# 只做可逆的事：
#   1. 让 wtool 把各项目的 install 逆着做一遍（wtool uninstall）
#   2. 收掉 install.sh 建的**两条入口链**（`$WTOOL_HOME/install.sh` →
#      `wtool/install.sh` → `<项目>/scripts/install.sh`，ADR-0045 §1.8 职责①）
#      —— 清单在账本里：`$WTOOL_HOME/var/installer/links.tsv`
#   3. 顺手收掉**老位置** `$WTOOL_HOME/bootstrap` 的悬空链（ADR-0045 D23 之前引擎
#      自举到那儿、之后不再有它 —— **这是历史路径字面量，不是项目名**；只删软链，
#      绝不动实体目录）
#
# 不碰系统依赖（apt 装的东西可能别的软件也在用），也不删工作区本身。
#
# 用法：
#   ./uninstall.sh [--dry-run] [--no-script]
set -eu

self=$0
while [ -L "$self" ]; do
    target=$(readlink -- "$self")
    case $target in
        /*) self=$target ;;
        *)  self=$(dirname -- "$self")/$target ;;
    esac
done
here=$(cd -- "$(dirname -- "$self")" && pwd)          # = <项目>/scripts
proj=$(cd -- "$here/.." && pwd)                     # = <项目>

say() { printf 'wtool-base-tools: %s\n' "$*"; }
die() { printf 'wtool-base-tools: 错误: %s\n' "$*" >&2; exit 1; }

HOME_DIR=${HOME:-/root}
# `$WTOOL_HOME` = `.wtool` 根目录（ADR-0045 / D47）；没有才退回 `$HOME/.wtool`
WTOOL_HOME_DIR=${WTOOL_HOME:-$HOME_DIR/.wtool}
BOOT_DST=${WTOOL_BOOTSTRAP_DST:-$WTOOL_HOME_DIR/bootstrap}   # 老位置（只做收尾）
DRY=0
NO_SCRIPT=0
for arg in "$@"; do
    case $arg in
        --dry-run)   DRY=1 ;;
        --no-script) NO_SCRIPT=1 ;;
        --force)     ;;   # 兼容：卸载本来就是幂等的
        -*)          die "未知参数: $arg" ;;
    esac
done

# 被引擎调用时（`wtool uninstall <项目>` 那条路）：这里什么都不做，直接退出。
# ⚠️ 引擎**现在并不会调这个脚本** —— 它跑的是 `scripts/install.sh --uninstall`
#    （见 `wtool.sh` 的 cmd_uninstall，契约在 docs/spec.md）。这一支留着，是为了
#    "万一有人这么调"时不做危险的事；对称于 install.sh 在同样情况下的早退。
if [ -n "${WTOOL_PROJECT_ID:-}" ]; then
    say "由引擎调用（项目 ${WTOOL_PROJECT_ID}）：引擎走的是 install.sh --uninstall，这里什么都不做"
    exit 0
fi

if [ -x "$proj/wtool.sh" ]; then
    say "让 wtool 逆着卸载各个项目"
    _ws=$(dirname -- "$proj")
    python3 "$proj/lib/wtool_plan.py" list-projects --root "$_ws" 2>/dev/null |
    while IFS='	' read -r _prio _pid _path; do
        [ -n "${_path:-}" ] || continue
        _extra=""
        [ "$NO_SCRIPT" = 1 ] && _extra="--no-script"
        if [ "$DRY" = 1 ]; then
            "$proj/wtool.sh" uninstall "$_path" --dry-run $_extra || true
        else
            "$proj/wtool.sh" uninstall "$_path" --force $_extra || true
        fi
    done
fi

say "收掉 install.sh 建的两条入口链"
_links="$WTOOL_HOME_DIR/var/installer/links.tsv"
if [ -f "$_links" ]; then
    # 账本里记的是"相对 $WTOOL_HOME 的落点 + 当初那个相对目标"（ADR-0045 §1.8 ②）。
    # 三道验：还是软链、还指向当初那个目标、账上确实有它 —— 缺一条就不动。
    while IFS='	' read -r _rel_dest _rel_target _ts; do
        [ -n "${_rel_dest:-}" ] || continue
        _dest=$WTOOL_HOME_DIR/$_rel_dest
        if [ -L "$_dest" ] && [ "$(readlink -- "$_dest")" = "$_rel_target" ]; then
            [ "$DRY" = 1 ] || rm -f -- "$_dest"
            say "  已删除 $_dest"
        else
            say "  $_dest 不在（或已不是我们建的那条链），跳过"
        fi
    done < "$_links"
    [ "$DRY" = 1 ] || rm -rf -- "$WTOOL_HOME_DIR/var/installer"
    # 账本目录空了就收掉（和引擎自己那条清理规则一致：非空一律留着）
    [ "$DRY" = 1 ] || rmdir -- "$WTOOL_HOME_DIR/var" 2>/dev/null || true
else
    say "  没有 $_links（这台机器上没跑过 install.sh），跳过"
fi

# 老位置（第 5b 块之前 install.sh 把引擎自举到 $WTOOL_HOME/bootstrap；D23 之后
# 不再有它）。老机器上可能留着一条**悬空**链，顺手收掉 —— 只删软链。
if [ -L "$BOOT_DST" ]; then
    if [ -e "$BOOT_DST" ]; then
        say "  （老位置 $BOOT_DST 还指着活的东西，留着不动）"
    else
        [ "$DRY" = 1 ] || rm -f -- "$BOOT_DST"
        say "  已删除老位置 $BOOT_DST（悬空链）"
    fi
else
    say "  老位置 $BOOT_DST 不在，跳过"
fi

say "卸载完成"
say ""
say "注意："
say "  * 系统依赖（apt 装的）没有动 —— 可能别的软件也在用，自己看着删"
say "  * 工作区目录本身没有删"
say "  * manifest 三件套（\$WTOOL_HOME/wtool/.repo/manifests）没删：它是包/工作区的东西，"
say "    不属于安装器的账；不想要就自己删那三个文件"
say "  * 项目自己的 install.sh 往 \$HOME 放的东西，由它自己负责收拾"
