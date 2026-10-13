#!/bin/sh
# muslbin_test.sh —— ADR-0045 第 ⑦.2 块：② 类的「下载 → 解包 → 安装」+ `<generate>`
#
# 这一组守的是这一块新接上的三段链路（在这之前它们**根本没接线**）：
#
#   1. `download-release` 认 `wtool.xml` 的 `<muslbin>`（D32）
#      以前它只读 ③ 类的 `scripts/release.json` —— 拿一个 ② 类项目去下，
#      结果是"一句 warning + 完成（0 个项目）"，退出码还是 0（**假成功**）。
#      · 下载 → `<项目>/__release/`，按清单里的 sha256 校验
#      · sha256 不匹配 → **停下、非 0、不留半成品**（.part 也删掉）
#      · `--dry-run` 一个字节都不下；重跑幂等（已是最新，跳过）
#      · ② 类**不写** `__release/.source`（那个标记是给 ③ 的产物包用的）
#
#   2. `unpack-release` 对 ② 类读 `<muslbin member= dest=>`（D57）
#      以前它要 `scripts/release.json` 的 `artifacts` 对照表，而 ② 类按设计
#      **就不该有**那份文件（D50：② 类不产产物包）；而且 lib/wtool_zip.py 的
#      extract-tree 只认 zip，29 个资产里 23 个是 .tar.gz。
#      · .tar.gz / .zip / 裸文件（jq/yq/shfmt/b3sum 那种）三种都能取
#      · 落点是 `<项目>/__output/<dest>`，权限 0755
#      · `member` 写错 → 报错并列出归档里**有哪些**成员
#      · `member` 缺省 = `dest` 的 basename；裸文件资产**不许**写 member=
#
#   3. `<generate>` 执行（D41 / D33）
#      · `cmd` / `script` 两条路都跑，产物落 `__output/`、内容 = 命令的 stdout
#      · 产物**进 journal**、`uninstall` 删掉、重复 install 幂等（覆盖更新）
#      · `cmd` 的 PATH 前面有 `$WTOOL_HOME/usr/bin`（所以 `fzf --zsh` 用的是
#        刚链上的那份二进制）—— 这一条是"第一次装就成功"的关键
#      · 失败 / 产物是空的 → install **当场非 0**，不留半个生成物
#
# 全程在临时工作区 + 临时 $WTOOL_HOME/$WTOOL_STATE 里跑，**不联网**：
# `curl` 用 PATH 前置的桩（把 URL 的 basename 映射到本地 fixture），
# 资产是这一组自己现打的 .tar.gz / .zip。
set -eu

# 先把外面可能残留的 WTOOL_* 清掉（跑测试的人可能刚在真工作区里跑过 wtool）
for _v in $(env | grep -o '^WTOOL_[A-Za-z_]*' || true); do unset "$_v"; done

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
WT="$boot/wtool.sh"
PY="$boot/lib/wtool_plan.py"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
         [ $# -gt 1 ] && printf '      %s\n' "$2"; return 0; }
chk()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }
hasnt(){ [ ! -e "$2" ] && ok "$1" || bad "$1" "（$2 不该存在）"; }
has()  { [ -e "$2" ] && ok "$1" || bad "$1" "（$2 该存在）"; }
sha()  { sha256sum -- "$1" | cut -d' ' -f1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-muslbin.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

_nws=0
newhome() {
    # 每组给一个**独立的假工作区**：全局 `wtool check` 会扫工作区里所有项目，
    # 而前面几组故意造了坏清单（member 写错 / 不支持的压缩）当反例 ——
    # 那些反例留在同一个工作区里，后面那组的"卸完 check 干净"就必然红。
    _nws=$((_nws + 1))
    H=$(mktemp -d "$T/home.XXXXXX")
    printf '# 用户自己的 zshrc\nsetopt auto_cd\n' > "$H/.zshrc"
    export WTOOL_HOME="$H/.wtool" WTOOL_STATE="$H/.wtool/var"
    export WTOOL_MANAGED_HOME="$H"
    export WTOOL_LOG_ROOT="$T/logs"
    export WTOOL_ROOT="$T/ws$_nws"
    mkdir -p "$WTOOL_ROOT"
}
mkproj() {   # <相对路径>：建项目目录 + git 仓库（install 要求干净仓库）
    d="$WTOOL_ROOT/$1"; mkdir -p "$d"
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

# ---------------------------------------------------------------------------
# curl 桩：URL 的 basename → $CURL_FIX/<basename>
#   引擎的调用形状是固定的（见 wt_dl_one / wt_dl_one_api）：
#     curl -fL --retry 3 --retry-delay 2 -C - --connect-timeout 15 \
#          --speed-limit 4096 --speed-time 60 -o <out> <url>
#   找不到那个 fixture 就退 22（= curl 的 HTTP 错误码），让引擎走它自己的
#   "两条路都失败"分支 —— 这也正是"包不在发布页上"的样子。
# ---------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/fix"
cat > "$T/bin/curl" <<'CEOF'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -H|--retry|--retry-delay|--connect-timeout|--speed-limit|--speed-time|--max-time)
            shift 2 ;;
        -*) shift ;;
        *)  url=$1; shift ;;
    esac
