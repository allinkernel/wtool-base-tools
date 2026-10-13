#!/bin/sh
# wtool 自测：把"完全配对"变成可证明的属性。
#
# 全程在临时目录里跑，绝不碰真实 $HOME。
#   1. install  → uninstall 必须字节级回到安装前
#   2. install 幂等（第二次无变更）
#   3. 安装顺序不影响 $WTOOL_HOME/env.zsh 的最终内容（用户 rc 一个字都不动）
#   4. 仓库脏 / 非 git 时拒绝安装
#   5. 软链被用户换成真实文件时，uninstall 不删它
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
demo=${WTOOL_TEST_DEMO:-$boot/../terminal/tmux}

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
chk()   { # chk <描述> <期望> <实际> —— 和 contract_test 同名同义
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望: $2
实际: $3"; fi
}
check() { # check <描述> <期望> <实际>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望: $2
实际: $3"; fi
}

newhome() {
    h=$(mktemp -d "${TMPDIR:-/tmp}/wtool-home.XXXXXX")
    mkdir -p "$h/home"
    printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1\n' > "$h/home/.zshrc"
    printf '# 用户自己的 bashrc\n' > "$h/home/.bashrc"
    # 新口径（ADR-0045 §1.2 / D48）：**用户**在 rc 最后写那两行。
    # 引擎默认只打印、不代写（要用户点头），所以夹具里自己写上 ——
    # 之后"env 真的能加载起来"那几场才有意义，而且 install 不会再啰嗦那两行。
    wt_rc_lines "$h/home/.zshrc"
    wt_rc_lines "$h/home/.bashrc"
    # 项目都建在工作区里：**项目身份 = 它相对工作区根的路径**（ADR-0037），
    # 所以"项目放在哪个路径"就决定了它的身份，下面断言里那些 `wtool:<路径>`
    # 和 L1 链 `<dot>/wtool/<路径>` 都是这么来的。
    #
    # ‼️ 这里**不能** export WTOOL_ROOT：newhome 是在 `$(...)` 子 shell 里跑的，
    #    子 shell 里的 export 传不回父 shell（踩过：身份退化成目录名，
    #    `links/terminal/tmux` 变成 `links/tmux`）。由调用方导出。
    mkdir -p "$h/ws"
    echo "$h"
}

# rc 最后那两行（模拟用户照文档自己加）——按文件后缀给对应的 env 文件
wt_rc_lines() {   # <rc 文件>
    case $1 in
        *.bashrc) _wl_env=env.bash ;;
        *)        _wl_env=env.zsh ;;
    esac
    {
        printf 'export WTOOL_HOME=~/.wtool\n'
        printf 'source ${WTOOL_HOME}/%s\n' "$_wl_env"
    } >> "$1"
}

snap() { find "$1" -mindepth 1 -printf '%y %p -> %l\n' | sort; }

mkrepo() { # mkrepo <目录> <相对路径（就是身份）> <优先级>
    d=$1
    mkdir -p "$d"
    if [ -d "$demo" ]; then
        cp -r "$demo"/. "$d/"
    # ‼️ 拷过来的 .git 可能是指向 .repo/projects/… 的**软链**（repo 客户端的工作区就是这样），
    #    落进临时目录后会解析成 /tmp/.repo/… 而悬空，下面的 git init 直接 fatal。
    #    rm -rf 只删这条软链本身，不会跟着删目标。
    rm -rf "$d/.git"
    fi
    _var=$(printf '%s' "$2" | tr -c 'A-Za-z0-9' _)
    # ADR-0045：`<link>` 已删，$HOME 里不再建软链。这一组要验的"装了什么、
    # 卸完能不能字节级回退"改成走 **L2 导出链**：
    #   <项目>/__output/usr/bin/<名字>  →  $WTOOL_HOME/usr/bin/<名字>
    # kind 必须是 ②③（① 类不写 <export_*>），所以给个 kind="docker" + __output/。
    mkdir -p "$d/__output/usr/bin"
    cp "$d/tmux.conf" "$d/__output/usr/bin/wtool-test-$_var.conf"
    cat > "$d/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="docker" priority="$3">
  <zshrc src="env.zsh"/>
  <bashrc src="env.bash"/>
  <export_bin src="__output/usr/bin/wtool-test-$_var.conf" name="wtool-test-$_var.conf"/>
</wtool>
EOF
    printf '# env for %s\nexport WTOOL_TEST_%s=1\n' "$2" "$_var" > "$d/env.zsh"
    printf '# env for %s (bash)\nexport WTOOL_TEST_%s=1\n' "$2" "$_var" > "$d/env.bash"
    ( cd "$d" && git init -q && git add -A \
      && git -c user.email=t@example.com -c user.name=t commit -qm init )
}

