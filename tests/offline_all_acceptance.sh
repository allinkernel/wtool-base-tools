#!/bin/sh
# offline_all_acceptance.sh —— **整机包在目标机（容器）里的验收 + 逐项目功能矩阵**
#
# 用法（在容器里跑，root 或普通用户都行，只要 $HOME 可写）：
#
#     sh offline_all_acceptance.sh <整机包.tar.gz> <目标 $HOME> [<矩阵输出文件>]
#
# 四步（每条失败都非 0 退出，并说清是哪一步）：
#   1) `tar xf` 到 `$HOME` → `$HOME/.wtool`；并断言 **`$HOME/usr` 不存在**
#      （2026-10-21 口径：装完只多 `.wtool/` 与 rc 两行）
#   2) `$HOME/.wtool/install.sh --no-rc` → **rc=0**
#   3) 干净 PATH（摘掉 wtool 目录、摘掉所有 WTOOL_*）下 `wtool check` → **rc=0**
#   4) **逐项目功能探针**：拿包里 `var/offline-all.tsv` 的项目表，按 kind 挑探针
#        · ② muslbin → `$WTOOL_HOME/usr/bin/<命令> --version`（44 个逐个跑）
#        · ③ docker  → `zsh --version` + `zsh -ic 'echo ok'`
#        · ① source  → 项目声明面：L1 有内容、每条 env 块能单独 source、
#                      再加这个项目自己的那条命令/变量探针（下面 PROBE_* 那张表）
#      每个项目打一行：`MATRIX<TAB><项目id><TAB><kind><TAB>OK|FAIL<TAB><依据>`
#
# 退出码：0 全过；1 有失败（会打印 `MATRIX-SUMMARY` 和失败清单）。
#
# ⚠️ 这个脚本**只读**解出来的 `.wtool`，不联网（下载归 pack 那一侧）。
set -u

PKG=${1:-}
THOME=${2:-}
OUT=${3:-}
if [ -z "$PKG" ] || [ -z "$THOME" ]; then
    printf 'usage: sh %s <整机包.tar.gz> <目标 HOME> [矩阵输出]\n' "$0" >&2
    exit 2
fi
[ -f "$PKG" ] || { printf '错误: 包不存在: %s\n' "$PKG" >&2; exit 2; }
say()  { printf '%s\n' "$*"; }
step() { printf '\n=== %s\n' "$*"; }
bad()  { printf '✗ %s\n' "$*" >&2; }

say "包      : $PKG（$(wc -c < "$PKG" | tr -d ' ') 字节）"
say "目标 HOME: $THOME"
mkdir -p -- "$THOME" || { bad "建不了 $THOME"; exit 2; }
# 绝对路径（install.sh 要求 WTOOL_HOME 是绝对路径）
THOME=$(cd -- "$THOME" && pwd -P)

# ---------------------------------------------------------------------------
# 1) 解包 + `~/usr` 不该被造出来
# ---------------------------------------------------------------------------
step "1) tar xf → $THOME/.wtool"
rm -rf -- "$THOME/.wtool"
tar xf "$PKG" -C "$THOME" || { bad "tar xf 失败"; exit 1; }
[ -d "$THOME/.wtool" ] || { bad "解开之后没有 .wtool/"; exit 1; }
if [ -e "$THOME/usr" ] || [ -L "$THOME/usr" ]; then
    bad "包解开就有 \$HOME/usr —— 不该有（整机包不带它）"; exit 1
fi
say "✔ 解开：$(find "$THOME/.wtool" | wc -l | tr -d ' ') 个条目；\$HOME/usr 不存在"

W=$THOME/.wtool

# ---------------------------------------------------------------------------
# 2) install.sh
# ---------------------------------------------------------------------------
step "2) $W/install.sh --no-rc"
if ! ( cd "$W" && HOME="$THOME" WTOOL_HOME="$W" sh ./install.sh --no-rc ) \
        > "$THOME/install.log" 2>&1; then
    bad "install.sh 非 0 退出 —— 最后 30 行："
    tail -n 30 -- "$THOME/install.log" >&2
    exit 1