done
name=${url##*/}
src="${CURL_FIX:-/nonexistent}/$name"
[ -f "$src" ] || { echo "curl(stub): 404 $url" >&2; exit 22; }
cp -f -- "$src" "$out"
exit 0
CEOF
chmod +x "$T/bin/curl"
export CURL_FIX="$T/fix"
PATH="$T/bin:$PATH"; export PATH

# 现打一个 tar.gz：成员名就是 <包内路径>
mk_targz() {   # <输出文件> <包内路径> <内容>
    _o=$1; _in=$2; _c=$3
    _d=$(mktemp -d "$T/stage.XXXXXX")
    mkdir -p "$_d/$(dirname -- "$_in")"
    printf '%s' "$_c" > "$_d/$_in"
    chmod 755 "$_d/$_in"
    ( cd "$_d" && tar czf "$_o" "$_in" )
    rm -rf -- "$_d"
}
# 现打一个 tar.xz（watchexec / csvlens 那种形状；第 ⑦.3 块加的格式）
mk_tarxz() {   # <输出文件> <包内路径> <内容>
    _o=$1; _in=$2; _c=$3
    _d=$(mktemp -d "$T/stage.XXXXXX")
    mkdir -p "$_d/$(dirname -- "$_in")"
    printf '%s' "$_c" > "$_d/$_in"
    chmod 755 "$_d/$_in"
    ( cd "$_d" && tar cJf "$_o" "$_in" )
    rm -rf -- "$_d"
}
# 现打一个 zip（权限位自己写：python 的 zipfile 默认不给可执行位）
mk_zip() {     # <输出文件> <包内路径> <内容>
    python3 - "$1" "$2" "$3" <<'PY'
import stat, sys, zipfile
out, name, content = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    zi.external_attr = (0o755 | stat.S_IFREG) << 16
    z.writestr(zi, content)
PY
}

TOOL_SH='#!/bin/sh
[ "$1" = "--version" ] && { echo "tool 1.0"; exit 0; }
echo "tool ran"
'

# ==========================================================================
printf '\n== 1. download-release：读 wtool.xml 的 <muslbin>（② 类）==\n'
# ==========================================================================
newhome
mkdir -p "$T/fix"
mk_targz "$T/fix/tool-1.0-x86_64.tar.gz" "tool-1.0/tool" "$TOOL_SH"
SHA_TOOL=$(sha "$T/fix/tool-1.0-x86_64.tar.gz")

P=$(mkproj "tools/musl-bins/tool")
wxml "$P" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/tool-1.0-x86_64.tar.gz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_TOOL\" member=\"tool-1.0/tool\" dest=\"usr/bin/tool\" arch=\"x86_64\"/>" \
    '<export_bin src="__output/usr/bin/tool"/>'
gitci "$P"

_rc=0
_out=$("$WT" download-release "$P" 2>&1) || _rc=$?
chk "★② 类 download-release 退出码 0（以前是'完成（0 个项目）'的假成功）" "$_rc" "0"
case $_out in
    *"没有 scripts/release.json"*) bad "还在拿 release.json 劝 ② 类项目" "$_out" ;;
    *) ok "不再报'没有 scripts/release.json'" ;;
esac
case $_out in
    *"<muslbin>"*) ok "说清了下载依据是 <muslbin> 声明" ;;
    *) bad "没说下载依据" "$_out" ;;
esac
has "资产落在 __release/ 下" "$P/__release/tool-1.0-x86_64.tar.gz"
chk "落地的字节和 fixture 一致" "$SHA_TOOL" "$(sha "$P/__release/tool-1.0-x86_64.tar.gz" 2>/dev/null)"
hasnt "② 类不写 __release/.source（那是 ③ 产物包的来源标记）" "$P/__release/.source"
hasnt "没有留下 .part 半成品" "$P/__release/tool-1.0-x86_64.tar.gz.part"
chk "记账：actions.tsv 里有 download" \
    "$(awk -F'\t' '$1=="download"{print $1}' "$WTOOL_STATE/tools/musl-bins/tool/actions.tsv" 2>/dev/null | head -1)" \
    "download"

# 幂等：再下一次，应该跳过（不重下）
_rc=0
_out=$("$WT" download-release "$P" 2>&1) || _rc=$?
chk "第二次 download-release 也成功（幂等）" "$_rc" "0"
case $_out in
    *"已是最新，跳过"*) ok "已经下好的文件被跳过（没重下）" ;;
    *) bad "第二次没有跳过" "$_out" ;;
esac

