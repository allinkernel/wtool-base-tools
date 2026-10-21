#!/bin/sh
# installer_test.sh —— ADR-0045 第 5b 块：`install.sh` 六项职责 + manifest 三件套
#
# 这一组守的是"错了会静默出事"的那几条（D42 / DESIGN §1.6 §1.8）：
#
#   ① 两条入口链的形状
#        $WTOOL_HOME/install.sh → wtool/install.sh → <安装器项目>/scripts/install.sh
#      （两条都是**相对**链 —— 两端都在 .wtool 里，整棵搬走也有效）
#      项目名**不写死**：这里用的就是当前这份 wtool-base-tools 的拷贝，改名那一块不用动这里
#   ①b 工作区根入口（install.sh / uninstall.sh）在"没有 repo 客户端"的工作区里补齐
#   ② var/ 账本：installer/{actions.tsv,links.tsv}；**删掉 var/ 之后 check 必须非 0**
#      （D42 的判据就是这一条：不许静默"一切对得上"）
#   ③ 三件套两种形态：
#        满血工作区（.repo/projects 且 .repo/project-objects）
#            → default.xml 是**指向 live 的绝对链**；.sha256/.commitid **现场算**
#        bundle / 无 repo
#            → default.xml 是**包内副本**；.sha256/.commitid **只校验不覆盖**
#              对不上 / 缺件 / commitid 不是 id → **停手非 0**
#        两者都没有（"只有 wtool 一份"，§1.10）→ 只警告，不硬失败
#      ⚠️ 顺带守一条回归：bundle 里 `$WTOOL_HOME/wtool/<项目>` **就是**项目目录
#         （L1 位置上本来就是实体），install 绝不能把它当"占位的真实文件"备份走
#   ④ env.{zsh,bash} 都在，且第一个 env 块是安装器项目自己
#   ⑤ 自检：干净 PATH 的新进程里 source env.<shell> 之后 `wtool` 可用
#   ⑥ rc：非交互**一个字节都不写**、不许挂住；pty 答 y 才写；写了也只有两行（幂等）
#   ⑦ 六步**各自的**失败路径都非 0，且说的就是那一步
#
# ⚠️ 全程临时工作区 + 临时 HOME，`env -i` 起 install.sh（只给 PATH/HOME），
#    绝不在真 $HOME 上跑、一个字节都不碰宿主。
set -eu

