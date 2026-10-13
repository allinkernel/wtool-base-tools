#!/bin/sh
# home_acceptance.sh —— **容器里真装一遍**的验收（ADR-0045 第 5a + 5b 块）
#
# 验的是这几面：
#   · 第 5a 块：`$WTOOL_HOME` 新语义 / rc 两行（默认只打印、旧块替换、非交互不挂）/
#     `$WTOOL_HOME/env.{zsh,bash}` / 账本进 `var/`、日志留本机且编号递增
#   · 第 5b 块（第 14–22 节）：在假 HOME 里**完整跑一遍 `install.sh` 的六项职责**
#     （D42）——两条入口链的真实形状、manifest 三件套（满血=链+现场算 /
#     bundle=只校验不覆盖）、`var/` 账本、env 汇总、新进程自检、
#     rc"非交互只打印 / pty 答 y 才写"、以及"六步各自的失败路径都非 0"。
#
# 怎么跑（**宿主一个字节都不碰**；容器用完即弃）：
#
#   docker run --rm -v /:/h:ro -v ~/self/wtool:/wtool:ro -v <tests 目录>:/wtc:ro \
#     ubuntu:24.04 bash -c 'sh /wtc/home_acceptance.sh'
#
#   ⚠️ 为什么挂 `-v /:/h:ro`：这样**不用 apt**（实测走代理装包会十分钟起步、
#      经常直接超时）。python3 / git / zsh 都用宿主的，容器只当隔离层。
#   ⚠️ 脚本里 `cp -a /wtool/wtool-base-tools` 到 /work：工作区是只读挂载，
#      而且验收要造自己的假工作区与假 HOME。
#   ⚠️ `zsh` 用一层包装脚本（`env -i` 会清掉 LD_LIBRARY_PATH，所以设在包装里）。
#
# 它会打印每一步的真实输出。全程只碰容器里的假 HOME：不碰宿主。
set -eu
# 容器里不装任何东西：宿主工具（python3 / git / zsh）通过 `-v /:/h:ro` 挂进来。
# 这样验收**不依赖网络**，也不会在 apt 上磨掉十分钟（实测：走代理装包会超时）。
export LD_LIBRARY_PATH=/h/lib/x86_64-linux-gnu:/h/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
export PATH=/h/usr/bin:/h/bin:/usr/bin:/bin
export GIT_TEMPLATE_DIR=/h/usr/share/git-core/templates
export GIT_EXEC_PATH=/h/usr/lib/git-core
# zsh 也从宿主挂进来（容器里不装东西）。包一层：`env -i` 会把环境清空，
# 所以 LD_LIBRARY_PATH 必须在**包装脚本自己里面**设。
#
# ‼️ 还要把宿主的 zsh **模块**目录接进来：宿主 zsh 编译时的模块路径是
#    `/usr/lib/x86_64-linux-gnu/zsh/5.9/`，容器里没有这个目录 → `zsh/parameter`
#    这种内置模块加载失败。症状（第 5b 块的 ⑤ 自检里第一次撞到）：
#        completion/wtool.zsh:25: failed to load module `zsh/parameter': …
#        SELFCHECK-FAIL source env.zsh 失败
#    —— 那不是安装器的问题，是"容器里的 zsh 是半残的"（模块不在它认的路径上）。
#    软链一下，等于"这台机器有一份完整的 zsh"。
if [ -d /h/usr/lib/x86_64-linux-gnu/zsh ] && [ ! -e /usr/lib/x86_64-linux-gnu/zsh ]; then
    mkdir -p /usr/lib/x86_64-linux-gnu
    ln -sfn /h/usr/lib/x86_64-linux-gnu/zsh /usr/lib/x86_64-linux-gnu/zsh
fi
if [ ! -x /usr/bin/zsh ] && [ -x /h/bin/zsh ]; then
    cat > /usr/bin/zsh <<'ZSHW'