# ---- --dry-run：一个字节都不下 ----
D=$(mkproj "tools/musl-bins/dry")
wxml "$D" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/tool-1.0-x86_64.tar.gz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_TOOL\" member=\"tool-1.0/tool\" dest=\"usr/bin/tool\" arch=\"x86_64\"/>"
gitci "$D"
_rc=0
_out=$("$WT" download-release "$D" --dry-run 2>&1) || _rc=$?
chk "--dry-run 退出码 0" "$_rc" "0"
case $_out in
    *"[dry-run] tool-1.0-x86_64.tar.gz"*) ok "dry-run 打印了会下什么（含 URL）" ;;
    *) bad "dry-run 没打印计划" "$_out" ;;
esac
hasnt "★--dry-run 一个字节都没下（没有 __release/）" "$D/__release"

# ---- sha256 不匹配：停下、非 0、不留半成品 ----
B=$(mkproj "tools/musl-bins/bad")
wxml "$B" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/tool-1.0-x86_64.tar.gz"' \
    '         tag="v1.0" sha256="0000000000000000000000000000000000000000000000000000000000000000" member="tool-1.0/tool" dest="usr/bin/tool" arch="x86_64"/>' \
    '<export_bin src="__output/usr/bin/tool"/>'
gitci "$B"
_rc=0
_out=$("$WT" download-release "$B" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★sha256 不匹配 → 非 0" || bad "sha256 不匹配居然成功了" "$_out"
case $_out in
    *"sha256 校验失败"*) ok "★报的是 sha256 校验失败" ;;
    *) bad "没说 sha256 校验失败" "$_out" ;;
esac
case $_out in
    *"$SHA_TOOL"*"0000000000000000000000000000000000000000000000000000000000000000"*|\
    *"0000000000000000000000000000000000000000000000000000000000000000"*"$SHA_TOOL"*)
        ok "★期望/实际两个 sha256 都打了出来（人能自己判断）" ;;
    *) bad "没把期望/实际都打出来" "$_out" ;;
esac
hasnt "★坏文件没被留在 __release/" "$B/__release/tool-1.0-x86_64.tar.gz"
hasnt "坏文件的 .part 也删了" "$B/__release/tool-1.0-x86_64.tar.gz.part"

# ---- 上游根本没有这个资产：非 0 且说清两条路都失败 ----
M=$(mkproj "tools/musl-bins/missing")
wxml "$M" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/nope-1.0.tar.gz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_TOOL\" member=\"nope\" dest=\"usr/bin/nope\" arch=\"x86_64\"/>"
gitci "$M"
_rc=0
_out=$("$WT" download-release "$M" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★资产不在 → 非 0（② 类不静默跳过）" || bad "资产不在却成功了" "$_out"
case $_out in
    *"直链和 api.github.com 两条路都失败"*) ok "说清两条路都试过了" ;;
    *) bad "没说两条路都失败" "$_out" ;;
esac

# ---- 裸文件资产（没有归档的那种）----
printf '#!/bin/sh\necho raw 1.0\n' > "$T/fix/rawbin-1.0"
SHA_RAW=$(sha "$T/fix/rawbin-1.0")
RAW=$(mkproj "tools/musl-bins/raw")
wxml "$RAW" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/rawbin-1.0"' \
    "         tag=\"v1.0\" sha256=\"$SHA_RAW\" dest=\"usr/bin/rawbin\" arch=\"x86_64\"/>"
gitci "$RAW"
_rc=0
"$WT" download-release "$RAW" >/dev/null 2>&1 || _rc=$?
chk "裸文件资产（没有 member=）也能下" "$_rc" "0"
has "裸文件落到 __release/" "$RAW/__release/rawbin-1.0"

# ---- 裸文件资产写了 member= → 解析期就报错（不许猜）----
_rc=0
_out=$("$WT" validate "$RAW" 2>&1) || _rc=$?
chk "裸文件资产不带 member= 时 validate 通过" "$_rc" "0"
RB=$(mkproj "tools/musl-bins/rawwrong")
wxml "$RB" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/rawbin-1.0"' \
    "         tag=\"v1.0\" sha256=\"$SHA_RAW\" member=\"rawbin\" dest=\"usr/bin/rawbin\" arch=\"x86_64\"/>"
gitci "$RB"
_rc=0
_out=$("$WT" validate "$RB" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★裸文件资产写 member= → 非 0" || bad "写错了 member 居然过了" "$_out"
case $_out in
    *"不是归档"*) ok "说清了'这个资产不是归档'" ;;
    *) bad "没说清原因" "$_out" ;;
esac

# ---- 不认识的压缩格式：报错，不静默当裸文件 ----
# （`.tar.xz` 在第 ⑦.3 块转了正，这里换成仍然不支持的 `.tar.zst`）
ZS=$(mkproj "tools/musl-bins/zstd")
wxml "$ZS" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/tool-1.0.tar.zst"' \
    "         tag=\"v1.0\" sha256=\"$SHA_TOOL\" member=\"tool\" dest=\"usr/bin/tool\" arch=\"x86_64\"/>"
