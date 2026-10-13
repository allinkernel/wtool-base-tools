#!/bin/sh
# export_test.sh —— ADR-0045 第 3 块：新 wtool.xml 标签 + L1/L2 两类链
#
# 这一组守的是"错了会静默出事"的那几条：
#   1. 精确语义标签的**硬约束**（D6/D19/D40/D41/D46）：没有 dest=、src 在 __output/ 下、
#      export_bin 是文件、白名单 6 个 part、① 类不许写这些标签、generate 二选一
#   2. **L1**：$WTOOL_HOME/wtool/<项目路径> → 工作区项目，**绝对**链、按项目惰性建
#   3. **L2**：$WTOOL_HOME/usr/<part>/<条目> → ../../wtool/<项目>/__output/…，**相对**链、
#      usr/<part> 是**实体目录**、逐条目一链
#   4. **记账**：L1/L2 都进 journal；链悬空后 `wtool check` **必须报出来**
#      （这是回归点 —— 老 `reg` + 按需 `link` 的写法在"链已存在且指向正确"时
#      什么都不记，悬空了 check 还报"一切对得上"，见 DESIGN §2.8 的假绿实测）
#   5. **冲突只报错**（D8/D60）：文案要请用户"找助手改设计"，不提供 --takeover
#
# ⚠️ 全程在临时工作区 + 临时 $WTOOL_HOME/$WTOOL_STATE 里跑，绝不碰真 $HOME/真工作区。
set -eu

# 先把外面可能残留的 WTOOL_* 清掉（跑测试的人可能刚在真工作区里跑过 wtool）
for _v in $(env | grep -o '^WTOOL_[A-Za-z_]*' || true); do unset "$_v"; done

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
WT="$boot/wtool.sh"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
         [ $# -gt 1 ] && printf '      %s\n' "$2"; return 0; }
chk()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }
hasnt(){ [ ! -e "$2" ] && ok "$1" || bad "$1" "（$2 不该存在）"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-export.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

newhome() {
    H=$(mktemp -d "$T/home.XXXXXX")
    printf '# 用户自己的 zshrc\nsetopt auto_cd\n' > "$H/.zshrc"
    # 新口径：WTOOL_HOME 就是 .wtool 根；账本在 var/ 下。
    export WTOOL_HOME="$H/.wtool" WTOOL_STATE="$H/.wtool/var"
    export WTOOL_MANAGED_HOME="$H"
    export WTOOL_LOG_ROOT="$T/logs"
    export WTOOL_ROOT="$T/ws"
}
mkproj() {   # <相对路径>：建项目目录 + git 仓库（install 要求干净仓库）
    d="$T/ws/$1"; mkdir -p "$d"
    git -C "$d" init -q
    echo "$d"
}
# 写清单：<项目目录> <kind> <元素行…>
wxml() {
    _d=$1; _kind=$2; shift 2
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<wtool schema="1" kind="%s" priority="50">\n' "$_kind"
        printf '%s\n' "$@"
        printf '</wtool>\n'
    } > "$_d/wtool.xml"
}
gitci() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t commit -qm init; }

# 约定的错误文案片段：列表里每条坏输入都要命中自己那一句
expect_err() {   # <标题> <项目目录> <文案片段> [第二个片段]
    _rc=0
    _out=$("$WT" validate "$2" 2>&1) || _rc=$?
    [ "$_rc" != 0 ] && ok "$1：报错（退出码 $_rc）" || bad "$1：居然过了（退出码 0）"
    case $_out in
        *"$3"*) ok "$1：文案说清了 —— $3" ;;
        *) bad "$1：文案没提『$3』" "$_out" ;;
    esac
    if [ $# -ge 4 ]; then
        case $_out in
            *"$4"*) ok "$1：还给了可照做的下一步（$4）" ;;
            *) bad "$1：没给下一步（$4）" "$_out" ;;
        esac
    fi
}