# 先把外面可能残留的 WTOOL_* 清掉（跑测试的人可能刚在真工作区里跑过 wtool）
for _v in $(env | grep -o '^WTOOL_[A-Za-z_]*' || true); do unset "$_v"; done

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(cd -- "$here/.." && pwd)

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
        [ $# -gt 1 ] && printf '      %s\n' "$2"; return 0; }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }
has()   { [ -e "$2" ] && ok "$1" || bad "$1" "（$2 不在）"; }
hasnt() { [ ! -e "$2" ] && ok "$1" || bad "$1" "（$2 不该存在）"; }
islink(){ [ -L "$2" ] && ok "$1" || bad "$1" "（$2 不是软链）"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-installer.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

# ‼️ 夹具专用的 PATH：只留"跑引擎真正需要的那几个目录"（python3 / git + 系统目录）。
#    为什么不直接用跑测试那个 shell 的 $PATH —— 两条都实测撞过：
#      ① 那里面可能有**另一份真 wtool**（`~/.wtool/…/bin`）：照搬过去等着看
#         "wtool 可用"就成了假绿（⑤ 的失败路径删掉夹具里的 bin/wtool 照样过）；
#      ② 那里面可能有带空格/括号的 Windows 路径（`/mnt/c/Program Files (x86)/…`），
#         塞进 `script -c` 的命令串里会被 shell 拆坏（报 `no matches found`）。
FIX_PATH="$(dirname -- "$(command -v python3)"):$(dirname -- "$(command -v git)"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ── 夹具 ────────────────────────────────────────────────────────────────
# 安装器项目 = **当前这份 wtool-base-tools 的拷贝**（只拷引擎真正要用的那些）。
# 用拷贝而不是原地跑：install.sh 会往工作区根补入口链，别动真工作区。
mkproj() {   # <项目目录>
    _p=$1; mkdir -p "$_p"
    for _mpf in wtool.sh wtool.xml env.zsh env.bash; do cp -- "$boot/$_mpf" "$_p/$_mpf"; done
    for _mpd in lib bin scripts completion; do cp -a -- "$boot/$_mpd" "$_p/$_mpd"; done
    rm -rf -- "$_p/lib/__pycache__"
    chmod +x -- "$_p/wtool.sh" "$_p/bin/wtool" \
        "$_p/scripts/install.sh" "$_p/scripts/uninstall.sh"
}

# 一份"live 清单"（内容不重要，重要的是它是**真 git 仓**里的一份文件：
# 满血那条路要拿 `git rev-parse HEAD` 当 .commitid）
cat > "$T/live-default.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="github" fetch=".."/>
  <default revision="main" remote="github"/>
  <project path="wtool-base-tools" name="allinkernel/wtool-base-tools"/>
</manifest>
XML
mkdir -p "$T/mrepo"
cp -- "$T/live-default.xml" "$T/mrepo/default.xml"
git -C "$T/mrepo" init -q
git -C "$T/mrepo" add -A
git -C "$T/mrepo" -c user.name=t -c user.email=t@t commit -qm manifest
LIVE_CID=$(git -C "$T/mrepo" rev-parse HEAD)

mklive() {   # <ws 目录>：满血工作区的 .repo 部分（判据 = projects + project-objects，D17）
    _ws=$1
    mkdir -p "$_ws/.repo/projects" "$_ws/.repo/project-objects" "$_ws/.repo/manifests"
    cp -- "$T/live-default.xml" "$_ws/.repo/manifests/default.xml"
    # 满血工作区的 `.repo/manifests` **是个真 git 仓**（repo 客户端建的）——
    # ③ 的 `.commitid` 就是 `git -C … rev-parse HEAD`，夹具也得是真的，
    # 不然会先在 ③ 挂掉、后面几步根本没机会跑（第一版就踩了）。
    git -C "$_ws/.repo/manifests" init -q
    git -C "$_ws/.repo/manifests" add -A
    git -C "$_ws/.repo/manifests" -c user.name=t -c user.email=t@t commit -qm manifest
}

mkfix() {   # <名字> <full|bundle|lone> → 打印夹具目录
    _n=$1; _mode=$2
    _d=$T/$_n; rm -rf -- "$_d"; mkdir -p "$_d/home"
    printf '# 用户自己的 zshrc\nsetopt auto_cd\n' > "$_d/home/.zshrc"
    printf '# 用户自己的 bashrc\n' > "$_d/home/.bashrc"
    case $_mode in
        full)
            mkdir -p "$_d/ws"
            mkproj "$_d/ws/wtool-base-tools"
            mklive "$_d/ws" ;;
        bundle)
            # bundle / 目标机：没有工作区，`$WTOOL_HOME/wtool/` **就是**工作区根；
            # 三件套随包而来（default.xml 是**副本**，不是链）。
            mkdir -p "$_d/home/.wtool/wtool/.repo/manifests"
            mkproj "$_d/home/.wtool/wtool/wtool-base-tools"
            cp -- "$T/live-default.xml" "$_d/home/.wtool/wtool/.repo/manifests/default.xml"
            ( cd "$_d/home/.wtool/wtool/.repo/manifests" \
                && sha256sum default.xml > default.xml.sha256 )
            printf '%s\n' "$LIVE_CID" \
                > "$_d/home/.wtool/wtool/.repo/manifests/default.xml.commitid"
            # 种子包形态的入口（现在的 pack 侧就是这么建的：一条相对链指到项目脚本）
            ln -s wtool/wtool-base-tools/scripts/install.sh "$_d/home/.wtool/install.sh" ;;
        lone)
            # "只有 wtool 一份"（§1.10）：没有 .repo 元数据，也没有包内三件套
            mkdir -p "$_d/home/.wtool/wtool"
            mkproj "$_d/home/.wtool/wtool/wtool-base-tools"
            ln -s wtool/wtool-base-tools/scripts/install.sh "$_d/home/.wtool/install.sh" ;;
    esac
    printf '%s' "$_d"
}