gitci "$ZS"
_rc=0
_out=$("$WT" validate "$ZS" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★.tar.zst（不支持的压缩）→ 非 0" || bad ".tar.zst 被放行了" "$_out"
case $_out in
    *"只认"*) ok "报错里列了支持的格式" ;;
    *) bad "没说支持哪些格式" "$_out" ;;
esac

# ---- kind=muslbin 但一条 <muslbin> 都没有 ----
N=$(mkproj "tools/musl-bins/none")
wxml "$N" muslbin '<export_bin src="__output/usr/bin/x"/>'
gitci "$N"
_rc=0
_out=$("$WT" download-release "$N" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "② 类没有 <muslbin> → 非 0" || bad "没声明的 ② 类居然成功了" "$_out"
case $_out in
    *"<muslbin>"*) ok "指路了：要在 wtool.xml 里补 <muslbin>" ;;
    *) bad "没指路" "$_out" ;;
esac

# ---- 裸命令 / all 的展开名单里要有 ② 类 ----
_out=$("$WT" download-release 2>&1)
case $_out in
    *"tools/musl-bins/tool"*) ok "★裸 download-release 的名单里有 ② 类项目" ;;
    *) bad "名单里没有 ② 类（还是只认 release.json）" "$_out" ;;
esac
chk "download-list 认出 ② 类（按 <muslbin>）" \
    "$(python3 "$PY" download-list --root "$WTOOL_ROOT" | grep 'musl-bins/raw$')" "tools/musl-bins/raw"

# ==========================================================================
printf '\n== 2. unpack-release：按 <muslbin member= dest=> 解到 __output/ ==\n'
# ==========================================================================
# .tar.gz：成员带一层目录前缀（bat 那种形状）
_rc=0
_out=$("$WT" unpack-release "$P" 2>&1) || _rc=$?
chk "★.tar.gz 解包退出码 0" "$_rc" "0"
has "★解到 __output/usr/bin/tool（dest 就是落点，D57）" "$P/__output/usr/bin/tool"
chk "内容就是归档里那个成员" "$("$P/__output/usr/bin/tool" --version 2>&1)" "tool 1.0"
case "$(ls -l "$P/__output/usr/bin/tool" | cut -c1-10)" in
    -rwxr-xr-x) ok "★权限 0755（能敲）" ;;
    *) bad "权限不是 0755" "$(ls -l "$P/__output/usr/bin/tool")" ;;
esac
hasnt "没有把整个归档铺进项目（只取那一个成员）" "$P/__output/tool-1.0"

# .zip：成员在根上（procs 那种形状）
mk_zip "$T/fix/procs-1.0.zip" "procs" "$TOOL_SH"
SHA_ZIP=$(sha "$T/fix/procs-1.0.zip")
Z=$(mkproj "tools/musl-bins/zipped")
wxml "$Z" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/procs-1.0.zip"' \
    "         tag=\"v1.0\" sha256=\"$SHA_ZIP\" member=\"procs\" dest=\"usr/bin/procs\" arch=\"x86_64\"/>" \
    '<export_bin src="__output/usr/bin/procs"/>'
gitci "$Z"
"$WT" download-release "$Z" >/dev/null 2>&1 || bad "zip 项目下载"
_rc=0
_out=$("$WT" unpack-release "$Z" 2>&1) || _rc=$?
chk "★.zip 解包退出码 0" "$_rc" "0"
has "★.zip 也解到 __output/usr/bin/procs" "$Z/__output/usr/bin/procs"
chk "zip 里的成员能跑" "$("$Z/__output/usr/bin/procs" --version 2>&1)" "tool 1.0"

# 裸文件：资产本身就是二进制，直接落到 dest
_rc=0
_out=$("$WT" unpack-release "$RAW" 2>&1) || _rc=$?
chk "★裸文件资产解包退出码 0" "$_rc" "0"
has "★裸文件资产落到 __output/usr/bin/rawbin" "$RAW/__output/usr/bin/rawbin"
chk "裸文件资产能跑" "$("$RAW/__output/usr/bin/rawbin" 2>&1)" "raw 1.0"

# .tar.xz：成员带一层目录前缀（watchexec / csvlens 那种形状，第 ⑦.3 块）
mk_tarxz "$T/fix/xztool-1.0-x86_64-unknown-linux-musl.tar.xz" \
         "xztool-1.0-x86_64-unknown-linux-musl/xztool" "$TOOL_SH"
SHA_XZ=$(sha "$T/fix/xztool-1.0-x86_64-unknown-linux-musl.tar.xz")
X=$(mkproj "tools/musl-bins/xztool")
wxml "$X" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/xztool-1.0-x86_64-unknown-linux-musl.tar.xz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_XZ\" member=\"xztool-1.0-x86_64-unknown-linux-musl/xztool\" dest=\"usr/bin/xztool\" arch=\"x86_64\"/>" \
    '<export_bin src="__output/usr/bin/xztool"/>'