# --------------------------------------------------------------------------
printf '\n== 1. 好输入：L1 绝对 + L2 相对 + usr/<part> 实体目录 ==\n'
newhome
mkdir -p "$WTOOL_ROOT"
P=$(mkproj "tools/demo")
mkdir -p "$P/__output/usr/bin" "$P/__output/usr/share/man" "$P/scripts"
printf 'fzfbin\n' > "$P/__output/usr/bin/fzf"
printf 'rgbin\n'  > "$P/__output/rg-dbg"
printf 'manpage\n' > "$P/__output/usr/share/man/fzf.1"
printf '#!/bin/sh\ntrue\n' > "$P/scripts/gen-x.bash"
printf 'export DEMO=1\n' > "$P/env.zsh"
wxml "$P" muslbin \
    '<zshrc  src="env.zsh"/>' \
    '<muslbin url="https://github.com/junegunn/fzf/releases/download/v0.67.0/fzf-0.67.0-linux_amd64.tar.gz"' \
    '         tag="v0.67.0" sha256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"' \
    '         member="fzf" dest="usr/bin/fzf" arch="x86_64"/>' \
    '<export_bin src="__output/rg-dbg" name="rg"/>' \
    '<export_usr src="__output/usr"/>' \
    '<generate dest="__output/fzf.zsh" cmd="fzf --zsh"/>' \
    '<generate dest="__output/fzf.bash" script="scripts/gen-x.bash"/>'
gitci "$P"

_rc=0
_v=$("$WT" validate "$P" 2>&1) || _rc=$?
chk "★四种新标签齐全的清单 validate 通过" "$_rc" "0"
case $_v in
    *"error"*) bad "validate 报错了" "$_v" ;;
    *) ok "validate 没有报错" ;;
esac
# muslbin/generate 本轮**只解析 + 校验**：不建任何链、不落任何产物
hasnt "★<generate> 本轮不执行（__output/fzf.zsh 没被生成）" "$P/__output/fzf.zsh"

"$WT" install "$P" > "$T/i1.log" 2>&1 || bad "install 执行" "$(cat "$T/i1.log")"