#!/bin/sh
LD_LIBRARY_PATH=/h/lib/x86_64-linux-gnu:/h/usr/lib/x86_64-linux-gnu exec /h/bin/zsh "$@"
ZSHW
    chmod +x /usr/bin/zsh
fi

echo "=== 0. 环境 ==="
echo "镜像      : $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "python3   : $(python3 --version 2>&1)"
echo "git       : $(git --version 2>&1)"

WORK=/work; HOME_DIR=/root
export HOME="$HOME_DIR"
rm -rf "$WORK"; mkdir -p "$WORK"
# 工作区只读挂着 → 拷一份出来当"满血工作区"
#
# ‼️ **过渡窗口**（2026-10-13）：引擎项目在 GitHub / 清单 / 代码里已经叫
#    `wtool-base-tools`，但**本地目录改名是用户的一次性切换**，还没做 ——
#    所以磁盘上可能还是 `bootstrap/`。两个名字都认，哪个在就用哪个
#    （挂载命令不必跟着改名走；判据：随便哪一边存在都跑得起来）。
_eng_src=/wtool/wtool-base-tools
[ -d "$_eng_src" ] || _eng_src=/wtool/bootstrap
[ -d "$_eng_src" ] || { echo "找不到引擎目录（/wtool/wtool-base-tools 或 /wtool/bootstrap）" >&2; exit 1; }
echo "  引擎目录: $_eng_src"
cp -a "$_eng_src" "$WORK/wtool-base-tools"
rm -rf "$WORK/wtool-base-tools/lib/__pycache__" "$WORK/wtool-base-tools/.git"
BOOT="$WORK/wtool-base-tools"
WS="$WORK/ws"

echo
echo "=== 1. 造一个项目（kind=docker + <zshrc>/<bashrc> + <export_bin>）==="
P="$WS/editor/demo"
mkdir -p "$P/__output/usr/bin" "$P/scripts"
printf 'demo-bin\n' > "$P/__output/usr/bin/demo"
printf 'export DEMO_MARK=1\n' > "$P/env.zsh"
printf 'export DEMO_MARK=1\n' > "$P/env.bash"
cat > "$P/wtool.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="docker" priority="50">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
  <export_bin src="__output/usr/bin/demo"/>
</wtool>
XML
cd "$P" && git init -q && git add -A && git -c user.email=t@e.com -c user.name=t commit -qm init
echo "项目身份 : editor/demo（= 它相对工作区根的路径）"

echo
echo "=== 2. 默认状态：WTOOL_HOME **没有**导出过，rc 里也没有那两行 ==="
printf '# 用户自己的 zshrc\nsetopt auto_cd\n' > "$HOME_DIR/.zshrc"
printf '# 用户自己的 bashrc\n' > "$HOME_DIR/.bashrc"
echo "  \$WTOOL_HOME = '${WTOOL_HOME:-（空）}'"
echo "  rc 里 wtool 的行数 : $(grep -c wtool "$HOME_DIR/.zshrc" || true)"

echo
echo "=== 3. wtool install（引擎**不该**动 rc：默认只打印）==="
WTOOL_ROOT="$WS" "$BOOT/wtool.sh" install editor/demo | sed 's/^/  /'
echo "  rc 里那两行/旧块 : $(grep -c 'WTOOL_HOME\|wtool >>>' "$HOME_DIR/.zshrc" || true)  ← 应该是 0"
echo "  rc 原文（一个字都没被动）："; sed 's/^/    /' "$HOME_DIR/.zshrc"
echo "  install 末尾要打印照抄就行的提示："; grep -A4 "还差一步" /tmp/i.log 2>/dev/null | sed 's/^/    /' || true