gitci "$X"
_rc=0
_out=$("$WT" download-release "$X" 2>&1) || _rc=$?
chk "★.tar.xz 也能下（第 ⑦.3 块）" "$_rc" "0"
_rc=0
_out=$("$WT" unpack-release "$X" 2>&1) || _rc=$?
chk "★.tar.xz 解包退出码 0" "$_rc" "0"
has "★.tar.xz 解到 __output/usr/bin/xztool" "$X/__output/usr/bin/xztool"
chk ".tar.xz 里的成员能跑（解出来是那个二进制本身）" \
    "$("$X/__output/usr/bin/xztool" --version 2>&1)" "tool 1.0"

# member 缺省 = dest 的 basename
mk_targz "$T/fix/plain-1.0.tar.gz" "plain" "$TOOL_SH"
SHA_PLAIN=$(sha "$T/fix/plain-1.0.tar.gz")
PL=$(mkproj "tools/musl-bins/plain")
wxml "$PL" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/plain-1.0.tar.gz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_PLAIN\" dest=\"usr/bin/plain\" arch=\"x86_64\"/>"
gitci "$PL"
"$WT" download-release "$PL" >/dev/null 2>&1 || bad "无 member 的项目下载"
_rc=0
_out=$("$WT" unpack-release "$PL" 2>&1) || _rc=$?
chk "★member 缺省 = dest 的 basename（plain）" "$_rc" "0"
has "解出来了" "$PL/__output/usr/bin/plain"

# member 写错：报错、非 0、把归档里有什么列出来
WR=$(mkproj "tools/musl-bins/wrongmember")
wxml "$WR" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/tool-1.0-x86_64.tar.gz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_TOOL\" member=\"tool-1.0/nope\" dest=\"usr/bin/tool\" arch=\"x86_64\"/>"
gitci "$WR"
"$WT" download-release "$WR" >/dev/null 2>&1 || bad "member 写错的项目下载"
_rc=0
_out=$("$WT" unpack-release "$WR" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★member 写错 → 非 0" || bad "member 写错居然解开了" "$_out"
case $_out in
    *"找不到成员"*) ok "★说清是'找不到成员'" ;;
    *) bad "没说清" "$_out" ;;
esac
case $_out in
    *"tool-1.0/tool"*) ok "★列出了归档里有哪些成员（人能直接照抄）" ;;
    *) bad "没列出归档成员" "$_out" ;;
esac
hasnt "解不出来时不留半个目录" "$WR/__output/usr/bin/tool"

# 还没下载就解包：说清"先 download-release"
ND=$(mkproj "tools/musl-bins/nodl")
wxml "$ND" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/tool-1.0-x86_64.tar.gz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_TOOL\" member=\"tool-1.0/tool\" dest=\"usr/bin/tool\" arch=\"x86_64\"/>"
gitci "$ND"
_rc=0
_out=$("$WT" unpack-release "$ND" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "没下载就解包 → 非 0" || bad "没下载居然解开了" "$_out"
case $_out in
    *"download-release"*) ok "指路了：先 wtool download-release" ;;
    *) bad "没指路" "$_out" ;;
esac

# __release/ 里的东西被换过（和清单里的 sha256 不一致）→ 解包这一步也要拦住
printf 'tampered\n' > "$P/__release/tool-1.0-x86_64.tar.gz"
rm -rf "$P/__output"
_rc=0
_out=$("$WT" unpack-release "$P" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★__release/ 里的资产和清单 sha256 对不上 → 非 0" || bad "被换过的资产照样解开了" "$_out"
case $_out in
    *"整体校验失败"*) ok "报的是校验失败" ;;
    *) bad "没说校验失败" "$_out" ;;
esac
hasnt "校验失败时不留解出来的文件" "$P/__output/usr/bin/tool"

# 恢复：重新下一次（下载那步会认出 sha 不对并重下）
"$WT" download-release "$P" >/dev/null 2>&1 || bad "恢复下载"
_rc=0
"$WT" unpack-release "$P" --dry-run >/dev/null 2>&1 || _rc=$?
chk "dry-run 解包退出码 0" "$_rc" "0"
rm -rf "$P/__output"
_rc=0
_out=$("$WT" unpack-release "$P" --dry-run 2>&1) || _rc=$?
chk "★dry-run 解包也成功" "$_rc" "0"
case $_out in
    *"[dry-run]"*"usr/bin/tool"*) ok "dry-run 打印了会解到哪" ;;
    *) bad "dry-run 没打印落点" "$_out" ;;
esac
hasnt "★--dry-run 一个字节都没写 __output/" "$P/__output"
"$WT" unpack-release "$P" >/dev/null 2>&1 || bad "正式解包"