# --------------------------------------------------------------------------
printf '\n== 场景 1：install / uninstall 完全配对 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
proj="$h/ws/terminal/tmux"; mkrepo "$proj" "terminal/tmux" 50

before=$(snap "$h/home")
"$boot/wtool.sh" install "$proj" > "$h/install.log" 2>&1 || {
    bad "install 执行成功" "$(cat "$h/install.log")"; }
after_install=$(snap "$h/home")

[ -L "$h/home/.wtool/usr/bin/wtool-test-terminal_tmux.conf" ] \
    && ok "L2 导出链已创建" || bad "L2 导出链已创建"
[ -d "$h/home/.wtool/wtool/terminal/tmux" ] \
    && ok "L1 接入链已创建" || bad "L1 接入链已创建"
[ -d "$h/home/.wtool/wtool" ] && [ ! -L "$h/home/.wtool/wtool" ] \
    && ok "\$WTOOL_HOME/wtool/ 是实体目录（L1 一条一链）" \
    || bad "\$WTOOL_HOME/wtool/ 不是实体目录"
[ "$(readlink "$h/home/.wtool/usr/bin/wtool-test-terminal_tmux.conf")" = \
  "../../wtool/terminal/tmux/__output/usr/bin/wtool-test-terminal_tmux.conf" ] \
    && ok "L2 是**相对**链（跟着 .wtool 走）" || bad "L2 不是相对链"