echo
echo "=== 4. 装出来的东西 ==="
echo "  \$WTOOL_HOME 树："
find "$HOME_DIR/.wtool" -maxdepth 4 | sed 's/^/    /' | head -20
echo "  env.zsh（$HOME_DIR/.wtool/env.zsh）："
sed 's/^/    | /' "$HOME_DIR/.wtool/env.zsh"
echo "  install.sh 是**照文档手工**加的那两行："
cat >> "$HOME_DIR/.zshrc" <<'RCEOF'
export WTOOL_HOME=~/.wtool
source ${WTOOL_HOME}/env.zsh
RCEOF
cat >> "$HOME_DIR/.bashrc" <<'RCEOF'
export WTOOL_HOME=~/.wtool
source ${WTOOL_HOME}/env.bash
RCEOF
tail -2 "$HOME_DIR/.zshrc" | sed 's/^/    /'

echo
echo "=== 5. 新 shell 里 source env.zsh 之后（zsh + bash 两份）==="
for sh in zsh bash; do
  if command -v "$sh" >/dev/null 2>&1; then
    _out=$(env -i HOME="$HOME_DIR" PATH=/usr/bin:/bin "$sh" -c \
      ". \"\$HOME/.${sh}rc\" >/dev/null 2>&1; printf 'DEMO_MARK=%s WTOOL_HOME=%s WTOOL_PROJECT_DIR=%s' \"\$DEMO_MARK\" \"\$WTOOL_HOME\" \"\$WTOOL_PROJECT_DIR\"")
    echo "  $sh: $_out"
  else
    echo "  $sh: （容器里没装，跳过）"
  fi
done

echo
echo "=== 6. 校验片段：把 WTOOL_HOME 清掉再 source（两个 shell 都要非 0）==="
for sh in zsh bash; do
  if command -v "$sh" >/dev/null 2>&1; then
    _rc=0
    env -i HOME="$HOME_DIR" PATH=/usr/bin:/bin "$sh" -c 'unset WTOOL_HOME; . "$HOME/.wtool/env.'"$sh"'"' >/tmp/chk.$sh 2>&1 || _rc=$?
    echo "  $sh 退出码 = $_rc"
    sed 's/^/      /' /tmp/chk.$sh
  else
    _rc=0
    sh -c 'unset WTOOL_HOME; . "$1"' _ "$HOME_DIR/.wtool/env.bash" >/tmp/chk.sh 2>&1 || _rc=$?
    echo "  sh(dash) 退出码 = $_rc"
    sed 's/^/      /' /tmp/chk.sh
  fi
done

echo
echo "=== 7. rc 两行幂等（再装两次，rc 还是那两行）==="
WTOOL_ROOT="$WS" "$BOOT/wtool.sh" install editor/demo >/dev/null 2>&1
WTOOL_ROOT="$WS" "$BOOT/wtool.sh" install editor/demo >/dev/null 2>&1
echo "  WTOOL_HOME 出现次数 = $(grep -c WTOOL_HOME "$HOME_DIR/.zshrc")  ← 应该是 2"
echo "  rc 最后两行："; tail -2 "$HOME_DIR/.zshrc" | sed 's/^/    /'

echo
echo "=== 8. 旧形态（# >>> wtool >>> 块）→ 被识别并替换成那两行 ==="
cat > "$HOME_DIR/.zshrc" <<'RCEOF'
# 用户自己的 zshrc
setopt auto_cd
# >>> wtool >>>
# wtool 装的东西都从这里生效。
[ -f "$HOME/.wtool/.zshrc" ] && . "$HOME/.wtool/.zshrc"
# <<< wtool <<<
RCEOF
_rc=0; _out=$(WTOOL_ROOT="$WS" "$BOOT/wtool.sh" check editor/demo 2>&1) || _rc=$?
echo "  check 退出码 = $_rc（>0 = 认出来要迁移）"
printf '%s\n' "$_out" | grep -i "旧块" | sed 's/^/    /' || true
WTOOL_ROOT="$WS" "$BOOT/wtool.sh" install editor/demo >/dev/null 2>&1
echo "  替换之后 rc 最后两行："; tail -2 "$HOME_DIR/.zshrc" | sed 's/^/    /'
echo "  还有旧标记块吗 : $(grep -c '# >>> wtool >>>' "$HOME_DIR/.zshrc" || true)  ← 应该是 0"