# ==========================================================================
printf '\n== 3. <generate>：install 时生成、记账、卸载删掉（D41/D33）==\n'
# ==========================================================================
newhome
mkdir -p "$T/fix"
G=$(mkproj "tools/demo-gen")
mkdir -p "$G/__output/usr/bin" "$G/scripts"
printf '%s' "$TOOL_SH" > "$G/__output/usr/bin/gizmo"
chmod 755 "$G/__output/usr/bin/gizmo"
printf '#!/bin/sh\necho "export GEN_SCRIPT=1"\n' > "$G/scripts/gen.bash"
printf 'export DEMO=1\n' > "$G/env.zsh"
wxml "$G" muslbin \
    '<zshrc src="env.zsh"/>' \
    '<export_bin src="__output/usr/bin/gizmo"/>' \
    '<generate dest="__output/gizmo.zsh" cmd="gizmo --zsh"/>' \
    '<generate dest="__output/gen.bash" script="scripts/gen.bash"/>' \
    '<generate dest="__output/version.txt" cmd="gizmo --version"/>'
gitci "$G"

_rc=0
_out=$("$WT" install "$G" 2>&1) || _rc=$?
chk "装上（含三条 <generate>）" "$_rc" "0"
has "cmd 的产物在 __output/ 下" "$G/__output/gizmo.zsh"
chk "★cmd 的 PATH 里有 \$WTOOL_HOME/usr/bin（gizmo --zsh 走通了）" \
    "$(cat "$G/__output/gizmo.zsh" 2>/dev/null)" "tool ran"
chk "script 的产物也在 __output/ 下" \
    "$(cat "$G/__output/gen.bash" 2>/dev/null)" "export GEN_SCRIPT=1"
chk "★cmd 用的是刚链上的那份二进制（版本号一致）" \
    "$(cat "$G/__output/version.txt" 2>/dev/null)" "tool 1.0"
has "L2 链建出来了" "$WTOOL_HOME/usr/bin/gizmo"

JS="$WTOOL_STATE/tools/demo-gen/journal.tsv"
chk "★journal 里有 3 条 generate 账" "$(grep -c '^generate' "$JS" 2>/dev/null || echo 0)" "3"
chk "账里记着产物路径" \
    "$(awk -F'\t' '$1=="generate" && $3=="'"$G"'/__output/gizmo.zsh"{n++} END{print n+0}' "$JS")" "1"
chk "账里记着产物的 sha256（不是空的）" \
    "$(awk -F'\t' '$1=="generate" && $3=="'"$G"'/__output/gizmo.zsh" && length($5)==64 {n++} END{print n+0}' "$JS")" "1"

# 幂等：重复 install 覆盖更新、账不堆
_rc=0
_out=$("$WT" install "$G" 2>&1) || _rc=$?
chk "重复 install 也成功（幂等）" "$_rc" "0"
chk "重复 install 之后账还是 3 条（按 (action,dest) 去重）" \
    "$(grep -c '^generate' "$JS" 2>/dev/null || echo 0)" "3"
chk "重复 install 之后产物内容一样" "$(cat "$G/__output/gen.bash")" "export GEN_SCRIPT=1"

# check：生成物被删掉要报出来（不许假绿）
rm -f "$G/__output/gen.bash"
_rc=0
_out=$("$WT" check "$G" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★生成物被删 → check 非 0（不许假绿）" || bad "check 没报出来" "$_out"
case $_out in
    *"不见了"*"generate"*) ok "check 指到了 <generate> 的产物" ;;
    *) bad "check 没说清是生成物" "$_out" ;;
esac
_rc=0
"$WT" install "$G" >/dev/null 2>&1 || _rc=$?
chk "再 install 一次把它补回来" "$_rc" "0"
has "补回来了" "$G/__output/gen.bash"

# uninstall：生成物删干净
_rc=0
_out=$("$WT" uninstall "$G" 2>&1) || _rc=$?
chk "uninstall 退出码 0" "$_rc" "0"
hasnt "★uninstall 删掉 cmd 的生成物" "$G/__output/gizmo.zsh"
hasnt "★uninstall 删掉 script 的生成物" "$G/__output/gen.bash"
hasnt "★uninstall 删掉第三个生成物" "$G/__output/version.txt"
has "二进制（下载解出来的那个）**不归 <generate> 管**，还在" "$G/__output/usr/bin/gizmo"
hasnt "L2 链撤掉了" "$WTOOL_HOME/usr/bin/gizmo"
_rc=0
# ⚠️ **不带项目名**：点名 check 一个已经卸干净的项目，按设计要报
#    "还没装过（wtool install <路径>）"—— 那是给人看的提示，不是残渣。
#    这里要验的是"卸完不留残渣"，那正是**全局** check 的活。
_out=$("$WT" check 2>&1) || _rc=$?
[ "$_rc" = 0 ] && ok "uninstall 之后全局 check 干净（没留残渣）" \
    || bad "uninstall 之后全局 check 不干净" "$_out"