# 跑一次 install.sh：**只给 PATH/HOME**（不把跑测试那个人的 WTOOL_* 带进去），
# stdin 一律 /dev/null（非交互），输出落 <夹具>/log。打印退出码。
runfix() {   # <夹具> <入口> [参数…]
    _d=$1; _entry=$2; shift 2
    _rc=0
    env -i PATH="$FIX_PATH" HOME="$_d/home" sh "$_entry" "$@" \
        > "$_d/log" 2>&1 < /dev/null || _rc=$?
    printf '%s' "$_rc"
}

newfix() {   # <名字> <模式> → 建夹具、跑一遍，把目录与退出码留给调用方
    F=$(mkfix "$1" "$2")
    if [ "$2" = full ]; then
        ENTRY=$F/ws/wtool-base-tools/scripts/install.sh
    else
        ENTRY=$F/home/.wtool/install.sh
    fi
    RC=$(runfix "$F" "$ENTRY" ${3:-})
    B=$F/home/.wtool
    M=$B/wtool/.repo/manifests
}

echo "== 1. 满血工作区：三件套 = 指向 live 的绝对链 + 现场算 =="
newfix full full
chk "install.sh 退出码 0" "$RC" "0"
islink "default.xml 是软链（不是副本）" "$M/default.xml"
chk "default.xml 指向 live 的绝对路径" "$(readlink -- "$M/default.xml")" "$F/ws/.repo/manifests/default.xml"
chk "★sha256sum default.xml 与 default.xml.sha256 **逐字相同**" \
    "$(cat -- "$M/default.xml.sha256")" "$(cd -- "$M" && sha256sum default.xml)"
chk "sha256sum -c 认它" "$(cd -- "$M" && sha256sum -c default.xml.sha256 2>&1)" "default.xml: OK"
chk "★.commitid 对得上 live 清单仓的 HEAD" "$(cat -- "$M/default.xml.commitid")" \
    "$(git -C "$F/ws/.repo/manifests" rev-parse HEAD)"

echo
echo "== 2. 两条入口链 + 工作区根入口（职责①/①b）=="
chk "★\$WTOOL_HOME/install.sh 解析到安装器项目里那个真脚本" \
    "$(readlink -f -- "$B/install.sh")" "$F/ws/wtool-base-tools/scripts/install.sh"
chk "第一跳是**相对**链（wtool/install.sh）" "$(readlink -- "$B/install.sh")" "wtool/install.sh"
chk "★第二跳也相对（<项目>/scripts/install.sh）" "$(readlink -- "$B/wtool/install.sh")" \
    "wtool-base-tools/scripts/install.sh"
chk "① 的判据：L1 位置上那个 install.sh 可执行" \
    "$([ -x "$B/wtool/wtool-base-tools/scripts/install.sh" ] && echo yes || echo no)" "yes"
chk "①b：工作区根 install.sh 补上了" "$(readlink -- "$F/ws/install.sh")" "wtool-base-tools/scripts/install.sh"
chk "①b：工作区根 uninstall.sh 补上了" "$(readlink -- "$F/ws/uninstall.sh")" "wtool-base-tools/scripts/uninstall.sh"