echo
echo "=== 9. check 的 rc ==="
_rc=0; WTOOL_ROOT="$WS" "$BOOT/wtool.sh" check editor/demo || _rc=$?
echo "  wtool check 的 rc = $_rc"

echo
echo "=== 10. 日志：每次装一个新目录、编号递增、永远读最新那个 ==="
for i in 1 2 3; do WTOOL_ROOT="$WS" "$BOOT/wtool.sh" install editor/demo >/dev/null 2>&1; sleep 1; done
ls -1d "$HOME_DIR"/.local/state/wtool/wtool-logs-* | sed 's/^/    /'
echo "  doctor 认的最新那个："
WTOOL_ROOT="$WS" "$BOOT/wtool.sh" doctor 2>/dev/null | grep "log " | sed 's/^/    /'
echo "  日志里有什么（最新那个）："
find "$(ls -1d "$HOME_DIR"/.local/state/wtool/wtool-logs-* | tail -1)" -type f | sed 's/^/    /' | head -8

echo
echo "=== 11. 删掉**所有**旧日志（只留最新），wtool 照常工作 ==="
_latest=$(ls -1d "$HOME_DIR"/.local/state/wtool/wtool-logs-* | tail -1)
ls -1d "$HOME_DIR"/.local/state/wtool/wtool-logs-* | grep -v "^$_latest$" | while read -r d; do rm -rf "$d"; done
rm -rf "$_latest"          # 连最新那个也删掉
echo "  删完还剩 : $(ls -1d "$HOME_DIR"/.local/state/wtool/wtool-logs-* 2>/dev/null | wc -l) 个"
_rc=0; WTOOL_ROOT="$WS" "$BOOT/wtool.sh" check editor/demo >/tmp/c2.log 2>&1 || _rc=$?
echo "  删日志之后 wtool check 的 rc = $_rc"
sed 's/^/      /' /tmp/c2.log
_rc=0; WTOOL_ROOT="$WS" "$BOOT/wtool.sh" install editor/demo >/dev/null 2>&1 || _rc=$?
echo "  再装一次 rc = $_rc；新日志目录 = $(ls -1d "$HOME_DIR"/.local/state/wtool/wtool-logs-* 2>/dev/null | tail -1)"

echo
echo "=== 12. 账本在 \$WTOOL_HOME/var，且删了它 check 必须报（账本不能删）==="
ls "$HOME_DIR/.wtool/var" | sed 's/^/    /'
rm -rf "$HOME_DIR/.wtool/var"
_rc=0; WTOOL_ROOT="$WS" "$BOOT/wtool.sh" check editor/demo 2>&1 | head -3 | sed 's/^/    /'
echo "  （上面这几行是删了账本之后 check 的态度）"

echo
echo "=== 13. uninstall：rc 里那两行跟着剥掉 ==="
WTOOL_ROOT="$WS" "$BOOT/wtool.sh" install editor/demo >/dev/null 2>&1
WTOOL_ROOT="$WS" "$BOOT/wtool.sh" uninstall editor/demo >/dev/null 2>&1
echo "  rc 内容："; cat "$HOME_DIR/.zshrc" | sed 's/^/    /'
echo "  \$WTOOL_HOME 还在吗 : $([ -e "$HOME_DIR/.wtool" ] && echo 在 || echo 不在)"

# ==========================================================================
# 第 5b 块（ADR-0045 §1.8 / D42）：`install.sh` 六项职责 + manifest 三件套
#
# 上面 13 节都是**引擎**那条路（直接调 wtool.sh）。这一段走**安装器**那条路：
# 在假 HOME 里真跑一遍 `install.sh`，六步各打印一段，然后把三件套、两条入口链、
# 账本、rc 两条路、以及"删掉 var/ 必须报错"都用真实输出摊开。
# ==========================================================================
# 容器里跑被测脚本的**唯一入口**：必须带上 LD_LIBRARY_PATH。
# 容器里的 python3 是宿主挂进来的，`env -i` 一清就 "libexpat.so.1: cannot open
# shared object file"（实测：install.sh 的 ① 直接死在引擎那一层，后面全空）。
# PATH 也显式给，别依赖调用者的环境。
irun() {   # <HOME> <脚本> [参数…]
    _ih=$1; _is=$2; shift 2
    env -i LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" PATH="$PATH" HOME="$_ih" sh "$_is" "$@"
}