# ---- 失败路径：cmd 跑失败 / 产物是空的 ----
newhome
F=$(mkproj "tools/gen-fail")
mkdir -p "$F/__output"
wxml "$F" docker \
    '<generate dest="__output/x.zsh" cmd="exit 3"/>'
gitci "$F"
_rc=0
_out=$("$WT" install "$F" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★<generate cmd> 失败 → install 非 0" || bad "失败的 generate 居然过了" "$_out"
case $_out in
    *"退出码 3"*) ok "报出了命令的退出码" ;;
    *) bad "没报退出码" "$_out" ;;
esac
case $_out in
    *"没有被写出去"*) ok "说清生成物没写出去" ;;
    *) bad "没说清" "$_out" ;;
esac
hasnt "失败时不留半个生成物" "$F/__output/x.zsh"
# 临时文件（`<dest>.wtool-new.<引擎 pid>`）也不许留 —— 用通配找，不猜 pid
chk "失败时不留临时文件" \
    "$(find "$F/__output" -name 'x.zsh.wtool-new.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---- --dry-run：只打印"会生成哪个路径、跑什么"，不跑不写 ----
newhome
DRY=$(mkproj "tools/gen-dry")
mkdir -p "$DRY/__output"
wxml "$DRY" docker \
    '<generate dest="__output/dry.zsh" cmd="echo hi"/>' \
    '<generate dest="__output/dry.bash" script="scripts/x.bash"/>'
mkdir -p "$DRY/scripts"; printf '#!/bin/sh\necho hi\n' > "$DRY/scripts/x.bash"
gitci "$DRY"
_rc=0
_out=$("$WT" install "$DRY" --dry-run 2>&1) || _rc=$?
chk "--dry-run install 退出码 0" "$_rc" "0"
case $_out in
    *"[dry-run] 生成"*"dry.zsh"*) ok "★dry-run 打印了会生成哪个路径" ;;
    *) bad "dry-run 没打印生成计划" "$_out" ;;
esac
hasnt "★--dry-run 没有真跑 <generate>（产物不存在）" "$DRY/__output/dry.zsh"
hasnt "--dry-run 也没跑 script 那条" "$DRY/__output/dry.bash"

# ---- cmd 里的制表符/换行：两种写法、两种结果（都钉一条，这是反直觉的地方）----
# ① **字面**制表符写进 XML 属性 → XML 规范要求属性值规范化，`#x9` 变成**空格**
#    （所以它到不了 TSV，产物内容是 "a b"）
# ② **字符引用** `&#9;` → 规范化**不**碰它，真制表符会一路走到计划表（TSV）里 →
#    必须**解析期报错**（不然列会静默串位，比报错难查得多）
TB=$(mkproj "tools/gen-tab")
wxml "$TB" docker \
    '<generate dest="__output/t.zsh" cmd="echo a	b"/>'
gitci "$TB"
_rc=0
_out=$("$WT" install "$TB" 2>&1) || _rc=$?
chk "① 字面制表符：XML 规范化成空格，install 照常成功" "$_rc" "0"
chk "① 产物是 'a b'（制表符已经变成空格）" "$(cat "$TB/__output/t.zsh" 2>/dev/null)" "a b"

TR=$(mkproj "tools/gen-tabref")
wxml "$TR" docker \
    '<generate dest="__output/t.zsh" cmd="echo a&#9;b"/>'
gitci "$TR"
_rc=0
_out=$("$WT" validate "$TR" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "② 字符引用 &#9; 的制表符 → 非 0" || bad "带真制表符的 cmd 放行了" "$_out"
case $_out in
    *"制表符"*) ok "说清了是制表符/换行的问题" ;;
    *) bad "没说清" "$_out" ;;
esac

E=$(mkproj "tools/gen-empty")
mkdir -p "$E/__output"
wxml "$E" docker '<generate dest="__output/empty.zsh" cmd="true"/>'
gitci "$E"
_rc=0
_out=$("$WT" install "$E" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★产物是空的 → install 非 0" || bad "空产物居然算成功" "$_out"
case $_out in
    *"空的"*) ok "报出了'生成物是空的'" ;;
    *) bad "没说清" "$_out" ;;
esac
hasnt "空产物不会留在磁盘上" "$E/__output/empty.zsh"

# ---- 失败要"说清"：script 不存在（解析期就拦）----
NS=$(mkproj "tools/gen-noscript")
wxml "$NS" docker '<generate dest="__output/x.zsh" script="scripts/nope.bash"/>'
gitci "$NS"
_rc=0
_out=$("$WT" validate "$NS" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "script 不存在 → validate 非 0" || bad "不存在的脚本放行了" "$_out"
case $_out in
    *"脚本不存在"*) ok "说清是脚本不存在" ;;
    *) bad "没说清" "$_out" ;;
esac