fi
say "✔ install.sh rc=0（日志 $THOME/install.log）"
grep -E '^(wtool-install: .*(✔|SELFCHECK)|.*自检)' "$THOME/install.log" | head -8

# ---------------------------------------------------------------------------
# 3) 干净 PATH 下的 `wtool check`
# ---------------------------------------------------------------------------
step "3) 干净 PATH 下 wtool check"
_clean_path=$(printf '%s' "${PATH:-/usr/bin:/bin}" | tr ':' '\n' \
    | awk -v h="$W" 'length($0) && index($0,h)==0 {printf "%s%s", sep, $0; sep=":"}')
[ -n "$_clean_path" ] || _clean_path=/usr/bin:/bin
_unset_args=""
for _uv in $(env | sed -n 's/^\(WTOOL[A-Za-z_]*\)=.*/-u \1/p'); do
    _unset_args="$_unset_args $_uv"
done
# shellcheck disable=SC2086
if ! env $_unset_args HOME="$THOME" PATH="$_clean_path" \
        bash -c 'WTOOL_HOME=$1; export WTOOL_HOME; . "$WTOOL_HOME/env.bash"; wtool check' \
        _ "$W" > "$THOME/check.log" 2>&1; then
    bad "wtool check 非 0 —— 最后 30 行："
    tail -n 30 -- "$THOME/check.log" >&2
    exit 1
fi
say "✔ wtool check rc=0：$(tail -1 -- "$THOME/check.log")"

# `~/usr` 装完仍然不该有
if [ -e "$THOME/usr" ] || [ -L "$THOME/usr" ]; then
    bad "install 之后 \$HOME/usr 出现了（本轮口径：不再创建它）"; exit 1
fi
say "✔ \$HOME/usr 仍然不存在（判据：test -e / -L 都不成立）"

# `wtool status` 必须与 `wtool check` **同一个结论**（2026-10-21 用户实测的矛盾）
step "3b) status 与 check 结论一致"
# shellcheck disable=SC2086
env $_unset_args HOME="$THOME" PATH="$_clean_path" \
    bash -c 'WTOOL_HOME=$1; export WTOOL_HOME; . "$WTOOL_HOME/env.bash"; wtool status' \
    _ "$W" > "$THOME/status.log" 2>&1 || true
# PATH 里不许有重复项（2026-10-21 VM 实测：env 汇总把每个项目 source 了两次）
_dups=$(env HOME="$THOME" PATH="$_clean_path" WTOOL_HOME="$W" bash -c \
        '. "$1"; printf "%s" "$PATH"' _ "$W/env.bash" \
        | tr ':' '\n' | sed '/^$/d' | sort | uniq -d)
if [ -n "$_dups" ]; then
    bad "source env.bash 之后 PATH 里有重复项："
    printf '%s\n' "$_dups" | head -5 >&2
    exit 1
fi
say "✔ PATH 没有重复项（env 汇总没有把项目 source 两次）"

_status_line=$(grep -E '个项目：正常' "$THOME/status.log" | tail -1)
case $_status_line in
    *"正常"*"悬空 0"*"缺失 0"*"未安装 0"*)
        say "✔ $_status_line" ;;
    *)
        bad "status 与 check 对不上（check rc=0 但 status 不是全绿）："
        tail -n 20 -- "$THOME/status.log" >&2
        exit 1 ;;
esac

# 野文件 / 误入物断言（用户实测：10-14 的包里带过 `t_publish_repo_of() {,+30p`）
step "3c) 包内没有野文件"
_wild=$(find "$W" \( -name '*t_publish_repo_of*' -o -name '*.orig' -o -name '*.rej' \
        -o -name '*.swp' -o -name 'musl.tar*' -o -name '*~' \) -print 2>/dev/null | head -5)
if [ -n "$_wild" ]; then
    bad "包里有野文件："; printf '%s\n' "$_wild" >&2; exit 1
fi
_big=$(find "$W/wtool" -type f -size +20M 2>/dev/null \
       | grep -v '/__output/' | head -5 || true)