IWS=/work/iws; IHOME=/work/ihome
rm -rf "$IWS" "$IHOME"
mkdir -p "$IWS/.repo/projects" "$IWS/.repo/project-objects" "$IWS/.repo/manifests" "$IHOME"
cp -a /work/wtool-base-tools "$IWS/wtool-base-tools"        # = 安装器项目（含 scripts/install.sh）

echo
echo "=== 14. 第 5b 块夹具：满血工作区（D17 判据：这两个目录都在）+ 独立假 HOME ==="
cat > "$IWS/.repo/manifests/default.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="github" fetch=".."/>
  <default revision="main" remote="github"/>
  <project path="wtool-base-tools" name="allinkernel/wtool-base-tools"/>
</manifest>
XML
git -C "$IWS/.repo/manifests" init -q
git -C "$IWS/.repo/manifests" add -A
git -C "$IWS/.repo/manifests" -c user.email=t@e.com -c user.name=t commit -qm manifest
printf '# 用户自己的 zshrc\nsetopt auto_cd\n' > "$IHOME/.zshrc"
printf '# 用户自己的 bashrc\n' > "$IHOME/.bashrc"
echo "  工作区 : $IWS（安装器项目 = $IWS/wtool-base-tools）"
echo "  假 HOME: $IHOME（跟上面 13 节那个 \$HOME_DIR 分开，互不干扰）"
echo "  满血判据: .repo/projects=$([ -d "$IWS/.repo/projects" ] && echo 有)  .repo/project-objects=$([ -d "$IWS/.repo/project-objects" ] && echo 有)"
echo "  live 清单 HEAD = $(git -C "$IWS/.repo/manifests" rev-parse HEAD)"

echo
echo "=== 15. 真跑一遍 install.sh（非交互：stdin 接 /dev/null）==="
echo "  —————————————— install.sh 的输出开始 ——————————————"
_rc=0
irun "$IHOME" "$IWS/wtool-base-tools/scripts/install.sh" < /dev/null || _rc=$?
echo "  —————————————— install.sh 的输出结束 ——————————————"
echo "  ← install.sh 退出码 = $_rc（0 = 六步都过）"

echo
echo "=== 16. 两条入口链的真实形状（①）==="
ls -l "$IHOME/.wtool/install.sh" "$IHOME/.wtool/wtool/install.sh" | sed 's/^/    /'
echo "  readlink -f \$WTOOL_HOME/install.sh = $(readlink -f "$IHOME/.wtool/install.sh")"
echo "  期望（项目里那个真脚本）           = $IWS/wtool-base-tools/scripts/install.sh"
echo "  从那两条链跑一次（应该能跑、且认得出自己）:"
irun "$IHOME" "$IHOME/.wtool/install.sh" --dry-run < /dev/null 2>&1 | grep -E '① 装安装器项目本体' | sed 's/^/    /'

echo
echo "=== 17. manifest 三件套的真实形态（③：满血 = 链 + 现场算）==="
_M="$IHOME/.wtool/wtool/.repo/manifests"
ls -l "$_M" | sed 's/^/    /'
echo "  default.xml.sha256  : $(cat "$_M/default.xml.sha256")"
echo "  sha256sum 现算      : $(cd "$_M" && sha256sum default.xml)"
echo "  sha256sum -c        : $(cd "$_M" && sha256sum -c default.xml.sha256 2>&1)"
echo "  default.xml.commitid: $(cat "$_M/default.xml.commitid")"
echo "  live 清单仓 HEAD    : $(git -C "$IWS/.repo/manifests" rev-parse HEAD)"