# ==========================================================================
printf '\n== 4. 全链：download → unpack → install → 敲那个工具 ==\n'
# ==========================================================================
newhome
mkdir -p "$T/fix"
CH=$(mkproj "tools/musl-bins/chain")
wxml "$CH" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/tool-1.0-x86_64.tar.gz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_TOOL\" member=\"tool-1.0/tool\" dest=\"usr/bin/tool\" arch=\"x86_64\"/>" \
    '<export_bin src="__output/usr/bin/tool"/>' \
    '<generate dest="__output/tool.zsh" cmd="tool --version"/>'
gitci "$CH"
_rc=0
"$WT" download-release "$CH" >/dev/null 2>&1 || _rc=$?
chk "① download-release" "$_rc" "0"
_rc=0
"$WT" unpack-release "$CH" >/dev/null 2>&1 || _rc=$?
chk "② unpack-release" "$_rc" "0"
_rc=0
"$WT" install "$CH" >/dev/null 2>&1 || _rc=$?
chk "③ install" "$_rc" "0"
chk "★④ $WTOOL_HOME/usr/bin/tool --version" \
    "$("$WTOOL_HOME/usr/bin/tool" --version 2>&1)" "tool 1.0"
chk "★<generate> 在安装时用上了那份二进制" "$(cat "$CH/__output/tool.zsh")" "tool 1.0"
_rc=0
"$WT" check "$CH" >/dev/null 2>&1 || _rc=$?
chk "⑤ check 干净" "$_rc" "0"

# `.tar.xz` 走同一段全链（第 ⑦.3 块加的格式：watchexec / csvlens 的资产就是它）
CHX=$(mkproj "tools/musl-bins/chainxz")
wxml "$CHX" muslbin \
    '<muslbin url="https://github.com/fake/demo/releases/download/v1.0/xztool-1.0-x86_64-unknown-linux-musl.tar.xz"' \
    "         tag=\"v1.0\" sha256=\"$SHA_XZ\" member=\"xztool-1.0-x86_64-unknown-linux-musl/xztool\" dest=\"usr/bin/xztool\" arch=\"x86_64\"/>" \
    '<export_bin src="__output/usr/bin/xztool"/>' \
    '<generate dest="__output/xztool.zsh" cmd="xztool --version"/>'
gitci "$CHX"
_rc=0
"$WT" download-release "$CHX" >/dev/null 2>&1 || _rc=$?
chk "① .tar.xz download-release" "$_rc" "0"
_rc=0
"$WT" unpack-release "$CHX" >/dev/null 2>&1 || _rc=$?
chk "② .tar.xz unpack-release" "$_rc" "0"
_rc=0
"$WT" install "$CHX" >/dev/null 2>&1 || _rc=$?
chk "③ .tar.xz install" "$_rc" "0"
chk "★④ .tar.xz 全链：$WTOOL_HOME/usr/bin/xztool --version" \
    "$("$WTOOL_HOME/usr/bin/xztool" --version 2>&1)" "tool 1.0"
chk "★<generate> 用的是刚链上的那份 xz 二进制" \
    "$(cat "$CHX/__output/xztool.zsh")" "tool 1.0"
_rc=0
"$WT" check "$CHX" >/dev/null 2>&1 || _rc=$?
chk "⑤ .tar.xz 项目 check 干净" "$_rc" "0"

# ★ ② 类的 `unpack-release` **不能**被自己的离线包堵死（2026-10-14 修的缺陷）
#   症状：`pack-offline-release` 会给每个项目写一份 `scripts/release.json`（离线包的
#   artifacts 对照表）；② 类因此从"没有 release.json → 走 `<muslbin dest=>`"变成
#   "有 release.json → 走对照表"，而那张表里只有离线族那一个资产（会被 skip）→
#   计划算不出来 → **② 类的升级路（download → unpack → install）整个失效**（实测撞到）。
#   口径：② 类"解到哪"的权威声明是 `wtool.xml` 的 `<muslbin dest=>`（D50），
#   所以这时回退到它。判据：先打一次离线包（它会写 release.json），**再 unpack 一次**
#   必须照样成功，而且产物真的解出来。
_rc=0
"$WT" pack-offline-release "$CHX" >/dev/null 2>&1 || _rc=$?
chk "① 先给 ② 类项目打一个离线自足包（它会写 scripts/release.json）" "$_rc" "0"
[ -f "$CHX/scripts/release.json" ] \
    && ok "① release.json 生成了" || bad "① release.json 没生成"
rm -rf "$CHX/__output"
_rc=0
_out=$("$WT" unpack-release "$CHX" 2>&1) || _rc=$?
chk "★② 有了离线包之后 unpack-release **照样能用**（回退到 <muslbin dest=>）" "$_rc" "0"
[ -x "$CHX/__output/usr/bin/xztool" ] \
    && ok "★② 产物真的解出来了（不是退化成空成功）" \
    || bad "★② 产物没出来" "$_out"

printf '\n----------------------------------------\n'
printf 'muslbin_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