echo
echo "== 3. var/ 账本（职责②）=="
has "账本目录在" "$B/var"
has "引擎的 registry.tsv 在" "$B/var/registry.tsv"
has "installer/actions.tsv（这次动作的时间线）" "$B/var/installer/actions.tsv"
has "installer/links.tsv（两条入口链的账）" "$B/var/installer/links.tsv"
chk "links.tsv 正好两条（截断重写，幂等）" "$(wc -l < "$B/var/installer/links.tsv" | tr -d ' ')" "2"
chk "links.tsv 第一行 = \$WTOOL_HOME/install.sh → wtool/install.sh" \
    "$(cut -f1,2 -- "$B/var/installer/links.tsv" | head -1)" "install.sh	wtool/install.sh"
chk "actions.tsv 记了这次动作（项目名现算）" \
    "$(cut -f2 -- "$B/var/installer/actions.tsv" | head -1)" "install.sh"

echo
echo "== 4. env 汇总（职责④）=="
has "env.zsh 在" "$B/env.zsh"
has "env.bash 在（两个 shell 都要有）" "$B/env.bash"
chk "第一个 env 块就是安装器项目自己" \
    "$(awk '/^# --- wtool:/{sub(/^# --- wtool:/,""); sub(/ \(priority.*/,""); print; exit}' "$B/env.zsh")" \
    "wtool-base-tools"

echo
echo "== 5. 自检（职责⑤）：**新进程 + 干净 PATH** 里 wtool 可用 =="
for _sh in zsh bash; do
    command -v "$_sh" >/dev/null 2>&1 || { ok "$_sh：这台机器上没有，跳过"; continue; }
    _got=$(env -i HOME="$F/home" PATH="$FIX_PATH" "$_sh" -c \
        'WTOOL_HOME=$1; export WTOOL_HOME; . "$WTOOL_HOME/env.'"$_sh"'" >/dev/null 2>&1; printf "%s|%s" "$?" "$(command -v wtool)"' \
        _ "$B" 2>/dev/null || true)
    chk "★$_sh：source env.$_sh **返回 0** 且 wtool 可解析（新进程 + 干净 PATH）" \
        "$_got" "0|$B/wtool/wtool-base-tools/bin/wtool"
done
# ‼️ "source 返回 0"单独守一条：这条链的**末尾状态**会一路传回去 ——
#    实测（容器验收）：`completion/wtool.zsh` 末行写成 `(( … )) && compdef …`，
#    compdef 拿不到时短路成 1 → `source env.zsh` 返回 1 → install.sh 的 ⑤ 自检失败，
#    用户看到的是"装完了但自检不过"。修法是把末行改成 `if …; then …; fi`。
for _sh in zsh bash; do
    command -v "$_sh" >/dev/null 2>&1 || continue
    _src=0
    env -i HOME="$F/home" PATH="$FIX_PATH" "$_sh" -c \
        'WTOOL_HOME=$1; export WTOOL_HOME; . "$WTOOL_HOME/env.'"$_sh"'" >/dev/null 2>&1' \
        _ "$B" 2>/dev/null || _src=$?
    chk "$_sh：source env.$_sh 的退出码（末尾状态必须是 0）" "$_src" "0"
done

echo
echo "== 6. rc：非交互**一个字节都不写**，也不挂住（职责⑥）=="
chk "rc 原文没被动过（zshrc）" "$(cat -- "$F/home/.zshrc")" "# 用户自己的 zshrc
setopt auto_cd"
_start=$(date +%s)
RC2=0
env -i PATH="$FIX_PATH" HOME="$F/home" timeout 30 sh "$ENTRY" > "$F/log2" 2>&1 < /dev/null || RC2=$?
_end=$(date +%s)
chk "再跑一次（< /dev/null + timeout）退出码 0（124 = 挂了）" "$RC2" "0"
[ "$((_end - _start))" -le 25 ] && ok "没有挂住（$((_end - _start))s）" \
    || bad "跑得太久，像是挂住了（$((_end - _start))s）"