case $(readlink "$h/home/.wtool/wtool/terminal/tmux") in
    /*) ok "L1 是**绝对**链（断了能一眼看懂指哪）" ;;
    *)  bad "L1 不是绝对链" "$(readlink "$h/home/.wtool/wtool/terminal/tmux")" ;;
esac
# 新口径（ADR-0045 §1.2 / D48）：`install` **不写**用户的 rc（默认只打印那两行）；
# 项目的 env 块并进 `$WTOOL_HOME/env.zsh`（它再 source 账本里的块）。
wt_rc_now=$(cat "$h/home/.zshrc")
check "install 一个字都没往用户 rc 里写（默认只打印那两行）" \
    "$(printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1\nexport WTOOL_HOME=~/.wtool\nsource ${WTOOL_HOME}/env.zsh\n')" \
    "$wt_rc_now"
grep -q '# --- wtool:terminal/tmux (priority 50) ---' "$h/home/.wtool/env.zsh" \
    && ok "项目块并进了 \$WTOOL_HOME/env.zsh" || bad "\$WTOOL_HOME/env.zsh 里没有项目块"
grep -q '# >>> wtool:terminal/tmux schema=' "$h/home/.wtool/var/terminal/tmux/env.zsh" \
    && ok "账本里存着这个项目的 env 块（var/<项目>/env.zsh）" \
    || bad "账本里没有这个项目的 env 块"
grep -q 'export WTOOL_TEST_terminal_tmux=1' "$h/home/.wtool/var/terminal/tmux/env.zsh" \
    && bad "账本里的块把项目 env 的内容抄了一遍（应该只 source）" \
    || ok "账本里的块只 **source** 项目里那份 env（内容不抄两遍）"
# 真跑一遍：新 shell 里 source env.zsh，项目声明的变量和引擎给的三个变量都得在
if command -v bash >/dev/null 2>&1; then
    _got=$(env -i HOME="$h/home" WTOOL_HOME="$h/home/.wtool" PATH=/usr/bin:/bin \
        bash -c '. "$WTOOL_HOME/env.zsh" >/dev/null 2>&1; \
                 printf "%s|%s|%s" "$WTOOL_TEST_terminal_tmux" "$WTOOL_PROJECT_DIR" "$WTOOL_PROJECT_ROOT"')
    check "source \$WTOOL_HOME/env.zsh 之后项目变量都在" \
        "1|$h/home/.wtool/wtool/terminal/tmux|$proj" "$_got"
fi
grep -q 'WTOOL_HOME}/var/terminal/tmux/env.zsh' "$h/home/.wtool/env.zsh" \
    && ok "env.zsh 按 \$WTOOL_HOME 相对路径 source 账本里的块" \
    || bad "env.zsh 没 source 账本里的块" "$(cat "$h/home/.wtool/env.zsh")"
grep -q 'WTOOL_HOME 未设置或不存在' "$h/home/.wtool/env.zsh" \
    && ok "env.zsh 开头有校验片段（D48）" || bad "env.zsh 没有校验片段"
[ -f "$h/home/.wtool/env.bash" ] \
    && ok "env.bash 也生成了（两个 shell 各一份）" || bad "env.bash 没生成"
grep -q 'setopt auto_cd' "$h/home/.zshrc" \
    && ok "原有 rc 内容保留" || bad "原有 rc 内容保留"

"$boot/wtool.sh" uninstall "$proj" > "$h/uninstall.log" 2>&1 || {
    bad "uninstall 执行成功" "$(cat "$h/uninstall.log")"; }
after_uninstall=$(snap "$h/home")
check "uninstall 后 $HOME 与安装前一致" "$before" "$after_uninstall"
# 最后一个项目也卸了 → rc 里 wtool 的东西**全**剥掉（旧块 + 新形态那两行）。
# ⚠️ 文件本身**留着**（它是**用户**建的；`install` 从来没建过 rc）——
#    剥完只剩用户自己那几行，或者干脆是空文件。
check "rc 里 wtool 的东西全剥掉（一个项目都不剩）" \
      "$(printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1\n')" \
      "$(cat "$h/home/.zshrc")"
[ -f "$h/home/.zshrc" ] \
    && ok "★rc 文件本身还在（install 没建过它，uninstall 也就不删它）" \
    || bad "uninstall 把用户的 rc 文件删了"
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 2：install 幂等 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
proj="$h/ws/terminal/tmux"; mkrepo "$proj" "terminal/tmux" 50

"$boot/wtool.sh" install "$proj" > "$h/i1.log" 2>&1
s1=$(snap "$h/home"); rc1=$(cat "$h/home/.zshrc")
"$boot/wtool.sh" install "$proj" > "$h/i2.log" 2>&1
s2=$(snap "$h/home"); rc2=$(cat "$h/home/.zshrc")
check "第二次 install 不改变文件树" "$s1" "$s2"
check "第二次 install 不改变 rc 内容" "$rc1" "$rc2"
grep -q '没有需要变更的内容' "$h/i2.log" \
    && ok "第二次 install 报告无变更" || bad "第二次 install 报告无变更" "$(cat "$h/i2.log")"
"$boot/wtool.sh" uninstall "$proj" > /dev/null 2>&1
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 3：安装顺序无关 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
pa="$h/ws/zz/late"; pb="$h/ws/aa/early"
mkrepo "$pa" "zz/late" 50
mkrepo "$pb" "aa/early" 10
"$boot/wtool.sh" install "$pa" > /dev/null 2>&1
"$boot/wtool.sh" install "$pb" > /dev/null 2>&1
order1=$(grep -o '^# --- wtool:[a-z/]*' "$h/home/.wtool/env.zsh" | sed 's/^# --- //' | tr '\n' ' ')

h2=$(newhome)
export WTOOL_HOME="$h2/home/.wtool" WTOOL_STATE="$h2/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h2/home" WTOOL_LOG_ROOT="$h2/logs" WTOOL_ROOT="$h2/ws"
pa2="$h2/ws/zz/late"; pb2="$h2/ws/aa/early"
mkrepo "$pa2" "zz/late" 50
mkrepo "$pb2" "aa/early" 10
"$boot/wtool.sh" install "$pb2" > /dev/null 2>&1
"$boot/wtool.sh" install "$pa2" > /dev/null 2>&1
order2=$(grep -o '^# --- wtool:[a-z/]*' "$h2/home/.wtool/env.zsh" | sed 's/^# --- //' | tr '\n' ' ')

check "两种安装顺序得到相同的 rc 块顺序" "$order1" "$order2"
check "低优先级在前" "wtool:aa/early wtool:zz/late " "$order1"
rm -rf "$h" "$h2"

# --------------------------------------------------------------------------
printf '\n== 场景 4：仓库脏 / 非 git 时拒绝 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
proj="$h/ws/terminal/tmux"; mkrepo "$proj" "terminal/tmux" 50
printf 'dirty\n' >> "$proj/env.zsh"
if "$boot/wtool.sh" install "$proj" > "$h/dirty.log" 2>&1; then
    bad "脏仓库被拒绝" "却成功了"
else
    grep -q '未提交' "$h/dirty.log" \
        && ok "脏仓库被拒绝（提示未提交）" || bad "脏仓库被拒绝" "$(cat "$h/dirty.log")"
fi
( cd "$proj" && git -c user.email=t@example.com -c user.name=t commit -qam fix )
nogit="$h/nogit"; mkdir -p "$nogit"; cp -r "$proj"/. "$nogit/"; rm -rf "$nogit/.git"
if "$boot/wtool.sh" install "$nogit" > "$h/nogit.log" 2>&1; then
    bad "非 git 目录被拒绝" "却成功了"
else
    ok "非 git 目录被拒绝"
fi
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 5：软链被换成真实文件时，uninstall 不删它 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
proj="$h/ws/terminal/tmux"; mkrepo "$proj" "terminal/tmux" 50
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1
_l2="$h/home/.wtool/usr/bin/wtool-test-terminal_tmux.conf"
rm -f "$_l2"
printf 'user data\n' > "$_l2"
"$boot/wtool.sh" uninstall "$proj" > "$h/u.log" 2>&1 || true
if [ -f "$_l2" ] && [ ! -L "$_l2" ]; then
    ok "用户的真实文件被保留"
else
    bad "用户的真实文件被保留" "$(ls -l "$(dirname "$_l2")" 2>&1)"
fi
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 6：dry-run 零副作用 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
proj="$h/ws/terminal/tmux"; mkrepo "$proj" "terminal/tmux" 50
before=$(snap "$h/home")
"$boot/wtool.sh" install "$proj" --dry-run > "$h/dry.log" 2>&1
after=$(snap "$h/home")
check "dry-run 后文件树不变" "$before" "$after"
grep -q 'dry-run' "$h/dry.log" \
    && ok "dry-run 输出了计划" || bad "dry-run 输出了计划" "$(cat "$h/dry.log")"
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 7：重复 install 之后 uninstall 仍能完全回退（回归） ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
proj="$h/ws/terminal/tmux"; mkrepo "$proj" "terminal/tmux" 50
before=$(snap "$h/home")
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1   # no-op，但绝不能清空 journal
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1
"$boot/wtool.sh" uninstall "$proj" > "$h/u7.log" 2>&1
after=$(snap "$h/home")
check "连续 3 次 install 后 uninstall 仍完全回退" "$before" "$after"
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 8：rc 块真的能把 env 加载起来 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
proj="$h/ws/terminal/tmux"; mkrepo "$proj" "terminal/tmux" 50
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1

if command -v zsh >/dev/null 2>&1; then
    got=$(HOME="$h/home" zsh -c '. "$HOME/.zshrc" >/dev/null 2>&1; printf "%s|%s|%s" \
        "$WTOOL_TEST_terminal_tmux" "$WTOOL_PROJECT_DIR" "$WTOOL_PROJECT_ROOT"')
    check "env 里的变量被导出" "1|$h/home/.wtool/wtool/terminal/tmux|$proj" "$got"

    # 仓库**改名**：必须走 `wtool move`（= 卸旧的 + mv + 装新的，ADR-0037）。
    # 项目身份就是路径，所以"光 mv 再 install"会撞 registry 里的旧路径 ——
    # 那条路现在会报错（残渣由 wtool check 报出来），不再是一条可走的路。
    # 用户 rc 里只有那两行（这台机器上还没写过）—— 改名**一个字都不该变**。
    moved="$h/ws/terminal/tmux2"
    before_rc=$(cat "$h/home/.zshrc")
    "$boot/wtool.sh" move terminal/tmux terminal/tmux2 > "$h/move.log" 2>&1 \
        || bad "wtool move 执行成功" "$(cat "$h/move.log")"
    after_rc=$(cat "$h/home/.zshrc")
    check "改名后用户 rc 不变" "$before_rc" "$after_rc"
    got2=$(HOME="$h/home" zsh -c '. "$HOME/.zshrc" >/dev/null 2>&1; printf "%s" \
        "$WTOOL_PROJECT_ROOT"')
    check "搬家后 WTOOL_PROJECT_ROOT 指向新位置" "$moved" "$got2"
else
    printf 'SKIP  zsh 不可用，跳过场景 8\n'
fi
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 9：wtool-base-tools 自举项目提供的长期变量 ==\n'
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
# 引擎要求被安装的仓库是"干净的 git 仓"，所以拿一份 wtool-base-tools 的副本测试
bcopy="$h/ws/wtool-base-tools"
mkdir -p "$bcopy"
cp -r "$boot"/. "$bcopy/" 2>/dev/null || true
rm -rf "$bcopy/.git" "$bcopy/lib/__pycache__"
( cd "$bcopy" && git init -q && git add -A \
  && git -c user.email=t@example.com -c user.name=t commit -qm init )

# ⚠️ 自举那一步必须落在**这一轮的 `$WTOOL_HOME`** 里。
#    踩过：它原来只看 `$HOME`，于是跑一遍这个测试就把**真** `~/.wtool/wtool-base-tools`
#    指向 `$h/ws/wtool-base-tools` 这个临时副本 —— 测试跑完临时目录一删，真 HOME 里留下一条悬空软链。
#    所以这里两头都钉：该建的建在临时 `$WTOOL_HOME` 里，真 `~/.wtool` 一个字节不许动。
#    ‼️ 第 5b 块（D23）之后"自举"就是 **L1**：`$WTOOL_HOME/wtool/<项目>` → 工作区里
#    那个项目目录；`$WTOOL_HOME/wtool-base-tools` 这个**老位置不再存在**（下面也钉一条）。
_real_boot_before=$(readlink -- "$HOME/.wtool/wtool/wtool-base-tools" 2>/dev/null || echo 无)

"$bcopy/wtool.sh" install "$bcopy" > "$h/boot.log" 2>&1 || {
    bad "install wtool-base-tools" "$(cat "$h/boot.log")"; }
[ -d "$h/home/.wtool/wtool/wtool-base-tools" ] \
    && ok "wtool-base-tools 的 L1 接入链已创建" || bad "wtool-base-tools 的 L1 接入链已创建"
grep -q '# --- wtool:wtool-base-tools (priority' "$h/home/.wtool/env.zsh" \
    && ok "wtool-base-tools 的块写进了汇总文件" || bad "wtool-base-tools 的块没写进去"
check "自举（L1）落在这一轮的 \$WTOOL_HOME 里（\$WTOOL_HOME/wtool/wtool-base-tools）" "$bcopy" \
    "$(readlink -- "$h/home/.wtool/wtool/wtool-base-tools" 2>/dev/null || echo 无)"
check "★真 ~/.wtool/wtool/wtool-base-tools 没被动过" "$_real_boot_before" \
    "$(readlink -- "$HOME/.wtool/wtool/wtool-base-tools" 2>/dev/null || echo 无)"
check "D23：不再有 \$WTOOL_HOME/wtool-base-tools 这个老位置" "无" \
    "$(readlink -- "$h/home/.wtool/wtool-base-tools" 2>/dev/null || echo 无)"

if command -v zsh >/dev/null 2>&1; then
    got=$(HOME="$h/home" zsh -c '. "$HOME/.zshrc" >/dev/null 2>&1;
        printf "%s|%s|%s|%s" "$WTOOL_PREFIX" "$WTOOL_OS_ID" "$WTOOL_ARCH" \
               "$(case ":$PATH:" in *":$WTOOL_PREFIX/bin:"*) echo in-path;; *) echo missing;; esac)"')
    check "新 shell 里能拿到 PREFIX/OS_ID/ARCH 且 PATH 已含前缀" \
          "$h/home/.wtool/usr|ubuntu|x86_64|in-path" "$got"
    got2=$(HOME="$h/home" zsh -c '. "$HOME/.zshrc" >/dev/null 2>&1; command -v wtool')
    check "wtool 命令在 PATH 上" "$h/home/.wtool/wtool/wtool-base-tools/bin/wtool" "$got2"
else
    printf 'SKIP  zsh 不可用，跳过场景 9\n'
fi

"$bcopy/wtool.sh" uninstall "$bcopy" > /dev/null 2>&1
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n== 场景 10：wtool doctor 在干净 shell 里 eval 后可用 ==\n'
# `wtool env` 已经删掉，并进了 `wtool doctor`（2026-09）：
# 不带参数是环境诊断，带 --quiet/--json 时**只**输出 export 行，好让 eval 直接用。
got=$(env -i HOME="$HOME" PATH=/usr/bin:/bin sh -c \
    "eval \"\$('$boot/wtool.sh' doctor --quiet)\"; printf '%s|%s|%s' \
     \"\$WTOOL_PREFIX\" \"\$WTOOL_OS_ID\" \"\$(command -v wtool)\"")
check "eval 后 PREFIX/OS_ID/wtool 命令都可用" \
      "$HOME/.wtool/usr|ubuntu|$boot/bin/wtool" "$got"
got2=$(env -i HOME="$HOME" PATH=/usr/bin:/bin sh -c \
    "eval \"\$('$boot/wtool.sh' doctor --quiet)\"; printf '%s' \"\$WTOOL_JOBS\"")
[ -n "$got2" ] && ok "--quiet 只输出 export 行且 WTOOL_JOBS 非空" \
              || bad "--quiet 只输出 export 行且 WTOOL_JOBS 非空"
got3=$("$boot/wtool.sh" doctor --json | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["WTOOL_OS_ID"])' 2>/dev/null)
check "--json 可被程序解析" "ubuntu" "$got3"
# 删掉的三个命令要给出"现在该用什么"，而不是一句"未知命令"
for _dead in env list table; do
    _msg=$("$boot/wtool.sh" $_dead 2>&1 || true)
    case $_msg in
        *已经删掉*) ok "$_dead 提示已删掉并指向替代命令" ;;
        *) bad "$_dead 提示已删掉并指向替代命令" "$_msg" ;;
    esac
done

# --------------------------------------------------------------------------
printf '\n== 场景 11：本机日志 —— 每次安装一个新目录、编号递增、删了照样工作 ==\n'
#   ADR-0045 §1.9：**账本**进 `$WTOOL_HOME/var`（跟着 .wtool 走），**日志**留本机
#   `$WTOOL_LOG_ROOT/wtool-logs-<年>-<月日>-<时分>-<编号>/`（不跟着走、随便删）。
#   ‼️ 这一场是**容器验收里发现的洞**：`install` 原来根本不建日志目录
#      （惰性建，而 install 这条链上没人记账）—— 那时候容器里装完一遍，
#      `~/.local/state/wtool` 压根不存在。
h=$(newhome)
export WTOOL_HOME="$h/home/.wtool" WTOOL_STATE="$h/home/.wtool/var" \
    WTOOL_MANAGED_HOME="$h/home" WTOOL_LOG_ROOT="$h/logs" WTOOL_ROOT="$h/ws"
proj="$h/ws/terminal/tmux"; mkrepo "$proj" "terminal/tmux" 50

"$boot/wtool.sh" install "$proj" > "$h/i1.log" 2>&1
_n1=$(ls -1d "$h"/logs/wtool-logs-* 2>/dev/null | wc -l | tr -d ' ')
[ "$_n1" = 1 ] && ok "install 建了第一个日志目录" \
    || bad "install 没建日志目录" "$(ls -1d "$h"/logs/* 2>/dev/null | paste -sd' ' -)"
_d1=$(ls -1d "$h"/logs/wtool-logs-* 2>/dev/null | tail -1)
[ -f "$_d1/terminal/tmux/install.log" ] \
    && ok "日志里有这次 install 的一行（install.log）" \
    || bad "日志目录里没有 install.log" "$(find "$h/logs" -type f 2>/dev/null | paste -sd' ' -)"
grep -q '日志' "$h/i1.log" && ok "install 把日志路径打印出来了" \
    || bad "install 没说日志落在哪" "$(cat "$h/i1.log")"
# 账本里**不该**有日志（日志不跟着 .wtool 迁移）
[ -e "$WTOOL_STATE/terminal/tmux/build-logs" ] \
    && bad "账本里出现了日志目录" || ok "账本里没有日志（日志和账本分开了）"

sleep 1
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1
_n2=$(ls -1d "$h"/logs/wtool-logs-* 2>/dev/null | wc -l | tr -d ' ')
[ "$_n2" = 2 ] && ok "第二次 install 又建一个新目录（同一分钟内编号 +1，永不覆盖）" \
    || bad "第二次 install 没建新目录（现在 $_n2 个）" \
           "$(ls -1d "$h"/logs/* 2>/dev/null | paste -sd' ' -)"
_d2=$(ls -1d "$h"/logs/wtool-logs-* 2>/dev/null | tail -1)
[ "$_d1" != "$_d2" ] && ok "两个目录不是同一个（不覆盖）" || bad "两次装进同一个日志目录"
case $_d2 in
    *-002) ok "编号递增（…-001 → …-002）" ;;
    *) bad "编号没有递增" "$_d2" ;;
esac
# doctor 认的是**最新**那个
"$boot/wtool.sh" doctor 2>/dev/null | grep -q "log latest  : $_d2" \
    && ok "doctor 认的最新日志目录是编号最大的那个" \
    || bad "doctor 认错了最新日志目录" "$("$boot/wtool.sh" doctor 2>/dev/null | grep 'log ')"
# 旧目录**可以删**，删了 wtool 照常工作（只丢历史）
rm -rf "$_d1"
_rc=0
"$boot/wtool.sh" check "$proj" > "$h/c.log" 2>&1 || _rc=$?
chk "删掉旧日志之后 check 还是干净（退出 0）" "$_rc" "0"
_rc=0
"$boot/wtool.sh" install "$proj" > /dev/null 2>&1 || _rc=$?
chk "删掉旧日志之后 install 照常（退出 0）" "$_rc" "0"
# 连最新那个也删掉：check 不该因此报错（日志不是账本）
rm -rf "$h"/logs/wtool-logs-*
_rc=0
"$boot/wtool.sh" check "$proj" > /dev/null 2>&1 || _rc=$?
_out=$("$boot/wtool.sh" check "$proj" 2>&1) || true
chk "★日志一个不剩，check 照样干净（日志可删，账本不可删）" "$_rc" "0"
case $_out in
    *wtool-logs*) bad "check 拿日志目录说事（日志不该进 check 的判据）" "$_out" ;;
    *) ok "check 没提日志目录（它不是账本）" ;;
esac
"$boot/wtool.sh" uninstall "$proj" > /dev/null 2>&1
rm -rf "$h"

# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'PASS: %d   FAIL: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