if [ -n "$_big" ]; then
    bad "源文件 >20MB（多半是事故产物）："; printf '%s\n' "$_big" >&2; exit 1
fi
say "✔ 没有野文件；源码文件没有一个 >20MB"

# ---------------------------------------------------------------------------
# 4) **portable 模式**（借用机器：不改 ~/.bashrc，生成 wtool-bashrc / wtool-zshrc）
# ---------------------------------------------------------------------------
step "4) portable 模式（借用机器那条路）"
printf '# 用户自己的 rc（不该被动）\n' > "$THOME/.bashrc"
_before_sum=$(sha256sum "$THOME/.bashrc" | cut -d' ' -f1)
_before_mt=$(stat -c %Y "$THOME/.bashrc")
mkdir -p -- "$THOME/borrowed"
tar xf "$PKG" -C "$THOME/borrowed" || { bad "tar xf（portable）失败"; exit 1; }
_BW=$THOME/borrowed/.wtool
# ⚠️ 不能加 `--no-rc`：那是 `--rc-mode none`，portable 的"生成两份 rc 文件"也会被关掉。
if ! ( cd "$_BW" && HOME="$THOME" sh ./install.sh --portable ) \
        > "$THOME/install-portable.log" 2>&1; then
    bad "portable 模式 install.sh 非 0 —— 最后 25 行："
    tail -n 25 -- "$THOME/install-portable.log" >&2
    exit 1
fi
grep -q '落点模式：\*\*portable\*\*' "$THOME/install-portable.log" \
    || bad "portable 模式没打印判定依据（不静默切换）"
for _f in "$THOME/borrowed/wtool-bashrc" "$THOME/borrowed/wtool-zshrc"; do
    [ -f "$_f" ] || { bad "没有生成 $_f"; exit 1; }
done
[ "$(sha256sum "$THOME/.bashrc" | cut -d' ' -f1)" = "$_before_sum" ] \
    || { bad "portable 模式改了 \$HOME/.bashrc（内容变了）"; exit 1; }
[ "$(stat -c %Y "$THOME/.bashrc")" = "$_before_mt" ] \
    || { bad "portable 模式改了 \$HOME/.bashrc（mtime 变了）"; exit 1; }
# 两份 rc 都幂等：source 两次 PATH 长度不变
for _pf in bash zsh; do
    _rcf="$THOME/borrowed/wtool-${_pf}rc"
    # zsh 用**包里那份**（干净 PATH 上没有系统 zsh；用 bash 去 source 一份 zsh rc
    # 测出来的"不幂等"是假的 —— 2026-10-21 实测撞过）
    if [ "$_pf" = zsh ]; then _sh="$W/usr/bin/zsh"; else _sh=bash; fi
    command -v "$_sh" >/dev/null 2>&1 || _sh=bash
    _p1=$(env -u WTOOL_HOME HOME="$THOME" PATH="$_clean_path" "$_sh" -c \
          '. "$1"; . "$1"; printf "%s" "$PATH"' _ "$_rcf" 2>/dev/null)
    _p2=$(env -u WTOOL_HOME HOME="$THOME" PATH="$_clean_path" "$_sh" -c \
          '. "$1"; printf "%s" "$PATH"' _ "$_rcf" 2>/dev/null)
    [ -n "$_p1" ] && [ "$_p1" = "$_p2" ] \
        || { bad "source 两次 $_rcf 之后 PATH 变了（不幂等）"; exit 1; }
    case $_p1 in
        *"$THOME/borrowed/.wtool/usr/bin"*) : ;;
        *) bad "$_rcf 没有把 \$WTOOL_HOME/usr/bin 放进 PATH" ;;
    esac
done
# source 之后 wtool 能跑、check rc=0、没有 $HOME/usr
_pw=$(env HOME="$THOME" PATH="$_clean_path" bash -c \
      '. "$1"; command -v wtool' _ "$THOME/borrowed/wtool-bashrc" 2>/dev/null)