grep -q '没有终端可以问（非交互）' "$F/log2" && ok "说清了"非交互、只打印"" \
    || bad "没说清非交互那条路" "$(tail -5 "$F/log2")"
chk "第二个 rc 文件（bashrc）也没被动" "$(cat -- "$F/home/.bashrc")" "# 用户自己的 bashrc"
chk "两行只在提示里出现（没落进 rc）" "$(grep -c 'WTOOL_HOME' "$F/home/.zshrc" || true)" "0"

echo
echo "== 7. 幂等：从入口链（\$WTOOL_HOME/install.sh）再跑一遍 =="
_idx=$B/var/installer/links.tsv
# 只比对**内容列**（第 3 列是每次跑的时间戳，会变 —— 那不是"账变了"）
_before=$(cut -f1,2 -- "$_idx")
RC3=$(runfix "$F" "$B/install.sh")
chk "从**入口链**跑（不是工作区路径）也 0" "$RC3" "0"
chk "links.tsv 还是那两行（幂等，截断重写）" "$(cut -f1,2 -- "$_idx")" "$_before"
chk "三件套的 .sha256 没变" "$(cat -- "$M/default.xml.sha256")" \
    "$(cd -- "$M" && sha256sum default.xml)"
chk "rc 还是没被动" "$(grep -c 'WTOOL_HOME' "$F/home/.zshrc" || true)" "0"

echo
echo "== 8. 交互（pty）：答 y 才写那两行 =="
if command -v script >/dev/null 2>&1; then
    printf 'n\n' | script -qec "env -i PATH='$FIX_PATH' HOME=$F/home sh $ENTRY" /dev/null > "$F/pty_n.log" 2>&1 || true
    chk "答 n：rc 还是原文" "$(grep -c 'WTOOL_HOME' "$F/home/.zshrc" || true)" "0"
    printf 'y\n' | script -qec "env -i PATH='$FIX_PATH' HOME=$F/home sh $ENTRY" /dev/null > "$F/pty_y.log" 2>&1 || true
    chk "答 y：rc **最后两行**就是那两行" "$(tail -2 "$F/home/.zshrc" | tr -d '\r' | tr '\n' '|')" \
        "export WTOOL_HOME=~/.wtool|source \${WTOOL_HOME}/env.zsh|"
    chk "答 y：bashrc 写的是 env.bash" "$(tail -1 "$F/home/.bashrc" | tr -d '\r')" \
        "source \${WTOOL_HOME}/env.bash"
    # 幂等：再答一次 y 不该长出新行
    printf 'y\n' | script -qec "env -i PATH='$FIX_PATH' HOME=$F/home sh $ENTRY" /dev/null >/dev/null 2>&1 || true
    chk "★跑两遍也只有两行（WTOOL_HOME 出现 2 次）" "$(grep -c 'WTOOL_HOME' "$F/home/.zshrc")" "2"
    chk "  （那两行确实是最后两行）" "$(tail -2 "$F/home/.zshrc" | tr -d '\r' | tr '\n' '|')" \
        "export WTOOL_HOME=~/.wtool|source \${WTOOL_HOME}/env.zsh|"
else
    ok "没有 script 命令，跳过 pty 那条（其余照测）"
fi
# --write-rc：命令行上明确同意 → 非交互也写
F9=$(mkfix wrc full); ENTRY9=$F9/ws/wtool-base-tools/scripts/install.sh
RC9=$(runfix "$F9" "$ENTRY9" --write-rc)
chk "--write-rc：非交互也写" "$RC9" "0"
chk "--write-rc：最后两行" "$(tail -2 "$F9/home/.zshrc" | tr '\n' '|')" \
    "export WTOOL_HOME=~/.wtool|source \${WTOOL_HOME}/env.zsh|"