echo
echo "=== 18. 账本（②）+ env（④）==="
echo "  \$WTOOL_HOME/var/："; find "$IHOME/.wtool/var" -maxdepth 2 | sed "s|$IHOME/.wtool/var|    var|" | sort
echo "  var/installer/links.tsv（两条入口链的账）:"; sed 's/^/      /' "$IHOME/.wtool/var/installer/links.tsv"
echo "  var/installer/actions.tsv（这次动作）:"; sed 's/^/      /' "$IHOME/.wtool/var/installer/actions.tsv"
echo "  env.zsh 第一个 env 块: $(awk '/^# --- wtool:/{print; exit}' "$IHOME/.wtool/env.zsh")"

echo
echo "=== 19. ⑤ 自检：**新进程 + 干净 PATH** 里 source env 之后 wtool 可用 ==="
for _sh in zsh bash; do
  if command -v "$_sh" >/dev/null 2>&1; then
    _clean=$(printf '%s' "$PATH" | tr ':' '\n' | awk 'length($0) && tolower($0) !~ /wtool/ {printf "%s%s", sep, $0; sep=":"}')
    _out=$(env -i LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" HOME="$IHOME" PATH="$_clean" "$_sh" -c '
        WTOOL_HOME=$1; export WTOOL_HOME
        . "$WTOOL_HOME/env.'"$_sh"'" || exit 3
        printf "wtool=%s\n" "$(command -v wtool)"
        case ":$PATH:" in *":$WTOOL_HOME/usr/bin:"*) echo "usr/bin 在 PATH 里";; *) echo "usr/bin 不在 PATH";; esac
        wtool check >/dev/null 2>&1 && echo "wtool check = 0" || echo "wtool check 非 0"' _ "$IHOME/.wtool" 2>&1 || true)
    echo "  $_sh:"; printf '%s\n' "$_out" | sed 's/^/      /'
  else
    echo "  $_sh：（容器里没有，跳过）"
  fi
done

echo
echo "=== 20. 六步各自的失败路径（都非 0、都说清是哪一步）==="
_fail_try() {   # <名字> <对夹具做的破坏…（由调用方先做）>
    _name=$1
    _rc=0
    irun "$IHOME" "$IWS/wtool-base-tools/scripts/install.sh" < /dev/null >/tmp/ifail.log 2>&1 || _rc=$?
    echo "  $_name → 退出码 $_rc"
    grep -E '[①②③④⑤⑥] 失败' /tmp/ifail.log | head -2 | sed 's/^/      /'
}
mv "$IWS/wtool-base-tools/wtool.xml" "$IWS/wtool-base-tools/wtool.xml.off"
printf '<wtool schema="1"><export_bin src="src/x"/></wtool>\n' > "$IWS/wtool-base-tools/wtool.xml"
_fail_try "① 清单坏了（引擎拒绝）"
rm -f "$IWS/wtool-base-tools/wtool.xml"; mv "$IWS/wtool-base-tools/wtool.xml.off" "$IWS/wtool-base-tools/wtool.xml"
mv "$IWS/wtool-base-tools/bin/wtool" "$IWS/wtool-base-tools/bin/wtool.off"
_fail_try "⑤ 删掉 bin/wtool（source 之后没这个命令）"
mv "$IWS/wtool-base-tools/bin/wtool.off" "$IWS/wtool-base-tools/bin/wtool"
rm -f "$IHOME/.wtool/wtool/install.sh"
_fail_try "① 入口链被删（其实每次跑都会补回来 → 应该 0）"
rm -rf "$IHOME/.wtool/var"
echo "  删掉 var/ 之后 check 的态度："
_rc=0; irun "$IHOME" "$IWS/wtool-base-tools/wtool.sh" check >/tmp/ifail2.log 2>&1 || _rc=$?
sed 's/^/      /' /tmp/ifail2.log
echo "      → rc = $_rc（非 0 = 账本不能删这条立住了）"
echo "  再跑一次 install.sh 让它自己长回来："
irun "$IHOME" "$IWS/wtool-base-tools/scripts/install.sh" < /dev/null >/dev/null 2>&1; echo "      → 退出码 $?"