case $_pw in
    "$THOME/borrowed/.wtool"/*) : ;;
    *) bad "portable source 之后 wtool 解析到「$_pw」（应在本机的 .wtool 里）"; exit 1 ;;
esac
if ! env HOME="$THOME" PATH="$_clean_path" bash -c \
        '. "$1"; wtool check' _ "$THOME/borrowed/wtool-bashrc" \
        > "$THOME/check-portable.log" 2>&1; then
    bad "portable 模式下 wtool check 非 0："; tail -n 20 -- "$THOME/check-portable.log" >&2; exit 1
fi
[ ! -e "$THOME/usr" ] && [ ! -L "$THOME/usr" ] \
    || { bad "portable 装完出现了 \$HOME/usr"; exit 1; }
say "✔ portable：install.sh rc=0、生成两份 rc、\$HOME/.bashrc 没动、source 后 wtool 可用、check rc=0、无 ~/usr"

# ---------------------------------------------------------------------------
# 5) 逐项目功能探针
# ---------------------------------------------------------------------------
step "5) 逐项目功能探针"
_probe_lines="$THOME/matrix.tsv"
: > "$_probe_lines"

# 每个 source 项目自己的那条探针。`-` = 只验通用项（声明面 / env 块）。
# 判据都是"装了就该能跑"，不是"文件在不在"。
probe_source() {   # <pid> → 打印依据；rc=0 通过
    _p=$1
    case $_p in
        shell/shell-rc)
            env HOME="$THOME" WTOOL_HOME="$W" bash -c '. "$WTOOL_HOME/env.bash"; alias gs' \
                >/dev/null 2>&1 || { say 'alias gs 取不到'; return 1; }
            say 'bash -c . env.bash → alias gs' ;;
        shell/oh-my-zsh)
            env HOME="$THOME" WTOOL_HOME="$W" "$W/usr/bin/zsh" -ic 'echo ok' 2>/dev/null \
                | grep -qx ok || { say 'zsh -i 起不来'; return 1; }
            say 'zsh -ic echo ok' ;;
        terminal/tmux)
            env HOME="$THOME" WTOOL_HOME="$W" bash -c \
                '. "$WTOOL_HOME/env.bash"; [ -n "$WTOOL_TMUX_DIR" ] && [ -d "$WTOOL_TMUX_DIR" ]' \
                || { say 'WTOOL_TMUX_DIR 没设或不在'; return 1; }
            say 'WTOOL_TMUX_DIR 在' ;;
        terminal/fzf)
            env HOME="$THOME" WTOOL_HOME="$W" bash -c \
                '. "$WTOOL_HOME/env.bash"; fzf --version' 2>/dev/null | grep -q . \
                || { say 'fzf --version 没输出'; return 1; }
            say 'fzf --version（PATH 由 env 块给）' ;;
        os/ubuntu)
            [ -n "$(ls -A -- "$W/wtool/os/ubuntu" 2>/dev/null)" ] \
                || { say 'L1 目录是空的'; return 1; }
            say 'L1 有内容（纯数据项目，无命令）' ;;
        tools/git-repo-sh-tools)
            env HOME="$THOME" WTOOL_HOME="$W" bash -c \
                '. "$WTOOL_HOME/env.bash"; type gb >/dev/null 2>&1; type cdd >/dev/null 2>&1' \
                || { say 'gb / cdd 不是函数'; return 1; }
            say 'type gb / type cdd' ;;
        tools/android_repack)
            env HOME="$THOME" WTOOL_HOME="$W" bash -c \
                '. "$WTOOL_HOME/env.bash"; command -v wpack >/dev/null' \
                || { say 'wpack 不在 PATH 上（项目脚本装的命令没进包？）'; return 1; }
            say 'command -v wpack' ;;
        wtool-base-tools)
            env HOME="$THOME" WTOOL_HOME="$W" bash -c \
                '. "$WTOOL_HOME/env.bash"; wtool --help >/dev/null' \
                || { say 'wtool --help 非 0'; return 1; }
            say 'wtool --help' ;;
        *)
            say '无命令探针（只验声明面）' ;;
    esac
}

# 项目表 = 包里的来源记录（`var/offline-all.tsv`）：pid / commit / kind / at / osver
[ -f "$W/var/offline-all.tsv" ] || { bad "包里没有 var/offline-all.tsv（来源记录）"; exit 1; }
_n=0
_ok=0
_fail=0
_fails=""
while IFS="$(printf '\t')" read -r _pid _commit _kind _at _osv; do
    case $_pid in ''|'#'*) continue ;; esac
    _n=$((_n + 1))
    _detail=""
    _rc=0
    # ---- 通用项（所有项目）：L1 有内容 + 每条 env 块能单独 source --------------
    if [ ! -d "$W/wtool/$_pid" ] || [ -z "$(ls -A -- "$W/wtool/$_pid" 2>/dev/null)" ]; then
        _detail="L1 不在或空"; _rc=1
    fi
    if [ "$_rc" = 0 ]; then
        for _f in "$W/var/$_pid"/env.zsh "$W/var/$_pid"/env.bash; do
            [ -f "$_f" ] || continue
            case $_f in
                *.zsh)  _sh=$W/usr/bin/zsh; [ -x "$_sh" ] || _sh=zsh ;;
                *)      _sh=bash ;;
            esac
            command -v "$_sh" >/dev/null 2>&1 || continue
            env HOME="$THOME" WTOOL_HOME="$W" "$_sh" -c '. "$1"' _ "$_f" \
                >/dev/null 2>&1 || { _detail="env 块单独 source 失败: $(basename "$_f")"; _rc=1; }
        done
    fi
    # ---- 按 kind 的探针 ---------------------------------------------------
    if [ "$_rc" = 0 ]; then
        case $_kind in
            muslbin)
                _dest=$(sed -n 's/.*<muslbin[^>]*dest="\([^"]*\)".*/\1/p' \
                        "$W/wtool/$_pid/wtool.xml" 2>/dev/null | head -1)
                _cmd=$(basename -- "${_dest:-?}")
                _out=$("$W/usr/bin/$_cmd" --version 2>&1 | head -1)
                if [ -z "$_out" ]; then _detail="$_cmd --version 没输出"; _rc=1
                else _detail="$_cmd --version → $_out"; fi
                ;;
            docker)
                _out=$("$W/usr/bin/zsh" --version 2>&1 | head -1)
                if [ -z "$_out" ]; then _detail="zsh --version 没输出"; _rc=1
                else
                    if "$W/usr/bin/zsh" -ic 'echo ok' 2>/dev/null | grep -qx ok; then
                        _detail="$_out；zsh -ic echo ok"
                    else
                        _detail="$_out；但 zsh -ic 起不来"; _rc=1
                    fi
                fi
                ;;
            source)
                _detail=$(probe_source "$_pid") || _rc=1
                ;;
            *)
                _detail="未知 kind=$_kind"; _rc=1 ;;
        esac
    fi
    if [ "$_rc" = 0 ]; then
        _ok=$((_ok + 1))
        printf 'MATRIX\t%s\t%s\tOK\t%s\n' "$_pid" "$_kind" "$_detail" | tee -a "$_probe_lines"
    else
        _fail=$((_fail + 1))
        _fails="$_fails $_pid"
        printf 'MATRIX\t%s\t%s\tFAIL\t%s\n' "$_pid" "$_kind" "$_detail" | tee -a "$_probe_lines"
    fi
done < "$W/var/offline-all.tsv"

printf 'MATRIX-SUMMARY\t%d\t%d\t%d\n' "$_n" "$_ok" "$_fail"
if [ -n "$OUT" ]; then
    cp -f -- "$_probe_lines" "$OUT" 2>/dev/null \
        || printf '（矩阵写不到 %s）\n' "$OUT" >&2
fi
if [ "$_fail" -gt 0 ]; then
    bad "有 $_fail 个项目探针失败：$_fails"
    exit 1
fi
say "✔ 全部 $_n 个项目探针通过（无失败）"
exit 0
