#!/bin/sh
# container_home_acceptance.sh —— **容器里真装一遍**的验收（ADR-0045 第 5a 块）
#
# 验的是这一块的四面：`$WTOOL_HOME` 新语义 / rc 两行（默认只打印、旧块替换、
# 非交互不挂）/ `$WTOOL_HOME/env.{zsh,bash}` / 账本进 `var/`、日志留本机且编号递增。
#
# 怎么跑（**宿主一个字节都不碰**；容器用完即弃）：
#
#   docker run --rm -v /:/h:ro -v ~/self/wtool:/wtool:ro -v <本目录>:/wtc:ro \
#     ubuntu:24.04 bash -c 'sh /wtc/container_home_acceptance.sh'
#
#   ⚠️ 为什么挂 `-v /:/h:ro`：这样**不用 apt**（实测走代理装包会十分钟起步、
#      经常直接超时）。python3 / git / zsh 都用宿主的，容器只当隔离层。
#   ⚠️ 脚本里 `cp -a /wtool/bootstrap` 到 /work：工作区是只读挂载，
#      而且验收要造自己的假 HOME / 假工作区。
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
cp -a /wtool/bootstrap "$WORK/bootstrap"
rm -rf "$WORK/bootstrap/lib/__pycache__" "$WORK/bootstrap/.git"
BOOT="$WORK/bootstrap"
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
echo
echo "ACCEPTANCE DONE"