echo
echo "=== 21. rc 两条路（⑥）：非交互只打印 / pty 答 y 才写 ==="
echo "  rc 里 WTOOL_HOME 出现次数 = $(grep -c WTOOL_HOME "$IHOME/.zshrc" || true)  ← 应该是 0（上面全程非交互）"
echo "  非交互那一段说了什么："
grep -E '没有终端可以问|不会替你改' /tmp/ifail.log 2>/dev/null | sed 's/^/      /' || true
if command -v script >/dev/null 2>&1; then
  printf 'y\n' | script -qec "env -i LD_LIBRARY_PATH='${LD_LIBRARY_PATH:-}' PATH='$PATH' HOME=$IHOME sh $IWS/wtool-base-tools/scripts/install.sh" /dev/null >/tmp/pty.log 2>&1 || true
  echo "  pty 里答 y 之后："
  grep -E '要我把|已写进|写好了' /tmp/pty.log | tr -d '\r' | sed 's/^/      /' | head -4
  echo "  rc 最后两行（zsh）:"; tail -2 "$IHOME/.zshrc" | tr -d '\r' | sed 's/^/      /'
  echo "  rc 最后两行（bash）:"; tail -2 "$IHOME/.bashrc" | tr -d '\r' | sed 's/^/      /'
  printf 'y\n' | script -qec "env -i LD_LIBRARY_PATH='${LD_LIBRARY_PATH:-}' PATH='$PATH' HOME=$IHOME sh $IWS/wtool-base-tools/scripts/install.sh" /dev/null >/dev/null 2>&1 || true
  echo "  再答一次 y（幂等）→ WTOOL_HOME 出现次数 = $(grep -c WTOOL_HOME "$IHOME/.zshrc")  ← 还是 2"
else
  echo "  （容器里没有 script，跳过 pty 那条）"
fi

echo
echo "=== 22. bundle 形态（③：包内副本只校验不覆盖）==="
IB=/work/ibundle
rm -rf "$IB"; mkdir -p "$IB/home/.wtool/wtool/.repo/manifests"
cp -a /work/wtool-base-tools "$IB/home/.wtool/wtool/wtool-base-tools"
cp "$IWS/.repo/manifests/default.xml" "$IB/home/.wtool/wtool/.repo/manifests/default.xml"
( cd "$IB/home/.wtool/wtool/.repo/manifests" && sha256sum default.xml > default.xml.sha256 )
git -C "$IWS/.repo/manifests" rev-parse HEAD > "$IB/home/.wtool/wtool/.repo/manifests/default.xml.commitid"
ln -s wtool/wtool-base-tools/scripts/install.sh "$IB/home/.wtool/install.sh"
printf '# zshrc\n' > "$IB/home/.zshrc"
_rc=0; irun "$IB/home" "$IB/home/.wtool/install.sh" < /dev/null >/tmp/ibundle.log 2>&1 || _rc=$?
echo "  bundle 里 install.sh 退出码 = $_rc"
grep -E '包内副本校验通过' /tmp/ibundle.log | sed 's/^/      /'
ls -l "$IB/home/.wtool/wtool/.repo/manifests" | sed 's/^/      /'
echo "  改坏 .sha256 再跑（应该停手非 0）："
printf '%s  default.xml\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    > "$IB/home/.wtool/wtool/.repo/manifests/default.xml.sha256"
_rc=0; irun "$IB/home" "$IB/home/.wtool/install.sh" < /dev/null >/tmp/ibundle2.log 2>&1 || _rc=$?
echo "      退出码 = $_rc"; grep -E '对不上' /tmp/ibundle2.log | sed 's/^/      /'
echo "  ★bundle 的项目目录还在吗: $([ -x "$IB/home/.wtool/wtool/wtool-base-tools/wtool.sh" ] && echo 在（没被备份走） || echo 丢了)"

echo
echo "ACCEPTANCE DONE"