echo
echo "== 9. bundle：三件套**只校验不覆盖**，且项目目录一个字节不动 =="
newfix bun bundle
chk "bundle 里 install.sh 退出码 0" "$RC" "0"
chk "default.xml 是**副本**（不是链）" "$([ -L "$M/default.xml" ] && echo link || echo file)" "file"
chk "副本内容就是包里那份（没被改）" "$(cat -- "$M/default.xml")" "$(cat -- "$T/live-default.xml")"
chk "★.sha256 没被覆盖（还是包内那份）" "$(cat -- "$M/default.xml.sha256")" \
    "$(cd -- "$M" && sha256sum default.xml)"
chk ".commitid 没被覆盖" "$(cat -- "$M/default.xml.commitid")" "$LIVE_CID"
has "★回归：bundle 的项目目录还在（L1 位置上就是实体，绝不能被备份走）" \
    "$B/wtool/wtool-base-tools/wtool.sh"
hasnt "  也没有 .wtool-bak.* 残渣" "$(ls -d "$B/wtool"/wtool-base-tools.wtool-bak.* 2>/dev/null | head -1 || echo /nonexistent)"
# ‼️ 2026-10-22 用户原话："我执行 ~/.wtool/install.sh，**它会自动帮我写好
#    .bashrc 和 .zshrc**"。整机包/种子模式 = **不问、直接追加**（非交互也一样）；
#    只追加在末尾、幂等、不覆盖原有内容；**不创建 ~/.zshenv**。
chk "★bundle：非交互也**直接写** ~/.bashrc 那两行（用户口径，不问）" \
    "$(tail -2 "$F/home/.bashrc" | tr '\n' '|')" \
    "export WTOOL_HOME=~/.wtool|source \${WTOOL_HOME}/env.bash|"
chk "★bundle：~/.zshrc 那两行也直接写了" \
    "$(tail -2 "$F/home/.zshrc" | tr '\n' '|')" \
    "export WTOOL_HOME=~/.wtool|source \${WTOOL_HOME}/env.zsh|"
grep -q '^# 用户自己的 bashrc$' "$F/home/.bashrc" \
    && ok "  原有内容没被覆盖（只在末尾追加）" || bad "  原有内容被覆盖了"
hasnt "★bundle：**没有**创建 ~/.zshenv（不污染宿主机）" "$F/home/.zshenv"
chk "入口链在 bundle 里也归一成两跳" "$(readlink -- "$B/install.sh")" "wtool/install.sh"
chk "  （第二跳）" "$(readlink -- "$B/wtool/install.sh")" "wtool-base-tools/scripts/install.sh"

echo
echo "== 10. bundle：对不上 / 缺件 → **停手非 0** =="
cp -- "$M/default.xml.sha256" "$T/sha.bak"
printf '%s  default.xml\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    > "$M/default.xml.sha256"
RCa=$(runfix "$F" "$B/install.sh")
[ "$RCa" != 0 ] && ok "★.sha256 对不上 → 非 0" || bad ".sha256 对不上居然过了"
grep -q '对不上' "$F/log" && ok "说清了是对不上（还给了两边各是什么）" \
    || bad "没说清" "$(tail -4 "$F/log")"
cp -- "$T/sha.bak" "$M/default.xml.sha256"

mv -- "$M/default.xml.commitid" "$T/cid.bak"
RCb=$(runfix "$F" "$B/install.sh")
[ "$RCb" != 0 ] && ok "缺 .commitid → 非 0" || bad "缺 .commitid 居然过了"
mv -- "$T/cid.bak" "$M/default.xml.commitid"

printf '不是-id\n' > "$M/default.xml.commitid"
RCc=$(runfix "$F" "$B/install.sh")
[ "$RCc" != 0 ] && ok "★.commitid 不是 commit id → 非 0" || bad "坏 commitid 居然过了"
printf '%s\n' "$LIVE_CID" > "$M/default.xml.commitid"
RCd=$(runfix "$F" "$B/install.sh")
chk "修回来之后又 0（不是一次坏就永久坏）" "$RCd" "0"