L1="$WTOOL_HOME/wtool/tools/demo"
L2="$WTOOL_HOME/usr/bin/rg"
[ -L "$L1" ] && ok "L1 建出来了" || bad "L1 没建出来"
case "$(readlink "$L1" 2>/dev/null)" in
    /*) ok "L1 指向**绝对**路径（D11）" ;;
    *)  bad "L1 不是绝对路径" "$(readlink "$L1" 2>/dev/null)" ;;
esac
chk "L1 指向工作区里那个项目目录" "$P" "$(readlink "$L1" 2>/dev/null)"
[ -d "$WTOOL_HOME/wtool" ] && [ ! -L "$WTOOL_HOME/wtool" ] \
    && ok "\$WTOOL_HOME/wtool 是实体目录（L1 一条一链，D5）" \
    || bad "\$WTOOL_HOME/wtool 不是实体目录"
# 惰性：只建装过的那个项目
[ -L "$WTOOL_HOME/wtool/tools" ] && bad "L1 把父目录也做成了链" \
    || ok "L1 的父目录是实体目录（只有项目那一条是链）"

[ -L "$L2" ] && ok "L2（export_bin name=rg）建出来了" || bad "L2 没建出来"
chk "L2 指向**相对**路径（D45：两端都在 .wtool 里）" \
    "../../wtool/tools/demo/__output/rg-dbg" "$(readlink "$L2" 2>/dev/null)"
check_content=$(cat "$L2" 2>/dev/null || true)
chk "顺着 L2 读得到内容" "rgbin" "$check_content"
[ -e "$WTOOL_HOME/usr/share" ] && [ ! -L "$WTOOL_HOME/usr/share" ] \
    && ok "usr/share 是**实体目录**（多项目共享，D7）" \
    || bad "usr/share 不是实体目录"
chk "export_usr 逐条目建了 usr/bin/fzf" \
    "../../wtool/tools/demo/__output/usr/bin/fzf" \
    "$(readlink "$WTOOL_HOME/usr/bin/fzf" 2>/dev/null)"
chk "export_usr 把目录条目也建了链（usr/share/man）" \
    "../../wtool/tools/demo/__output/usr/share/man" \
    "$(readlink "$WTOOL_HOME/usr/share/man" 2>/dev/null)"
chk "usr/bin 下两条并存" "fzf rg" \
    "$(ls "$WTOOL_HOME/usr/bin" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# 幂等：第二次 install 一个字都不用改
_s1=$(find "$WTOOL_HOME" -mindepth 1 -printf '%y %p -> %l\n' | LC_ALL=C sort)
"$WT" install "$P" > "$T/i1b.log" 2>&1 || bad "第二次 install"
_s2=$(find "$WTOOL_HOME" -mindepth 1 -printf '%y %p -> %l\n' | LC_ALL=C sort)
chk "第二次 install 不改变文件树" "$_s1" "$_s2"
grep -q '没有需要变更的内容' "$T/i1b.log" && ok "第二次 install 报无变更" \
    || bad "第二次 install 没报无变更" "$(cat "$T/i1b.log")"

# --------------------------------------------------------------------------
printf '\n== 2. 坏输入：每条都必须报错且非 0 ==\n'
BAD="$T/ws/bad"; mkdir -p "$BAD"
mkbad() {   # <子目录名> <kind> <元素行…> → 打印项目目录
    _d="$BAD/$1"; _kind=$2; shift 2
    rm -rf "$_d"; mkdir -p "$_d/__output/usr/bin" "$_d/__output/usr/share/man" \
        "$_d/scripts" "$_d/__output/usr/etc"
    printf 'x\n' > "$_d/__output/usr/bin/fzf"
    printf 'm\n' > "$_d/__output/usr/share/man/f.1"
    printf 'y\n' > "$_d/__output/usr/etc/other.conf"
    printf 'z\n' > "$_d/src.conf"
    printf '#!/bin/sh\ntrue\n' > "$_d/scripts/g.bash"
    wxml "$_d" "$_kind" "$@"
    echo "$_d"
}

# ① export_bin 的 src 指向目录（D40 表格里的硬约束）
B=$(mkbad dir docker '<export_bin src="__output/usr/share/man"/>')
expect_err "① export_bin 指向目录" "$B" "必须是**一个文件**" "export_usr"
# ② src 指到源码树（不在 __output/ 下）
B=$(mkbad src docker '<export_bin src="src.conf"/>')
expect_err "② src 指到源码树" "$B" "必须在项目的 __output/ 之下" "① 类"
# ③ ① 类（kind=source）写导出标签
B=$(mkbad oneproj source '<export_bin src="__output/usr/bin/fzf"/>')
expect_err "③ ① 类写 <export_bin>" "$B" "不该出现在 kind=\"source\"" "源码即产物"
# ④ export_usr part= 不在白名单（D19）
B=$(mkbad part docker '<export_usr src="__output/usr" part="man"/>')
expect_err "④ part= 不在白名单" "$B" "不在白名单里" "bin / lib / libexec / share / include / local"
# ⑤ export_usr 遇到白名单外的子目录（要**列出它**）
B=$(mkbad stranger docker '<export_usr src="__output/usr"/>')
expect_err "⑤ 白名单外的子目录" "$B" "白名单外的子目录: etc" "找用户拍板"
# ⑥ 同一个项目里两条声明撞同一个落点
B=$(mkbad dup docker '<export_bin src="__output/usr/bin/fzf"/>' \
                     '<export_usr src="__output/usr" part="bin"/>')
expect_err "⑥ 两条声明指向同一个落点" "$B" "两条声明指向同一个落点"
# ⑦/⑧ generate：cmd 与 script **二选一**
B=$(mkbad gen2 docker '<generate dest="__output/x" cmd="true" script="scripts/g.bash"/>')
expect_err "⑦ generate 两个都给" "$B" "cmd= 和 script= **只能给一个**"
B=$(mkbad gen0 docker '<generate dest="__output/x"/>')
expect_err "⑧ generate 两个都没给" "$B" "二选一"
# ⑨ generate 的 dest 必须在 __output/ 下（D41）
B=$(mkbad gendest docker '<generate dest="fzf.zsh" cmd="true"/>')
expect_err "⑨ generate dest 不在 __output/ 下" "$B" "必须在项目的 __output/ 之下"
# ⑩ 任何标签都没有 dest=（D6）
B=$(mkbad dest docker '<export_bin src="__output/usr/bin/fzf" dest="usr/bin/x"/>')
expect_err "⑩ <export_bin> 写了 dest=" "$B" "没有 dest= 参数"
# ⑪ <muslbin> 用在非 ② 类
B=$(mkbad mbkind docker '<muslbin url="https://x/y.tar.gz" tag="v1" member="f" dest="usr/bin/f"/>')
expect_err "⑪ <muslbin> 用在 ③ 类" "$B" "只对 kind=\"muslbin\""
# ⑫ sha256 的形状
B=$(mkbad mbsha muslbin '<muslbin url="https://x/y.tar.gz" tag="v1" sha256="abc" member="f" dest="usr/bin/f"/>')
expect_err "⑫ sha256 不是 64 位十六进制" "$B" "64 位十六进制"
# ⑬ arch 只做 x86_64
B=$(mkbad mbarch muslbin '<muslbin url="https://x/y.tar.gz" tag="v1" sha256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" member="f" dest="usr/bin/f" arch="aarch64"/>')
expect_err "⑬ arch 不是 x86_64" "$B" "当前只做 x86_64"
# ⑭ 产物还没出来（__output/ 里没有那个文件）—— 报错要指路
B=$(mkbad miss docker '<export_bin src="__output/usr/bin/nope"/>')
expect_err "⑭ src 不在磁盘上" "$B" "src 不存在" "download-release"
# ⑮ 旧 <link> 已经删掉（D3）
B=$(mkbad oldlink docker '<link home="~/.x.conf" subproject="src.conf"/>')
expect_err "⑮ 旧 <link> 已删" "$B" "<link> 已经删掉" "export_bin"

# ⚠️ 这些**故意写坏**的清单必须挪出工作区：后面几节要 `wtool check` 整棵工作区，
#    留着它们就会一路报"清单有问题"（实测踩过：那不是后面几节要验的东西）。
mv "$BAD" "$T/bad-outside"

# --------------------------------------------------------------------------
printf '\n== 3. 记账：L1/L2 都进 journal；悬空之后 check 必须报出来 ==\n'
newhome
mkdir -p "$WTOOL_ROOT"
P=$(mkproj "tools/ledger")
mkdir -p "$P/__output/usr/bin"
printf 'bin\n' > "$P/__output/usr/bin/led"
wxml "$P" docker '<export_bin src="__output/usr/bin/led"/>'
gitci "$P"
"$WT" install "$P" > /dev/null 2>&1 || bad "install"

J="$WTOOL_STATE/tools/ledger/journal.tsv"
L1="$WTOOL_HOME/wtool/tools/ledger"
L2="$WTOOL_HOME/usr/bin/led"
grep -q "^link	dir	$L1	$P	" "$J" && ok "★L1 进了账本（link dir <L1> <项目目录>）" \
    || bad "★L1 没进账本" "$(cat "$J")"
grep -q "^link	file	$L2	" "$J" && ok "L2 也进了账本" || bad "L2 没进账本" "$(cat "$J")"

_rc=0
"$WT" check > /dev/null 2>&1 || _rc=$?
chk "装完 check 干净" "$_rc" "0"

# ★ 回归点 A：账本被清掉、链还在 —— 重装之后**必须**把 L1 重新记上。
#   老写法（reg + 按需 link）在"链已存在且指向正确"时只发 reg：
#   账本里永远不会有这条，于是它悬空之后 check 看不见（DESIGN §2.8 的假绿）。
: > "$J"
"$WT" install "$P" > /dev/null 2>&1 || bad "重装（账本已清）"
grep -q "^link	dir	$L1	" "$J" \
    && ok "★链已存在时重装也把 L1 记进账本（reglink）" \
    || bad "★链已存在时账没记上（老写法会这样）" "$(cat "$J")"

# ★ 回归点 B：L2 的目标没了（项目还在）→ check 必须点名"悬空"
rm -f "$P/__output/usr/bin/led"
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★L2 目标没了 → check 非 0" || bad "★check 假绿（退出码 0）"
case $_out in
    *悬空*) ok "★说清了是**悬空**（链在、目标不在）" ;;
    *) bad "★没说'悬空'" "$_out" ;;
esac
printf 'bin\n' > "$P/__output/usr/bin/led"
_rc=0
"$WT" check > /dev/null 2>&1 || _rc=$?
chk "目标补回来之后 check 又干净" "$_rc" "0"

# ★ 回归点 C：整个项目目录没了（工作区搬走）→ L1 悬空，check 必须点名
mv "$P" "$P.gone"
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★L1 悬空 → check 非 0" || bad "★check 假绿（退出码 0）"
case $_out in
    *"$L1"*) ok "★点名了那条 L1 路径" ;;
    *) bad "★没点名 L1" "$_out" ;;
esac
case $_out in
    *悬空*) ok "★说清了是悬空软链" ;;
    *) bad "★没说悬空" "$_out" ;;
esac
mv "$P.gone" "$P"
_rc=0
"$WT" check > /dev/null 2>&1 || _rc=$?
chk "项目搬回来之后 check 又干净" "$_rc" "0"

# uninstall：L1/L2 都逆放掉
"$WT" uninstall "$P" > /dev/null 2>&1 || bad "uninstall"
hasnt "uninstall 拆掉了 L2" "$L2"
hasnt "uninstall 拆掉了 L1（D5：只删那一条链）" "$L1"
_rc=0
"$WT" check > /dev/null 2>&1 || _rc=$?
chk "uninstall 之后 check 干净（没留残渣）" "$_rc" "0"

# --------------------------------------------------------------------------
printf '\n== 4. L2 冲突只报错：文案请用户找助手、不提供 --takeover（D8/D60）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
A=$(mkproj "tools/musl-bins"); B=$(mkproj "terminal/fzf")
for _d in "$A" "$B"; do
    mkdir -p "$_d/__output/usr/bin"; printf 'bin\n' > "$_d/__output/usr/bin/fzf"
    wxml "$_d" muslbin '<export_bin src="__output/usr/bin/fzf"/>'
    gitci "$_d"
done
"$WT" install "$A" > /dev/null 2>&1 || bad "装 A"
_rc=0
_out=$("$WT" install "$B" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "第二个项目要同一条落点 → 非 0" || bad "冲突居然过了"
case $_out in
    *"已被 tools/musl-bins 占用"*) ok "指出占用者是谁" ;;
    *) bad "没说占用者" "$_out" ;;
esac
case $_out in
    *"找助手"*) ok "★文案请用户**找助手改设计**（不设计 --takeover）" ;;
    *) bad "★文案里没有'找助手'" "$_out" ;;
esac
chk "冲突之后落点还是 A 的（没被改坏）" \
    "../../wtool/tools/musl-bins/__output/usr/bin/fzf" \
    "$(readlink "$WTOOL_HOME/usr/bin/fzf" 2>/dev/null)"
_rc=0
_out=$("$WT" install "$B" --takeover 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★没有 --takeover 这个口子（敲了就是不认识）" || bad "--takeover 被认了"
case $_out in
    *"未知参数"*) ok "报的是'未知参数: --takeover'" ;;
    *) bad "没说清 --takeover 不认" "$_out" ;;
esac

# --------------------------------------------------------------------------
printf '\n== 5. ① 类：不写导出标签也能装（源码即产物，走 L1）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
C=$(mkproj "terminal/tmux")
printf 'set -g mouse on\n' > "$C/tmux.conf"
printf 'export T=1\n' > "$C/env.zsh"
wxml "$C" source '<zshrc src="env.zsh"/>'
gitci "$C"
"$WT" install "$C" > "$T/i5.log" 2>&1 || bad "① 类 install" "$(cat "$T/i5.log")"
[ -d "$WTOOL_HOME/wtool/terminal/tmux" ] && ok "① 类有 L1（项目在哪）" \
    || bad "① 类没有 L1"
hasnt "① 类不建任何 L2（usr/bin 下没有它的东西）" "$WTOOL_HOME/usr/bin/tmux.conf"
# 顺着 L1 读得到源码本身 —— 这就是 ① 类"源码即产物"的判据
chk "顺着 L1 读到源码文件" "set -g mouse on" \
    "$(cat "$WTOOL_HOME/wtool/terminal/tmux/tmux.conf" 2>/dev/null)"

# --------------------------------------------------------------------------
printf '\nexport_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