echo
echo "== 11. 只有 wtool 一份（§1.10）：只警告，不硬失败 =="
newfix lone lone
chk "退出码 0（那种机器上本来就没有 manifest）" "$RC" "0"
grep -q '没有 manifest 可用' "$F/log" && ok "明说了三件套建不出来、以及哪条命令会受影响" \
    || bad "没说清" "$(grep -A3 '③' "$F/log" | head -5)"
has "env.zsh 照样建（wtool 自己能用）" "$B/env.zsh"

echo
echo "== 12. 六步各自的失败路径（D42：每一步失败都要非 0）=="
F1=$(mkfix f1 full)          # ① 清单坏 → 引擎拒绝
printf '<wtool schema="1"><export_bin src="src/x"/></wtool>\n' > "$F1/ws/wtool-base-tools/wtool.xml"
r=$(runfix "$F1" "$F1/ws/wtool-base-tools/scripts/install.sh")
[ "$r" != 0 ] && ok "① 引擎装不上 → 非 0" || bad "① 失败了却返回 0"
grep -q '① 失败' "$F1/log" && ok "  说的是第 ① 步" || bad "  没点出是第 ① 步"

F2=$(mkfix f2 full)          # ② var/installer 是个普通文件
mkdir -p "$F2/home/.wtool/var"; : > "$F2/home/.wtool/var/installer"
r=$(runfix "$F2" "$F2/ws/wtool-base-tools/scripts/install.sh")
[ "$r" != 0 ] && ok "② 建不了账本 → 非 0" || bad "② 失败了却返回 0"
grep -q '② 失败' "$F2/log" && ok "  说的是第 ② 步" || bad "  没点出是第 ② 步"

F3=$(mkfix f3 full)          # ③ 满血工作区但 live 清单没了（工作区是坏的）
rm -f "$F3/ws/.repo/manifests/default.xml"
r=$(runfix "$F3" "$F3/ws/wtool-base-tools/scripts/install.sh")
[ "$r" != 0 ] && ok "③ 满血却没有 live 清单 → 非 0" || bad "③ 这种情况居然过了"
grep -q '③ 失败' "$F3/log" && ok "  说的是第 ③ 步" || bad "  没点出是第 ③ 步"

F4=$(mkfix f4 full)          # ④ env 汇总没出来
mkdir -p "$F4/home/.wtool/env.bash"
r=$(runfix "$F4" "$F4/ws/wtool-base-tools/scripts/install.sh")
[ "$r" != 0 ] && ok "④ env.{zsh,bash} 没出来 → 非 0" || bad "④ 失败了却返回 0"
grep -q '④ 失败' "$F4/log" && ok "  说的是第 ④ 步" || bad "  没点出是第 ④ 步"

F5=$(mkfix f5 full)          # ⑤ source 之后找不到 wtool
rm -f "$F5/ws/wtool-base-tools/bin/wtool"
r=$(runfix "$F5" "$F5/ws/wtool-base-tools/scripts/install.sh")
[ "$r" != 0 ] && ok "⑤ 子进程里 wtool 不可用 → 非 0" || bad "⑤ 失败了却返回 0"
grep -q '⑤ 失败' "$F5/log" && ok "  说的是第 ⑤ 步" || bad "  没点出是第 ⑤ 步"
grep -q '找不到 wtool 命令' "$F5/log" && ok "  还指出了是哪一小步（不是笼统的失败）" \
    || bad "  没指出哪一小步"

echo
echo "== 13. D42 的判据：**删掉 var/ 之后 check 必须报错** =="
F6=$(mkfix f6 full); ENTRY6=$F6/ws/wtool-base-tools/scripts/install.sh; B6=$F6/home/.wtool
r=$(runfix "$F6" "$ENTRY6")
chk "先装好，check 干净（0）" \
    "$(env -i PATH="$FIX_PATH" HOME="$F6/home" WTOOL_HOME="$B6" sh "$F6/ws/wtool-base-tools/wtool.sh" check >/dev/null 2>&1; echo $?)" "0"
rm -rf -- "$B6/var"
_out=$(env -i PATH="$FIX_PATH" HOME="$F6/home" WTOOL_HOME="$B6" sh "$F6/ws/wtool-base-tools/wtool.sh" check 2>&1) && r=0 || r=$?
[ "$r" != 0 ] && ok "★删掉 var/ → check 非 0（不再假绿）" || bad "删掉 var/ 还报一切对得上"
case $_out in *"账本目录不见了"*) ok "  指出了是账本不见了，并给了重建办法" ;;
             *) bad "  没说清是账本不见了" "$_out" ;; esac
# 入口链没了也要报（install.sh 记过账才查）
rm -rf -- "$B6/var"   # 上面已经删过了，这里恢复一套：重装一次再删链
r=$(runfix "$F6" "$ENTRY6")
rm -f -- "$B6/wtool/install.sh"
_out=$(env -i PATH="$FIX_PATH" HOME="$F6/home" WTOOL_HOME="$B6" sh "$F6/ws/wtool-base-tools/wtool.sh" check 2>&1) && r=0 || r=$?
[ "$r" != 0 ] && ok "入口链没了 → check 非 0" || bad "入口链没了 check 还说对得上"
case $_out in *"入口链"*) ok "  说的是入口链（职责①）" ;; *) bad "  没说清是哪条链" "$_out" ;; esac

echo
echo "== 14. --dry-run：一个字节都不写 =="
F7=$(mkfix f7 full); ENTRY7=$F7/ws/wtool-base-tools/scripts/install.sh
r=$(runfix "$F7" "$ENTRY7" --dry-run)
chk "--dry-run 退出码 0" "$r" "0"
hasnt "  \$HOME/.wtool 没被建" "$F7/home/.wtool"
chk "  rc 也没动" "$(grep -c 'WTOOL_HOME' "$F7/home/.zshrc" || true)" "0"
grep -q '\[dry-run\]' "$F7/log" && ok "  打了要做什么" || bad "  什么都没说"

echo
echo "== 15. uninstall.sh：收掉 install.sh 建的东西（人手动那条路）=="
F8=$(mkfix f8 full); ENTRY8=$F8/ws/wtool-base-tools/scripts/install.sh; B8=$F8/home/.wtool
r=$(runfix "$F8" "$ENTRY8")
chk "先装好" "$r" "0"
_u=0
env -i PATH="$FIX_PATH" HOME="$F8/home" sh "$F8/ws/wtool-base-tools/scripts/uninstall.sh" \
    > "$F8/un.log" 2>&1 || _u=$?
chk "uninstall.sh 退出码 0" "$_u" "0"
hasnt "两条入口链都收掉了（\$WTOOL_HOME/install.sh）" "$B8/install.sh"
hasnt "两条入口链都收掉了（\$WTOOL_HOME/wtool/install.sh）" "$B8/wtool/install.sh"
hasnt "var/installer 的账也收掉了" "$B8/var/installer"
has "★工作区里那份项目一个字节没动（卸载不删源码）" "$F8/ws/wtool-base-tools/wtool.sh"
hasnt "引擎把 L1 也逆放掉了（那是它的账）" "$B8/wtool/wtool-base-tools"
grep -q '已删除' "$F8/un.log" && ok "说了收掉了什么" || bad "没说收掉了什么" "$(tail -5 "$F8/un.log")"
grep -q 'manifest 三件套' "$F8/un.log" && ok "说清了三件套不收（那不是安装器的账）" \
    || bad "没说清三件套的下场"

echo
echo "installer_test: PASS $pass  FAIL $fail"
[ "$fail" = 0 ] || exit 1
exit 0
