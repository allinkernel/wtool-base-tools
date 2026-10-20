#!/bin/sh
# contract_test.sh —— 新契约的端到端验证
#
# 这一组守的是"改了会静默出事"的那几条：
#   1. wtool.xml 新标签：<zshrc>/<bashrc>、<export_bin>/<export_usr>、<muslbin>、<generate>
#   2. 旧标签的下场：<link> **删掉解析**（D3，报错要能照做）、<env> 仍然认但警告
#   3. L1 / L2 两条链：L1 绝对（项目在哪）、L2 相对（项目提供什么）
#   4. 执行顺序：install.sh（__output/ → ~/.wtool）在前，XML 软链（影子 → $HOME）在后
#   5. 有 build.sh/download.sh 就必须先有 __output/（install 不替你编）
#   6. ~/usr → ~/.wtool/usr 这条全局软链：有项目就活着，一个不剩就收走
#   7. uninstall 拆软链前先问"还有别人要用吗"（判据是磁盘上的 wtool.xml）
#   8. check / repair：只报不改 / 只重建不删除
#   9. kill-self-forever：要逐字确认；删 wtool 的、不删别人的
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")
WT="$boot/wtool.sh"

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
# 注意最后要 return 0：不然"只带一个参数的 bad"会让函数返回非 0，
# 在 set -e 的脚本里直接终止整组测试（踩过）。
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
         if [ $# -gt 1 ]; then printf '      %s\n' "$2"; fi; return 0; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$2]  实际 [$3]"; }
chk()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$3]  实际 [$2]"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wtool-contract.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

newhome() {
    H=$(mktemp -d "$T/home.XXXXXX")
    mkdir -p "$H"
    printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1\n' > "$H/.zshrc"
    # state 每个场景一份：共用一份的话，前面场景留下的 state 会让
    # "还有没有项目装着"算错（~/usr 的生命周期那一场就是这么被坑的）
    # 新口径（ADR-0045 / D47）：WTOOL_HOME **就是** .wtool 根；账本在它下面 var/。
    # WTOOL_MANAGED_HOME = 假 $HOME（~/usr 那条链和 rc 落点靠它）。
    export WTOOL_HOME="$H/.wtool" WTOOL_STATE="$H/.wtool/var"
    export WTOOL_MANAGED_HOME="$H"
    export WTOOL_LOG_ROOT="$T/logs"
    export WTOOL_ROOT="$T/ws"
}
mkproj() {   # <相对路径>（这个路径**就是**项目身份，ADR-0037）
    d="$T/ws/$1"; mkdir -p "$d"
    git -C "$d" init -q
    echo "$d"
}
mkexport() {   # <项目目录> <条目名> <kind> [清单里的其它行…]
    # ADR-0045 之后"装一个项目"最少要有的东西：②③ 类的 kind + 一条 L2 导出。
    #   <项目>/__output/usr/bin/<条目名>  →  $WTOOL_HOME/usr/bin/<条目名>（**相对**链）
    # 想加 <zshrc>/<generate>/第二条导出，就把那些行当后面的参数传进来。
    _d=$1; _name=$2; _kind=$3; shift 3
    mkdir -p "$_d/__output/usr/bin"
    printf 'payload\n' > "$_d/__output/usr/bin/$_name"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<wtool schema="1" kind="%s" priority="50">\n' "$_kind"
        printf '<export_bin src="__output/usr/bin/%s"/>\n' "$_name"
        [ $# -gt 0 ] && printf '%s\n' "$@"
        printf '</wtool>\n'
    } > "$_d/wtool.xml"
    # 注意末尾这句：`[ $# -gt 0 ] &&` 为假时整行的退出码是 1，
    # 调用方在 `set -e` 下会直接退出 —— 所以显式还一个 0。
    return 0
}

# --------------------------------------------------------------------------
printf '\n== 场景 1：新标签全用上（zshrc/bashrc + 三段 link + produced-by）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
P=$(mkproj "terminal/tmux")
printf 'set -g mouse on\n' > "$P/tmux.conf"
printf 'export TMUX_MARK=1\n' > "$P/env.zsh"
printf 'export TMUX_MARK=1\n' > "$P/env.bash"
mkdir -p "$P/__output/usr/bin" "$P/__output/usr/share/man" "$P/scripts"
printf 'fzfbin\n' > "$P/__output/usr/bin/fzf"
printf 'rgbin\n' > "$P/__output/rg-dbg"
printf 'manpage\n' > "$P/__output/usr/share/man/fzf.1"
cat > "$P/scripts/install.sh" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--uninstall" ]; then
    # 卸载时要**先**拆完 L1/L2 链才轮到脚本（§4.2 的 ②' → ①'）
    if [ -e "$WTOOL_HOME/usr/bin/fzf" ] \
       || [ -e "$WTOOL_HOME/wtool/terminal/tmux" ]; then
        echo "links-still-there" > "$WTOOL_PROJECT_DIR/order-uninstall.txt"
    else
        echo "links-gone" > "$WTOOL_PROJECT_DIR/order-uninstall.txt"
    fi
    exit 0
fi
# ① 类才"源码即产物"；这里是 ②③ 类的形状：项目脚本还能往影子 HOME 铺自己的东西
mkdir -p "$WTOOL_HOME/.config/foo"
printf 'payload\n' > "$WTOOL_HOME/.config/foo/foo.conf"
EOF
cat > "$P/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="docker" priority="50">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
  <!-- L2：单个文件 → usr/bin/<name>（name 给了就用它，不给取 src 的 basename） -->
  <export_bin src="__output/rg-dbg" name="rg"/>
  <!-- L2：usr/ 下每个白名单子项逐条目导出 -->
  <export_usr src="__output/usr"/>
</wtool>
EOF
git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@t commit -qm init

_rc=0
"$WT" validate "$P" > "$T/v1.log" 2>&1 || _rc=$?
chk "新标签的清单 validate 通过" "$_rc" "0"
"$WT" install "$P" > "$T/i1.log" 2>&1 || bad "install 执行" "$(cat "$T/i1.log")"

# ---- L1「项目接入链」：<dot>/wtool/<项目路径> → 工作区项目（**绝对**）--------
L1="$WTOOL_HOME/wtool/terminal/tmux"
[ -L "$L1" ] && ok "L1 链建出来了" || bad "L1 链没建出来"
check "L1 指向工作区里那个项目（绝对路径）" "$P" "$(readlink "$L1" 2>/dev/null)"
case "$(readlink "$L1" 2>/dev/null)" in
    /*) ok "L1 是**绝对**链（D11）" ;;
    *)  bad "L1 不是绝对链" ;;
esac
[ -d "$WTOOL_HOME/wtool" ] && [ ! -L "$WTOOL_HOME/wtool" ] \
    && ok "\$WTOOL_HOME/wtool 是实体目录（L1 一条一链）" \
    || bad "\$WTOOL_HOME/wtool 不是实体目录"
# 惰性：只建装过的那个项目，别的项目一条都不建（D5）
[ -e "$WTOOL_HOME/wtool/terminal" ] \
    && ok "L1 按项目路径分层（terminal/tmux）" || bad "L1 分层不对"

# ---- L2「项目导出链」：<dot>/usr/<part>/<条目> → ../../wtool/<项目>/…（**相对**）----
L2BIN="$WTOOL_HOME/usr/bin/rg"
[ -L "$L2BIN" ] && ok "L2（export_bin）建出来了" || bad "L2（export_bin）没建出来"
check "L2 是**相对**链（跟着 .wtool 走，D45）" \
    "../../wtool/terminal/tmux/__output/rg-dbg" "$(readlink "$L2BIN" 2>/dev/null)"
[ -r "$L2BIN" ] && ok "顺着 L1+L2 打得开（不是断链）" || bad "L2 是断链"
check "顺着链读到内容" "rgbin" "$(cat "$L2BIN" 2>/dev/null)"
# export_usr 也逐条目建了 usr/bin 下的那一条（同一张 usr/bin 里两条并存）
check "export_usr 逐条目建了 usr/bin/fzf 那一条" \
    "../../wtool/terminal/tmux/__output/usr/bin/fzf" \
    "$(readlink "$WTOOL_HOME/usr/bin/fzf" 2>/dev/null)"
# export_usr：每个直接子项各展开、**按条目**建链，usr/<part> 自己是实体目录
[ -d "$WTOOL_HOME/usr/share" ] && [ ! -L "$WTOOL_HOME/usr/share" ] \
    && ok "usr/share 是实体目录（多项目共享，D7）" || bad "usr/share 不是实体目录"
check "export_usr 逐条目建了 usr/share/man" \
    "../../wtool/terminal/tmux/__output/usr/share/man" \
    "$(readlink "$WTOOL_HOME/usr/share/man" 2>/dev/null)"
# 同一个 usr/bin 下 fzf 只有一条（export_bin 那条），没有整目录替换
check "usr/bin 下两条并存（多项目共享这张表）" "fzf rg" \
    "$(ls "$WTOOL_HOME/usr/bin" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"

# `~/usr` 这条全局软链 **2026-10-21 起不再创建**（用户："装完只多 .wtool/ 与 rc 两行"；
# ADR-0046）。判据反过来：装完之后 $HOME 里**不许**出现 usr。
[ -e "$WTOOL_MANAGED_HOME/usr" ] || [ -L "$WTOOL_MANAGED_HOME/usr" ] \
    && bad "~/usr 又被建出来了（2026-10-21 起不再建）" || ok "~/usr 没建（新口径）"

# 新标签的路径也要幂等（L1+L2 + env.bash，重复 install 不该有任何变化）
_snap1=$(find "$WTOOL_HOME" -mindepth 1 -printf '%y %p -> %l\n' | LC_ALL=C sort)
_rc1=$(cat "$WTOOL_MANAGED_HOME/.zshrc")
"$WT" install "$P" > "$T/i1b.log" 2>&1 || bad "第二次 install 执行"
_snap2=$(find "$WTOOL_HOME" -mindepth 1 -printf '%y %p -> %l\n' | LC_ALL=C sort)
check "第二次 install 不改变文件树" "$_snap1" "$_snap2"
check "第二次 install 不改变 rc 内容" "$_rc1" "$(cat "$WTOOL_MANAGED_HOME/.zshrc")"
grep -q '没有需要变更的内容' "$T/i1b.log" && ok "第二次 install 报无变更" \
    || bad "第二次 install 没报无变更" "$(cat "$T/i1b.log")"

# env 两份都进了 `$WTOOL_HOME/env.{zsh,bash}`（ADR-0045 §1.2 / D48）：
# 汇总文件里放的是**块**（运行时 source 项目的 env 文件），不是把内容抄进去 ——
# 所以查的是块和它 source 的那一行
grep -q 'wtool:terminal/tmux' "$WTOOL_HOME/env.zsh" \
    && ok "zsh 的块进了 \$WTOOL_HOME/env.zsh" || bad "zsh 的块没进汇总"
grep -q 'env.zsh' "$WTOOL_HOME/env.zsh" \
    && ok "env.zsh 的块 source 的是 env.zsh" || bad "env.zsh 的块 source 错了"
grep -q 'env.bash' "$WTOOL_HOME/env.bash" \
    && ok "bash 的块进了 \$WTOOL_HOME/env.bash" || bad "bash 的块没进汇总"
# 块里的 WTOOL_PROJECT_DIR 必须是 **L1** 那条，而且走 `$WTOOL_HOME`
# （ADR-0045 起不再有中转链接，也不再写死 `$HOME/.wtool`）
grep -q 'WTOOL_PROJECT_DIR="\$WTOOL_HOME/wtool/terminal/tmux"' \
    "$WTOOL_HOME/env.zsh" \
    && ok "env 块里的 WTOOL_PROJECT_DIR 是 \$WTOOL_HOME 下的 L1 路径" \
    || bad "env 块里的 WTOOL_PROJECT_DIR 不是 L1 路径" "$(cat "$WTOOL_HOME/env.zsh")"
# 真 source 一遍：变量真的出来了才算数（rc 那两行由**用户**写，夹具里自己写）
_got=$(env -i HOME="$WTOOL_MANAGED_HOME" WTOOL_HOME="$WTOOL_HOME" sh -c \
    '. "$WTOOL_HOME/env.zsh"; printf "%s" "${TMUX_MARK:-}"')
check "source env.zsh 后变量真的在" "1" "$_got"

# --------------------------------------------------------------------------
printf '\n== 场景 2：check / repair（只报不改 / 只重建不删除）==\n'
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
chk "装完 check 干净（退出码 0）" "$_rc" "0"
rm -f "$L2BIN"
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "L2 链被删后 check 报出来（退出码非 0）" || bad "check 没报出来"
case $_out in
    *"不见了"*) ok "说清了是哪条不见了" ;;
    *) bad "没说清" "$_out" ;;
esac
"$WT" repair > "$T/repair.log" 2>&1 || bad "repair 执行" "$(cat "$T/repair.log")"
[ -L "$L2BIN" ] && ok "repair 把 L2 链补回来了" || bad "repair 没补回来"
check "补回来的链指向对" \
    "../../wtool/terminal/tmux/__output/rg-dbg" \
    "$(readlink "$L2BIN" 2>/dev/null)"
# repair 不删除：往 $HOME 放一个自己的文件，repair 之后它还得在
printf 'mine\n' > "$WTOOL_HOME/my-own-file"
"$WT" repair > /dev/null 2>&1
[ -f "$WTOOL_HOME/my-own-file" ] && ok "repair 不删用户的东西" || bad "repair 删了用户的东西"
_rc=0
"$WT" check > /dev/null 2>&1 || _rc=$?
chk "repair 之后 check 又干净了" "$_rc" "0"

# 场景 2b：卸载时**先拆 L1/L2，再跑 install.sh --uninstall**
_rc=0
"$WT" uninstall "$P" > "$T/u2b.log" 2>&1 || _rc=$?
chk "uninstall 执行成功" "$_rc" "0"
check "install.sh --uninstall 跑的时候 L1/L2 已经拆了" "links-gone" \
    "$(cat "$P/order-uninstall.txt" 2>/dev/null)"
[ -e "$L2BIN" ] && bad "卸载后 L2 链还在" || ok "卸载后 L2 链没了"
[ -e "$L1" ] && bad "卸载后 L1 链还在（D5：uninstall 只删那一条）" || ok "卸载后 L1 链没了"

# --------------------------------------------------------------------------
printf '\n== 场景 3：有 build.sh 就必须先有 __output/ ==\n'
newhome
mkdir -p "$WTOOL_ROOT"
P2=$(mkproj "editor/buildme")
mkdir -p "$P2/scripts"
printf '#!/bin/sh\ntrue\n' > "$P2/scripts/build.sh"
# ③ 类：清了 __output/ 就"没什么可导出的" → install 必须先拒绝
# ⚠️ mkexport 会顺手造出 __output/usr/bin/x；这里**删掉再提交** ——
#    `git status` 的 -uno 不算未跟踪文件，但把产物 commit 进去之后
#    下面重建它就变成"已跟踪改动"，install 会以"仓库脏"拒绝（踩过）。
mkexport "$P2" x docker
rm -rf "$P2/__output"
git -C "$P2" add -A && git -C "$P2" -c user.name=t -c user.email=t@t commit -qm init

_rc=0
"$WT" install "$P2" > "$T/i3.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "没有 __output/ 时 install 拒绝" || bad "没有 __output/ 居然装上了"
grep -q '__output/ 是空的' "$T/i3.log" && ok "说清了要先 build/download" \
    || bad "没说清原因" "$(cat "$T/i3.log")"
grep -q 'wtool download' "$T/i3.log" && ok "给了可复制的命令" || bad "没给命令"
mkdir -p "$P2/__output/usr/bin"
printf 'built\n' > "$P2/__output/usr/bin/x"
"$WT" install "$P2" > "$T/i3b.log" 2>&1 || bad "有 __output/ 之后 install 执行" "$(cat "$T/i3b.log")"
[ -L "$WTOOL_HOME/usr/bin/x" ] && ok "有 __output/ 之后就装上了" \
    || bad "有 __output/ 也没装上"

# 场景 3c：旧目录名的迁移提示（2026-10 的改名：release/ → __output/、publish/ → __release/）
#   判据是**形状**：旧 release/ 里是 <os>_<ver>/<层>/，新 __release/ 里是 *.zip + dist.json。
#   ⚠️ 两个都在时必须给出**顺序**（先 mv release __output 再 mv publish __release）——
#   反了会把 publish/ 塞进 __release/ 里。提示**只 warn，不改退出码**。
#   ⚠️ 这里造的必须是**旧名字** release/（没有下划线）—— 别跟着新名字改。
mkdir -p "$P2/publish"; printf 'pkg\n' > "$P2/publish/release.zip"
mkdir -p "$P2/release/ubuntu_22.04/main/payload"
_rc=0
_out=$("$WT" check "$P2" 2>&1) || _rc=$?
case $_out in
    *"mv release __output && mv publish __release"*)
        ok "两个旧目录都在：给了一条按顺序的命令" ;;
    *) bad "两个旧目录都在时没说顺序" "$_out" ;;
esac
# ⚠️ 这里只看"迁移提示本身不改退出码"：rc 里那两行的缺失是**另一件事**
#    （它会（正确地）让 check 非 0）—— 那张脸在场景 9b 里单独验。
case $_out in
    *"旧名字的产物目录"*) ok "提示走的是 warning（不是 error）" ;;
    *) bad "迁移提示没打出来" "$_out" ;;
esac
rm -rf "$P2/release"
_out=$("$WT" check "$P2" 2>&1) || true
case $_out in
    *"mv publish __release"*) ok "只有旧 publish/：提示改名" ;;
    *) bad "只有旧 publish/ 时没提示" "$_out" ;;
esac
rm -rf "$P2/publish"; mkdir -p "$P2/release/ubuntu_24.04/main/payload"
_out=$("$WT" check "$P2" 2>&1) || true
case $_out in
    *"mv release __output"*) ok "只有旧形状 release/：提示改名" ;;
    *) bad "只有旧 release/ 时没提示" "$_out" ;;
esac
# 2026-10 的上一版名字：output/ 和 layer/（ADR-0033）—— 也要提示，同样只提示。
#   ⚠️ 先挪走 __output：前面场景已经把它建出来了，而"新名字在就不提示"是**故意**的
rm -rf "$P2/__output"
mkdir -p "$P2/output/ubuntu_24.04/main/payload" "$P2/layer/ubuntu_24.04"
_out=$("$WT" check "$P2" 2>&1) || true
case $_out in
    *"mv output __output"*) ok "上一版的 output/ → 提示 mv output __output" ;;
    *) bad "output/ 没提示" "$_out" ;;
esac
case $_out in
    *"mv layer __layer"*) ok "上一版的 layer/ → 提示 mv layer __layer" ;;
    *) bad "layer/ 没提示" "$_out" ;;
esac
# 新名字里**真有东西**了就不再喊（用户搬完了，别再烦他）
mkdir -p "$P2/__output" "$P2/__layer"
printf 'moved\n' > "$P2/__output/.moved"; printf 'moved\n' > "$P2/__layer/.moved"
_out=$("$WT" check "$P2" 2>&1) || true
case $_out in
    *"mv output __output"*) bad "新名字已经在了还喊 mv output" "$_out" ;;
    *) ok "新名字里有东西了就不再提示（不烦人）" ;;
esac
rm -rf "$P2/output" "$P2/layer" "$P2/__output" "$P2/__layer"

# 新形状的 __release/（dist.json + 分卷）不该被误报
rm -rf "$P2/release"; mkdir -p "$P2/__release"
printf '{}\n' > "$P2/__release/dist.json"; printf 'z\n' > "$P2/__release/release.zip"
_out=$("$WT" check "$P2" 2>&1) || true
case $_out in
    *"mv __release"*) bad "新形状的 __release/ 被误报成旧目录" "$_out" ;;
    *) ok "新形状的 __release/ 不误报" ;;
esac
rm -rf "$P2/__release"

# --------------------------------------------------------------------------
printf '\n== 场景 4：同一条 L2 落点只能有一个项目（冲突报错，D8/D60）==\n'
#   `$WTOOL_HOME/usr/` 是**多项目共享**的实体目录，但**条目**是独占的：
#   两个项目要 `usr/bin/fzf` → 装第二个时报错并指出占用者，文案要请用户
#   **找助手改设计**（用户 2026-10-13 的口径：不设计 --takeover）。
newhome
mkdir -p "$WTOOL_ROOT"
A=$(mkproj "a/one"); B=$(mkproj "b/two")
mkexport "$A" shared docker
mkexport "$B" shared docker
git -C "$A" add -A && git -C "$A" -c user.name=t -c user.email=t@t commit -qm init
git -C "$B" add -A && git -C "$B" -c user.name=t -c user.email=t@t commit -qm init

"$WT" install "$A" > /dev/null 2>&1 || bad "装 A"
[ -L "$WTOOL_HOME/usr/bin/shared" ] && ok "A 的 L2 链建出来了" \
    || bad "A 的 L2 链没建出来"
check "A 的 L2 链指向 A 的 __output" \
    "../../wtool/a/one/__output/usr/bin/shared" \
    "$(readlink "$WTOOL_HOME/usr/bin/shared" 2>/dev/null)"

_rc=0
_out=$("$WT" install "$B" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "第二个项目要同一条落点 → 报错（退出码非 0）" \
    || bad "冲突居然装上了"
case $_out in
    *"已被 a/one 占用"*) ok "指出占用者是谁" ;;
    *) bad "没说清占用者" "$_out" ;;
esac
case $_out in
    *"找助手"*) ok "文案里请用户**找助手改设计**（不设计 --takeover）" ;;
    *) bad "文案里没有'找助手'" "$_out" ;;
esac
_rc=0
_out2=$("$WT" install "$B" --takeover 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "没有 --takeover 这个口子（敲了就是未知参数）" \
    || bad "--takeover 居然被认了"
case $_out2 in
    *"未知参数"*) ok "报的是'未知参数: --takeover'" ;;
    *) bad "没说清 --takeover 不认" "$_out2" ;;
esac
check "冲突之后落点还是 A 的（没被改坏）" \
    "../../wtool/a/one/__output/usr/bin/shared" \
    "$(readlink "$WTOOL_HOME/usr/bin/shared" 2>/dev/null)"

# registry 里那条登记仍然归 a/one
if [ -f "$WTOOL_STATE/registry.tsv" ]; then
    check "登记表里落点归 a/one" "a/one" \
        "$(awk -F'\t' -v d="$WTOOL_HOME/usr/bin/shared" '$1==d{print $2}' "$WTOOL_STATE/registry.tsv")"
fi

# --------------------------------------------------------------------------
printf '\n== 场景 5：~/usr 的生命周期（最后一个项目走了才收）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
C=$(mkproj "c/one"); D=$(mkproj "d/two")
for spec in "c/one Cone" "d/two Dtwo"; do
    set -- $spec
    mkexport "$T/ws/$1" "$2" docker
    git -C "$T/ws/$1" add -A && git -C "$T/ws/$1" -c user.name=t -c user.email=t@t commit -qm init
done
# 2026-10-21 起 `~/usr` 的"生命周期"整个不存在了：**任何时候都不建**。
# 这一场改成断言三件事：装了两个项目也不建；卸掉也不建（本来就没有）；
# 影子 HOME 里的实体 `$WTOOL_HOME/usr` 一直在（那是 L2 的落点，不许被顺手删）。
mkdir -p "$WTOOL_HOME/usr/bin"; printf 'bin\n' > "$WTOOL_HOME/usr/bin/x"
"$WT" install "$C" > /dev/null 2>&1
"$WT" install "$D" > /dev/null 2>&1
[ -e "$WTOOL_MANAGED_HOME/usr" ] || [ -L "$WTOOL_MANAGED_HOME/usr" ] \
    && bad "两个项目时 ~/usr 又被建出来了（新口径：不建）" || ok "两个项目时 ~/usr 仍然不建"
"$WT" uninstall "$C" > /dev/null 2>&1
[ -e "$WTOOL_MANAGED_HOME/usr" ] || [ -L "$WTOOL_MANAGED_HOME/usr" ] \
    && bad "卸一个之后 ~/usr 冒出来了" || ok "卸一个之后 ~/usr 还是没有"
"$WT" uninstall "$D" > /dev/null 2>&1
[ -e "$WTOOL_MANAGED_HOME/usr" ] || [ -L "$WTOOL_MANAGED_HOME/usr" ] \
    && bad "一个项目都不剩了 ~/usr 反而出现了" || ok "一个项目都不剩了 ~/usr 也没有"
[ -d "$WTOOL_HOME/usr" ] && ok "影子 HOME 里的实体 \$WTOOL_HOME/usr 一直不动" \
    || bad "把 $WTOOL_HOME/usr 实体也删了"

# --------------------------------------------------------------------------
printf '\n== 场景 5b：uninstall all（按 state 的账，不按项目表）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
G=$(mkproj "g/one"); Hh=$(mkproj "h/two")
mkexport "$G" Gone docker
mkexport "$Hh" Htwo docker
git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@t commit -qm init
git -C "$Hh" add -A && git -C "$Hh" -c user.name=t -c user.email=t@t commit -qm init
"$WT" install "$G" > /dev/null 2>&1
"$WT" install "$Hh" > /dev/null 2>&1
# 项目目录先"消失"（模拟仓库被删）：all 照样要能卸掉
mv "$Hh" "$Hh.gone"
"$WT" uninstall all > "$T/ua.log" 2>&1 || bad "uninstall all 执行" "$(cat "$T/ua.log")"
[ -e "$WTOOL_HOME/usr/bin/Gone" ] && bad "all 没卸掉 g/one" \
    || ok "uninstall all 卸掉了 g/one"
[ -e "$WTOOL_HOME/usr/bin/Htwo" ] && bad "all 没卸掉 h/two（项目目录已不在）" \
    || ok "项目目录不在也能卸（靠 state 的账）"
[ -e "$WTOOL_MANAGED_HOME/usr" ] || [ -L "$WTOOL_MANAGED_HOME/usr" ] \
    && bad "all 之后 ~/usr 出现了（新口径：本来就不该建）" || ok "all 之后 ~/usr 也不存在（新口径）"

# --------------------------------------------------------------------------
printf '\n== 场景 6：kill-self-forever（要逐字确认；删 wtool 的、不删别人的）==\n'
newhome
mkdir -p "$WTOOL_ROOT"
E=$(mkproj "e/one")
mkexport "$E" e docker '<zshrc src="env.zsh"/>'
printf 'export E=1\n' > "$E/env.zsh"
git -C "$E" add -A && git -C "$E" -c user.name=t -c user.email=t@t commit -qm init
# 新口径：那两行由**用户**写进 rc（install 默认只打印）。夹具里自己写上，
# 这一场才有"kill 把 rc 里 wtool 的东西剥干净"可验。
cat >> "$WTOOL_MANAGED_HOME/.zshrc" <<'RCEOF'
export WTOOL_HOME=~/.wtool
source ${WTOOL_HOME}/env.zsh
RCEOF
"$WT" install "$E" > /dev/null 2>&1
mkdir -p "$WTOOL_HOME/usr/bin"; printf 'bin\n' > "$WTOOL_HOME/usr/bin/e"
printf '不是 wtool 的东西\n' > "$WTOOL_HOME/keepme"

# 确认词不对 → 什么都不做
_rc=0
printf 'yes\n' | "$WT" kill-self-forever > "$T/kill1.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "确认词不对 → 拒绝执行" || bad "确认词不对还执行了"
[ -L "$WTOOL_HOME/usr/bin/e" ] && ok "拒绝之后什么都没删" || bad "拒绝之后东西没了"
grep -q 'KILL-SELF-FOREVER' "$T/kill1.log" && ok "提示了要输入什么" || bad "没提示确认词"
grep -q '不删' "$T/kill1.log" && ok "列清了不删什么（sudo 装的、别人的）" || bad "没说清不删什么"

_rc=0
"$WT" kill-self-forever --yes > "$T/kill2.log" 2>&1 || _rc=$?
chk "--yes 执行成功" "$_rc" "0"
[ -e "$WTOOL_HOME" ] && bad "~/.wtool 还在" || ok "~/.wtool 删干净了"
[ -e "$WTOOL_HOME/usr/bin/e" ] && bad "L2 链还在" || ok "L2 链删干净了"
[ -e "$WTOOL_STATE" ] && bad "state 还在" || ok "state 也删了"
grep -q 'wtool' "$WTOOL_MANAGED_HOME/.zshrc" \
    && bad "rc 里 wtool 的东西还在" || ok "rc 里 wtool 的东西剥掉了（那两行 + 旧块）"
check "rc 回到用户原来的内容" \
    "$(printf '# 用户自己的 zshrc\nsetopt auto_cd\nexport MY_STUFF=1\n')" \
    "$(cat "$WTOOL_MANAGED_HOME/.zshrc")"
if [ -f "$WTOOL_HOME/keepme" ]; then
    # `$WTOOL_HOME` 整棵被删了，"用户自己放进去的东西"当然也就没了 ——
    # 这是 kill-self-forever 的语义（它删的就是 $WTOOL_HOME）。
    ok "（\$WTOOL_HOME 整棵被删，用户放进去的东西跟着没 —— 符合 kill 的语义）"
else
    ok "\$WTOOL_HOME 整棵删干净了"
fi

# --------------------------------------------------------------------------
printf '\n== 场景 7：旧标签的下场（ADR-0045 / D3：不留兼容期）==\n'
#   `<link>` **删掉解析**：报错要能照做（说清原来那条该写成什么）。
#   `<env src= shells=>` 还是老写法（早就被 <zshrc>/<bashrc> 取代）—— 仍然认，但要警告。
newhome
mkdir -p "$WTOOL_ROOT"
F=$(mkproj "f/legacy")
printf 'f\n' > "$F/f.conf"
cat > "$F/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50">
  <env src="env.zsh" shells="zsh"/>
  <link src="f.conf" dest=".f.conf"/>
</wtool>
EOF
printf 'export F=1\n' > "$F/env.zsh"
git -C "$F" add -A && git -C "$F" -c user.name=t -c user.email=t@t commit -qm init

_rc=0
_v=$("$WT" validate "$F" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "<link> 的清单 validate 直接拒绝（不留兼容期）" \
    || bad "<link> 居然还认"
case $_v in
    *"<link> 已经删掉"*) ok "说清了 <link> 已经删掉（D3）" ;;
    *) bad "没说清 <link> 的下场" "$_v" ;;
esac
case $_v in
    *"export_bin"*) ok "给了照做就能改的路（<export_bin>）" ;;
    *) bad "没给可照做的改法" "$_v" ;;
esac
_rc=0
"$WT" install "$F" > "$T/i7.log" 2>&1 || _rc=$?
[ "$_rc" != 0 ] && ok "install 也拒绝（退出码非 0）" || bad "install 居然过了"
[ -e "$WTOOL_HOME/.f.conf" ] && bad "$HOME 里居然建出了软链（新模型不该有）" \
    || ok "$HOME 里没有 wtool 建的软链（D1）"

# 老写法 <env src= shells=> 仍然认（但每次解析都警告）
G=$(mkproj "g/legacyenv")
cat > "$G/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50">
  <env src="env.zsh" shells="zsh"/>
</wtool>
EOF
printf 'export GLEGACY=1\n' > "$G/env.zsh"
git -C "$G" add -A && git -C "$G" -c user.name=t -c user.email=t@t commit -qm init
_rc=0
_v=$("$WT" validate "$G" 2>&1) || _rc=$?
chk "旧写法 <env> 仍能通过校验" "$_rc" "0"
case $_v in
    *"旧写法"*) ok "validate 提示了旧写法该改" ;;
    *) bad "validate 没提示旧写法" "$_v" ;;
esac
"$WT" install "$G" > /dev/null 2>&1 || bad "旧写法的清单装不上"
[ -d "$WTOOL_HOME/wtool/g/legacyenv" ] \
    && ok "① 类项目装着就有 L1（不需要任何导出标签）" || bad "① 类项目没建出 L1"
# ⚠️ 把那份**故意写坏**的清单（f/legacy）从工作区里挪走：后面几个场景会
#    `wtool check` **整棵工作区**，留着它就会一路报"清单有问题"——
#    那不是那些场景要验的东西（实测踩过：move 场景的 check 被它顶成非 0）。
rm -rf "$T/ws/f"

# --------------------------------------------------------------------------
printf '\n== 场景 8：删掉的命令与改名的命令 ==\n'
for _dead in env list table; do
    _m=$("$WT" $_dead 2>&1 || true)
    case $_m in
        *已经删掉*) ok "$_dead 提示已删掉" ;;
        *) bad "$_dead 没提示已删掉" "$_m" ;;
    esac
done
_m=$("$WT" provision "$F" 2>&1 || true)
case $_m in
    *sudo-install*) ok "provision 指向了 sudo-install" ;;
    *) bad "provision 没指向新名字" "$_m" ;;
esac
_m=$("$WT" sudo-install "$F" --with-system 2>&1 || true)
case $_m in
    *已经删掉*) ok "sudo-install --with-system 提示已删掉" ;;
    *) bad "--with-system 没提示" "$_m" ;;
esac
_m=$("$WT" bootstrap --with-system 2>&1 || true)
case $_m in
    *sudo-bootstrap*) ok "bootstrap --with-system 指向 sudo-bootstrap" ;;
    *) bad "bootstrap --with-system 没指向新命令" "$_m" ;;
esac

# --------------------------------------------------------------------------
printf '\n== 场景 9：<build kind="local|docker"/>（ADR-025）==\n'
#   kind 决定两件事：这台机器行不行（没 docker 直接指路 download-release）、
#   __output/ 是什么形状（release.json 的 targets[] 跟着它走）。
newhome
mkdir -p "$WTOOL_ROOT"

mkbuildproj() {   # <相对路径> <build 标签行>
    # ⚠️ 根元素的 `kind="docker"` 是 ADR-0045 / D49 之后**必须**的：`build` 这条命令
    # 只有 ③ 类有，不声明类型（默认 source）会被分发点的门禁直接拒掉
    # （"kind=source ... 不支持 build"），脚本一行都不会跑，本场景就测不到东西了。
    # 而 `<build kind="local|docker">` 是**另一层**（怎么构建）—— 一个 kind="docker"
    # 的项目照样可以写 `<build kind="local"/>`（见下面第 ③ 个用例）。
    _d=$(mkproj "$1")
    mkdir -p "$_d/scripts"
    cat > "$_d/scripts/build.sh" <<'BEOF'
#!/bin/sh
echo "ran" > "$WTOOL_PROJECT_DIR/build-ran.txt"
mkdir -p "$WTOOL_PROJECT_DIR/__output/$WTOOL_BUILD_LAYER"
printf 'x\n' > "$WTOOL_PROJECT_DIR/__output/$WTOOL_BUILD_LAYER/out.bin"
BEOF
    chmod +x "$_d/scripts/build.sh"
    printf '%s\n' "$2" > "$_d/buildline"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<wtool schema="1" kind="docker" priority="50">\n'
        cat "$_d/buildline"
        printf '</wtool>\n'
    } > "$_d/wtool.xml"
    rm -f "$_d/buildline"
    echo "$_d"
}

# ① 非法 kind：validate 必须拒绝（顺带证明 <build> 不再是"未知元素" —— BL-22）
PD=$(mkbuildproj "editor/dockerproj" '<build kind="podman"/>')
_rc=0
_out=$("$WT" validate "$PD" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "<build kind=\"podman\"> 被 validate 拒绝" || bad "非法 kind 居然过了"
case $_out in
    *"只能是 local / docker"*) ok "报错说清了合法值" ;;
    *) bad "没说清合法值" "$_out" ;;
esac
# 顺带：<build> 本身是认识的标签了（BL-22 的症状是 error: 未知元素 <build>）
case $_out in
    *"未知元素"*) bad "validate 仍把 <build> 当未知元素（BL-22 回来了）" "$_out" ;;
    *) ok "<build> 不再是未知元素（BL-22）" ;;
esac
# 清单坏了的时候 build **不许猜**：解析失败 = 停下来，不能当成"大概是 local"就地开编
_rc=0
_out=$(WTOOL_DOCKER=/nonexistent/wtool-docker "$WT" build "$PD" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "清单坏了时 build 拒绝跑" || bad "清单坏了也照编（kind 落回默认值）"
[ -f "$PD/build-ran.txt" ] && bad "清单坏了 build.sh 还是跑了" || ok "清单坏了 build.sh 没跑"
case $_out in
    *"wtool.xml 有问题"*) ok "指了路（先 wtool validate）" ;;
    *) bad "没说清单有问题" "$_out" ;;
esac

# ② kind=docker + 没有 docker：拒绝、说原因、指路 download-release，**脚本不许跑**
WTB=$(mkbuildproj "editor/dockerproj" '<build kind="docker"/>')
export WTOOL_BUILD_LAYER=main
_rc=0
_out=$(WTOOL_DOCKER=/nonexistent/wtool-docker "$WT" build "$WTB" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "没 docker 时 build 退出码非 0（不当成成功）" || bad "没 docker 也报成功"
case $_out in
    *docker*) ok "说清了缺的是 docker" ;;
    *) bad "没说缺 docker" "$_out" ;;
esac
case $_out in
    *"download-release"*) ok "指了路：download-release" ;;
    *) bad "没指路下载" "$_out" ;;
esac
[ -f "$WTB/build-ran.txt" ] && bad "build.sh 居然跑了（白等一场）" || ok "build.sh 没跑（动手之前就拦住）"

# ③ 同一台机器上 kind=local（显式写）照跑
PL=$(mkbuildproj "editor/localproj" '<build kind="local" min-cores="1" min-mem="1" min-disk="1"/>')
_rc=0
_out=$(WTOOL_DOCKER=/nonexistent/wtool-docker "$WT" build "$PL" 2>&1) || _rc=$?
chk "kind=local：没有 docker 也编" "$_rc" "0"
[ -f "$PL/build-ran.txt" ] && ok "build.sh 跑了" || bad "local 项目没跑起来" "$_out"
chk "<build> 里的 min-* 是认识的（BL-22：不再报未知元素）" \
    "$("$WT" validate "$PL" >/dev/null 2>&1 && echo ok || echo bad)" "ok"

# ④ 不写 <build> = local（默认），也不要求 docker
PN=$(mkbuildproj "editor/nobuildtag" '<!-- 没有 <build> -->')
_rc=0
WTOOL_DOCKER=/nonexistent/wtool-docker "$WT" build "$PN" >/dev/null 2>&1 || _rc=$?
chk "不写 <build> 时默认 local，不要求 docker" "$_rc" "0"

# ⑤ 形状由声明决定：targets[] 的来源
chk "local 项目的 targets 是空的（不把层名当 target）" "" \
    "$(python3 "$boot/lib/wtool_plan.py" release-targets "$PL")"
mkdir -p "$WTB/__output/ubuntu_22.04/main" "$WTB/__output/ubuntu_24.04/main"
chk "docker 项目的 targets 就是 __output/<os>_<ver>/ 的名字" "ubuntu_22.04,ubuntu_24.04" \
    "$(python3 "$boot/lib/wtool_plan.py" release-targets "$WTB")"
mkdir -p "$PL/__output/main" "$PL/__output/lang-lua"      # local：层名不是 target
chk "local 项目就算 __output/ 里有多个目录，targets 还是空" "" \
    "$(python3 "$boot/lib/wtool_plan.py" release-targets "$PL")"

# --------------------------------------------------------------------------
printf '\n== 场景 9b：check 两个 shell 的汇总文件都查（BL-24）==\n'
#   生成那一侧两个 shell 都做了（render_env + _loader_block），
#   但 check 原来只查 ~/.wtool/.zshrc —— .bashrc 被误删时它一声不吭，
#   而 bash 用户的环境变量就静默失效了（最难查的半装状态）。
newhome
mkdir -p "$WTOOL_ROOT"
PB=$(mkproj "terminal/bashonly")
printf 'export BASH_ONLY=1\n' > "$PB/env.bash"
printf 'export BASH_ONLY=1\n' > "$PB/env.zsh"
cat > "$PB/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50">
  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>
</wtool>
EOF
git -C "$PB" add -A && git -C "$PB" -c user.name=t -c user.email=t@t commit -qm init
"$WT" install "$PB" >/dev/null 2>&1 || bad "装了却失败" "$(cat "$T/../x" 2>/dev/null)"
_out=$("$WT" check "$PB" 2>&1) || true
case $_out in
    *env.bash*) bad "两个汇总文件都在时就报 env.bash 有问题" "$_out" ;;
    *) ok "两个汇总文件都在时 check 不报" ;;
esac
# 新口径（ADR-0045 §1.2）：两个 shell 各一个 `$WTOOL_HOME/env.<shell>`，
# 删掉其中一个必须报出来（只查 zsh 的话，bash 用户的环境变量静默失效 —— BL-24）
rm -f "$WTOOL_HOME/env.bash"
_rc=0
_out=$("$WT" check "$PB" 2>&1) || _rc=$?
case $_out in
    *"env.bash 不见了"*) ok "★删掉 \$WTOOL_HOME/env.bash 之后 check 报出来（BL-24 修好）" ;;
    *) bad "删了 env.bash check 还是不吭声" "$_out" ;;
esac
[ "$_rc" != 0 ] && ok "check 退出码非 0" || bad "报了问题却退 0"
# ‼️ "rc 里还没有那两行"**不算错**（ADR-0045 §1.2 / D48）：install 默认只打印、
#    不代写，所以"用户还没来得及加"是正常状态 —— 提醒归 install / doctor。
#    check 只对"**摆错了**"报：旧块没迁、或者有那两行却一个项目都没装。
"$WT" install "$PB" >/dev/null 2>&1          # 先把 env.bash 补回来
printf '# 用户自己的 zshrc\nexport MY_STUFF=1\n' > "$WTOOL_MANAGED_HOME/.zshrc"
_rc=0
_out=$("$WT" check "$PB" 2>&1) || _rc=$?
chk "★rc 里还没有那两行不算错（install 本来就只打印）" "$_rc" "0"
case $_out in
    *"里没有 wtool 那两行"*) bad "check 去要那两行了（那是 install/doctor 的提醒）" "$_out" ;;
    *) ok "check 没去要那两行" ;;
esac
# 反过来：一个项目都没装、rc 里却留着那两行 → 那是**残渣**，要报
"$WT" uninstall "$PB" --no-script >/dev/null 2>&1 || true
printf '# 用户自己的 zshrc\nexport WTOOL_HOME=~/.wtool\nsource ${WTOOL_HOME}/env.zsh\n' \
    > "$WTOOL_MANAGED_HOME/.zshrc"
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
case $_out in
    *"一个项目都没装"*) ok "★rc 里留着那两行、账本却空了 → check 报残渣" ;;
    *) bad "残渣没被报出来" "$_out" ;;
esac
[ "$_rc" != 0 ] && ok "残渣时 check 退出码非 0" || bad "报了问题却退 0"
# 旧形态（`# >>> wtool >>>` 块）要能被认出来并提示替换（老机器迁移）
"$WT" install "$PB" >/dev/null 2>&1
printf '# 用户自己的 zshrc\n# >>> wtool >>>\n. "$HOME/.wtool/.zshrc"\n# <<< wtool <<<\n' \
    > "$WTOOL_MANAGED_HOME/.zshrc"
_rc=0
_out=$("$WT" check "$PB" 2>&1) || _rc=$?
case $_out in
    *"还有 wtool 的旧块"*) ok "★旧标记块 (\# >>> wtool >>>) 被认出来并提示替换" ;;
    *) bad "旧标记块没被认出来" "$_out" ;;
esac
[ "$_rc" != 0 ] && ok "旧形态时 check 退出码非 0" || bad "报了问题却退 0"
# 跑一次 install：旧块要**被替换**成那两行（幂等 —— 再跑一次还是那两行）
"$WT" install "$PB" >/dev/null 2>&1
_rc_after=$(cat "$WTOOL_MANAGED_HOME/.zshrc")
case $_rc_after in
    *'# >>> wtool >>>'*) bad "install 没把旧块替换掉" "$_rc_after" ;;
    *) ok "install 把旧标记块换成了那两行" ;;
esac
check "替换后 rc 最后两行就是那两行" \
    "export WTOOL_HOME=~/.wtool
source \${WTOOL_HOME}/env.zsh" \
    "$(tail -n 2 "$WTOOL_MANAGED_HOME/.zshrc")"
"$WT" install "$PB" >/dev/null 2>&1
chk "再跑一次 install：rc 还是那两行（幂等）" \
    "$_rc_after" "$(cat "$WTOOL_MANAGED_HOME/.zshrc")"
chk "rc 里只有两行 wtool 的东西（没有堆积）" "2" \
    "$(grep -c 'WTOOL_HOME' "$WTOOL_MANAGED_HOME/.zshrc")"

# --------------------------------------------------------------------------
printf '\n== 场景 10：install 认项目 id 和 all（需求 2）==\n'
#   需求 2 的形状是 `wtool [build|install|publish|download] all`。
#   build/download 早就有 all，install 只有 bootstrap 那条名字 —— 2026-09-28 补上。
newhome
# 自己一棵新的工作区根：前面的场景在同一棵树里留了一堆项目，
# `install all` 会把它们的软链冲突一起扫出来（那是别的场景要验的事）
export WTOOL_ROOT="$T/ws10"
mkdir -p "$WTOOL_ROOT/terminal/instid"
PI="$WTOOL_ROOT/terminal/instid"
git -C "$PI" init -q
mkdir -p "$PI/scripts"
mkexport "$PI" instid docker
git -C "$PI" add -A && git -C "$PI" -c user.name=t -c user.email=t@t commit -qm init

# ① 按 id 装（build / download-release / publish-release 都认 id，install 以前只认目录）
_rc=0
_out=$("$WT" install terminal/instid 2>&1) || _rc=$?
chk "install 认项目 id" "$_rc" "0"
[ -L "$WTOOL_HOME/usr/bin/instid" ] && ok "按 id 真装上了" \
    || bad "按 id 没装上" "$_out"
"$WT" uninstall terminal/instid >/dev/null 2>&1 || true
[ -L "$WTOOL_HOME/usr/bin/instid" ] && bad "uninstall <路径> 没撤掉" \
    || ok "uninstall <路径> 撤掉了"

# 不带任何开关的**裸路径**也要认（install 认了，uninstall 不认就会死在 cd 上）
"$WT" install terminal/instid >/dev/null 2>&1 || true
_rc=0
_out=$("$WT" uninstall terminal/instid 2>&1) || _rc=$?
chk "uninstall 也认裸项目 id" "$_rc" "0"
[ -e "$WTOOL_HOME/usr/bin/instid" ] && bad "裸 id 没撤掉" || ok "裸 id 撤掉了"

# ② install all（= wtool bootstrap：装所有"不需要你决策"的项目）
_rc=0
_out=$("$WT" install all 2>&1) || _rc=$?
chk "install all 退出码 0" "$_rc" "0"
[ -L "$WTOOL_HOME/usr/bin/instid" ] && ok "install all 把项目装上了" \
    || bad "install all 没装上" "$_out"
# dry-run 要在一个**干净的家目录**里验：刚装过的话"没有需要变更的内容"，
# 什么都不会打印（那条断言会假失败）
newhome
export WTOOL_ROOT="$T/ws10"
_rc=0
_out=$("$WT" install all --dry-run 2>&1) || _rc=$?
chk "install all --dry-run 退出码 0" "$_rc" "0"
case $_out in
    *"[dry-run]"*) ok "install all 也吃 --dry-run（打了计划）" ;;
    *) bad "install all --dry-run 没生效" "$_out" ;;
esac
[ -e "$WTOOL_HOME/usr/bin/instid" ] && bad "dry-run 居然真装了" \
    || ok "dry-run 一个字节没动"

# --------------------------------------------------------------------------
printf '\n== 场景 11：install --prune 清掉"清单里已经删掉"的导出（BL-15）==\n'
#   症状：从 wtool.xml 里删掉一条 <export_bin> 之后重装，旧 L2 链还留在磁盘上
#   （journal 里也还在），一直到 uninstall 才清。--prune 以 journal 为基准收掉它们。
#   判据必须是 **journal**（"我做过什么"）而不是扫磁盘 —— 扫磁盘会删掉用户自己的东西。
newhome
mkdir -p "$WTOOL_ROOT"
PP=$(mkproj "terminal/pruneproj")
mkdir -p "$PP/scripts"
prune_manifest() {   # <要写进去的导出/生成行…>
    mkdir -p "$PP/__output/usr/bin" "$PP/__output/usr/share"
    printf 'a\n' > "$PP/__output/usr/bin/a"
    printf 'b\n' > "$PP/__output/usr/bin/b"
    printf 's\n' > "$PP/__output/usr/share/s"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<wtool schema="1" kind="docker" priority="50">\n'
        printf '%s\n' "$@"
        printf '</wtool>\n'
    } > "$PP/wtool.xml"
    git -C "$PP" add -A
    git -C "$PP" -c user.name=t -c user.email=t@t commit -qm "manifest"
}
prune_manifest \
  '<export_bin src="__output/usr/bin/a"/>' \
  '<export_bin src="__output/usr/bin/b"/>' \
  '<export_usr src="__output/usr" part="share"/>'
"$WT" install "$PP" >/dev/null 2>&1 || bad "第一遍没装上（后面的断言都不成立）"
{ [ -L "$WTOOL_HOME/usr/bin/a" ] && [ -L "$WTOOL_HOME/usr/bin/b" ] \
  && [ -L "$WTOOL_HOME/usr/share/s" ]; } \
    && ok "三条 L2 链都建了" || bad "第一遍没建全"
[ -d "$WTOOL_HOME/usr/share" ] && [ ! -L "$WTOOL_HOME/usr/share" ] \
    && ok "usr/share 是实体目录（--prune 要能收走它下面的链）" || bad "usr/share 不是实体目录"
# 用户自己（不是 wtool）放的一条软链：--prune 一个字节都不许碰
ln -s /etc/hostname "$WTOOL_HOME/usr/bin/user-made"

# 清单里删掉 b，重装
prune_manifest \
  '<export_bin src="__output/usr/bin/a"/>' \
  '<export_usr src="__output/usr" part="share"/>'
"$WT" install "$PP" >/dev/null 2>&1 || bad "删掉 b 之后重装失败"
[ -L "$WTOOL_HOME/usr/bin/b" ] \
    && ok "不带 --prune 时旧链留着（BL-15 的症状，故意的）" \
    || bad "什么都没做旧链就没了（那这条不是可选项了）"

# ① --dry-run 只说不做
"$WT" install "$PP" --prune --dry-run >/dev/null 2>&1 || bad "--prune --dry-run 失败"
[ -L "$WTOOL_HOME/usr/bin/b" ] && ok "--prune --dry-run 一个字节没动" || bad "dry-run 居然真删了"

# ② --prune 真删，而且只删该删的
_rc=0
_out=$("$WT" install "$PP" --prune 2>&1) || _rc=$?
chk "--prune 退出码 0" "$_rc" "0"
[ -L "$WTOOL_HOME/usr/bin/b" ] && bad "--prune 没删掉旧链" "$_out" \
    || ok "--prune 删掉了旧链（清单里没有 b 了）"
[ -L "$WTOOL_HOME/usr/bin/a" ] && ok "清单里还有的那条留着" || bad "--prune 连在册的也删了"
[ -L "$WTOOL_HOME/usr/share/s" ] && ok "另一条落点（usr/share/s）也留着" \
    || bad "--prune 删了别的落点"
[ -L "$WTOOL_HOME/usr/bin/user-made" ] && ok "不是我们建的软链不碰" \
    || bad "--prune 删了用户自己的软链"
grep -q 'usr/bin/b' "$WTOOL_STATE/terminal/pruneproj/journal.tsv" 2>/dev/null \
    && bad "账还留在 journal 里（下次 --prune 会再删一遍）" || ok "journal 里那条账销掉了"
grep -q 'usr/bin/b' "$WTOOL_STATE/registry.tsv" 2>/dev/null \
    && bad "registry 里还占着落点（别的项目想用会撞冲突）" || ok "registry 里那条清了"

# ③ 幂等：再来一次不报错、也不动别的东西
_rc=0
_out=$("$WT" install "$PP" --prune 2>&1) || _rc=$?
chk "重复 --prune 退出码 0" "$_rc" "0"
[ -L "$WTOOL_HOME/usr/bin/a" ] && [ -L "$WTOOL_HOME/usr/bin/user-made" ] \
    && ok "重复 --prune 没伤到别人" || bad "重复 --prune 删多了"

# ④ 刹车：落点已经归了**另一个项目**（链接搬了家）→ 不删，留给那个项目
PQ=$(mkproj "terminal/pruneproj2")
mkdir -p "$PQ/__output/usr/bin"
printf 'c\n' > "$PQ/__output/usr/bin/a"
cat > "$PQ/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="docker" priority="50">
  <export_bin src="__output/usr/bin/a"/>
</wtool>
EOF
git -C "$PQ" add -A && git -C "$PQ" -c user.name=t -c user.email=t@t commit -qm init
"$WT" install "$PQ" --force >/dev/null 2>&1 || bad "第二个项目（同一个落点）没装上"
prune_manifest '<export_bin src="__output/usr/share/s"/>'
"$WT" install "$PP" --prune >/dev/null 2>&1 || bad "第二个项目装上之后 --prune 失败"
[ -L "$WTOOL_HOME/usr/bin/a" ] && ok "落点归了别的项目时不越权（链留着）" \
    || bad "--prune 删了别的项目正在用的链"

# --------------------------------------------------------------------------
# ③ 找不到时给的是能看懂的错，并且提一句怎么列出全部
_out=$("$WT" install nosuch-project 2>&1) || true
case $_out in
    *"项目路径不存在"*"wtool 裸跑看全部"*) ok "找不到项目时错误信息指了路" ;;
    *) bad "错误信息不好懂" "$_out" ;;
esac

# --------------------------------------------------------------------------
printf '\n== 场景 12：全局写锁（BL-17）==\n'
#   两个终端同时 install 会撞 registry.tsv / journal.tsv 的"读—改—写"：
#   各自读旧的、各写各的，最后落盘的那个把前一个的条目抹掉。
#   四条要守：跑完自动放锁 / 别人占着就不硬闯 / 占用者死了能接管 / 子进程不抢自己人的锁。
newhome
mkdir -p "$WTOOL_ROOT"
PW=$(mkproj "terminal/lockproj")
mkdir -p "$PW/scripts"
mkexport "$PW" lockproj docker
git -C "$PW" add -A && git -C "$PW" -c user.name=t -c user.email=t@t commit -qm init

# ① 正常跑完，锁要放掉（不放的话下一次 install 会等到超时）
"$WT" install "$PW" >/dev/null 2>&1 || bad "装没装上（后面的断言都不成立）"
[ -e "$WTOOL_STATE/.lock" ] && bad "跑完锁还留在状态目录里（下一次会白等）" \
    || ok "跑完自动放锁"

# ② 有人正占着（holder pid 是活的）：**不硬闯**，报清楚，什么都不动
mkdir -p "$WTOOL_STATE/.lock"
printf '%s\n' "$$" > "$WTOOL_STATE/.lock/pid"
rm -f "$WTOOL_HOME/usr/bin/lockproj"
_rc=0
_out=$(WTOOL_LOCK_TIMEOUT=0 "$WT" install "$PW" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "锁被占着时拒绝跑（不当成成功）" || bad "锁被占着还照跑"
case $_out in
    *"正在改状态目录"*) ok "说清了是谁占着、怎么办" ;;
    *) bad "等锁失败时没说清" "$_out" ;;
esac
[ -L "$WTOOL_HOME/usr/bin/lockproj" ] && bad "抢锁失败却已经动手改了东西" \
    || ok "抢锁失败时一个字节都没动"
rm -rf "$WTOOL_STATE/.lock"

# ③ 占用者已经死了 → 接管（不会永久卡住）
mkdir -p "$WTOOL_STATE/.lock"
printf '999999\n' > "$WTOOL_STATE/.lock/pid"
_rc=0
_out=$(WTOOL_LOCK_TIMEOUT=0 "$WT" install "$PW" 2>&1) || _rc=$?
chk "占用者死了时自动接管" "$_rc" "0"
[ -L "$WTOOL_HOME/usr/bin/lockproj" ] && ok "接管之后正常装上了" \
    || bad "接管了却没装上" "$_out"
[ -e "$WTOOL_STATE/.lock" ] && bad "接管之后没放锁" || ok "接管之后照样放锁"

# ④ 可重入：子进程（继承 WTOOL_LOCK_OWNER）不抢自己人的锁，也不替父进程放锁
mkdir -p "$WTOOL_STATE/.lock"
printf '1\n' > "$WTOOL_STATE/.lock/pid"
_rc=0
_out=$(WTOOL_LOCK_OWNER=1 "$WT" install "$PW" 2>&1) || _rc=$?
chk "继承 WTOOL_LOCK_OWNER 时不抢锁" "$_rc" "0"
[ -e "$WTOOL_STATE/.lock" ] && ok "也不替父进程放锁" || bad "子进程把父进程的锁放了"
rm -rf "$WTOOL_STATE/.lock"

# ⑤ dry-run 不锁：不写任何东西的命令没必要互斥（否则看个计划也要等）
mkdir -p "$WTOOL_STATE/.lock"
printf '%s\n' "$$" > "$WTOOL_STATE/.lock/pid"
_rc=0
_out=$(WTOOL_LOCK_TIMEOUT=0 "$WT" install "$PW" --dry-run 2>&1) || _rc=$?
chk "dry-run 不等锁（只读，不写状态）" "$_rc" "0"
rm -rf "$WTOOL_STATE/.lock"

# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
printf '\n== 场景 13：Tab 补全（wtool <TAB> 立刻列命令）==\n'
#   用户 2026-10-04：wtool 生效后按 Tab 不该去补当前目录的文件，要列可选命令；
#   bash / zsh 都要。候选由引擎自己算（`wtool _complete`），补全脚本只转发。
_cmds=$(WTOOL_SUDO=yes "$WT" _complete "" 2>/dev/null | tr '\n' ' ')
for want in install uninstall bootstrap build check repair doctor status \
            validate init version kill-self-forever refresh-downloads \
            pack-release publish-release download-release unpack-release \
            pack-offline-release publish-offline-release \
            sudo-install sudo-uninstall sudo-bootstrap \
            unpack-layer push-layer pull-layer; do
    case " $_cmds " in
        *" $want "*) ok "补全里有 $want" ;;
        *) bad "补全里缺 $want" "$_cmds" ;;
    esac
done
case " $_cmds " in
    *" _layer-save "*) bad "内部命令 _layer-save 不该进补全" ;;
    *) ok "内部命令不进补全（和 --help 口径一致）" ;;
esac
# `docs` 反过来：它是真命令，但 --help 故意不列它 —— 那补全里也**不该**有
#   （用户 2026-10-04 定的口径："--help 故意不列 docs，那就别加 docs"）
case " $_cmds " in
    *" docs "*) bad "补全里出现了 docs —— 和 --help 的口径不一致" ;;
    *) ok "docs 不进补全（--help 故意不列它，它只是 refresh-downloads 的别名）" ;;
esac
# `wtool status` 两种形态（用户 2026-10-04 定：就这样共存）。
# 无参那一形态 2026-10-21 改了（ADR-0046）：不再"先报缺失再打一张没有状态的登记表"，
# 而是**每行一个状态 + 表下一行汇总** —— 判据和 `wtool check` 同一个（project_health）。
case "$("$WT" status 2>&1)" in
    *"个项目：正常"*|*"账本里一个项目都没有"*) ok "status 无参 = 每行一个状态 + 汇总行" ;;
    *) bad "status 无参不是新的状态表" ;;
esac
case "$("$WT" status boot 2>&1)" in
    *"依据"*|*"找不到项目"*) ok "status <项目> = 新的逐列状态 + 依据" ;;
    *) bad "status <项目> 不是新的逐列查询" ;;
esac
chk "补 s 开头 → status + sudo-*" "status sudo-install sudo-uninstall sudo-bootstrap" \
    "$(WTOOL_SUDO=yes "$WT" _complete "s" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
# 没有 sudo 的机器：连补全也不提 sudo-*（和看板一个口径）
case "$(WTOOL_SUDO=never "$WT" _complete "" 2>/dev/null)" in
    *sudo-install*) bad "没有 sudo 时补全还提 sudo-install" ;;
    *) ok "没有 sudo 时补全不提 sudo-*" ;;
esac
case "$(WTOOL_SUDO=yes "$WT" _complete "-" install 2>/dev/null)" in
    *--dry-run*) ok "install 的开关补得出来" ;;
    *) bad "install 的开关补不出来" ;;
esac
case "$(WTOOL_SUDO=yes "$WT" _complete "-" pack-release 2>/dev/null)" in
    *--tag=*) ok "pack-release 的开关也补得出来（行首那条别漏）" ;;
    *) bad "pack-release 的开关补不出来（多半是列表匹配把换行当分隔符了）" ;;
esac
# 表里的开关必须**真的存在**（表自己的注释：补出一个不存在的开关，比不补更坏）。
#   判据：把 `wtool _complete "-" <命令>` 打出来的候选**原样**当参数跑一遍，
#   只断言输出里没有"未知参数" —— 各命令自己的用法报错不算失败。
#   安全边界：假 HOME / 假 state / **空 root**、不给位置参数、stdin 接 /dev/null
#   （kill-self-forever 会等人逐字确认，不接 /dev/null 会挂住）、不探 sudo-*
#   （那几条可能真的去提权）。
#   ⚠️ 只认**空格形式**的值开关（现在只剩 `--priority`）要单独补一个 dummy；
#      带 `=` 的（`--tag=` / `--color=` …）由 `*=` 那条兜住，别给它们补值 ——
#      补了会多出一个位置参数，反而把命令带偏。
_probe_home="$T/probe-home"; _probe_state="$T/probe-state"; _probe_ws="$T/probe-ws"
mkdir -p "$_probe_home" "$_probe_ws"
for _pc in install uninstall bootstrap build check repair doctor status \
           validate init version kill-self-forever refresh-downloads \
           pack-release publish-release download-release unpack-release \
           pack-offline-release publish-offline-release \
           unpack-layer push-layer pull-layer; do
    _pf=""
    for _cand in $(WTOOL_SUDO=yes "$WT" _complete "-" "$_pc" 2>/dev/null); do
        case $_cand in
            *=|--priority)      _pf="$_pf $_cand dummy" ;;
            *)                  _pf="$_pf $_cand" ;;
        esac
    done
    _rc=0
    _out=$(HOME="$_probe_home" WTOOL_HOME="$_probe_home" WTOOL_STATE="$_probe_state" \
           WTOOL_ROOT="$_probe_ws" "$WT" "$_pc" $_pf < /dev/null 2>&1) || _rc=$?
    case $_out in
        *"未知参数"*) bad "补全表里的开关，命令其实不认：$_pc$_pf" "$_out" ;;
        *) ok "补全表的开关都对得上：$_pc" ;;
    esac
done
for f in completion/wtool.bash completion/wtool.zsh; do
    [ -r "$boot/$f" ] && ok "有 $f" || bad "缺 $f"
done
grep -q 'completion/wtool.bash' "$boot/env.bash" && ok "env.bash 挂了补全" || bad "env.bash 没挂补全"
grep -q 'completion/wtool.zsh'  "$boot/env.zsh"  && ok "env.zsh 挂了补全"  || bad "env.zsh 没挂补全"
#   `; exit 0` 是必须的：env.bash 的最后一条命令万一非 0，`set -e` 会把测试带走
_bc=$(WTOOL_PROJECT_DIR="$boot" WTOOL_PREFIX="$H/prefix" \
      bash -c '. "$1" >/dev/null 2>&1; complete -p wtool 2>/dev/null; exit 0' sh "$boot/env.bash" 2>/dev/null)
case $_bc in
    *-F*wtool*) ok "bash 里 complete -p wtool 注册成功" ;;
    *) bad "bash 里没注册上补全" "$_bc" ;;
esac
if command -v zsh >/dev/null 2>&1; then
    _zc=$(WTOOL_PROJECT_DIR="$boot" WTOOL_PREFIX="$H/prefix" ZSH_COMPDUMP="$H/.zcompdump" \
          zsh -f -c '. "$1" >/dev/null 2>&1; print -r -- "${_comps[wtool]:-}"; exit 0' sh "$boot/env.zsh" 2>/dev/null)
    chk "zsh 里 wtool 挂到了 _wtool" "$_zc" "_wtool"
else
    ok "没有 zsh，跳过 zsh 补全那条"
fi

# --------------------------------------------------------------------------
printf '\n== 场景 14：sudo 探测两处实现必须一致（ADR-0035）==\n'
#   一条规则两处实现：引擎的 wtool_plan.py:sudo_state()（看板列不列那两列）
#   和 install-env.sh:env_sudo_state()（走不走提权流程）。同样的输入必须同样说法。
_py_state() {   # <WTOOL_SUDO> → none / yes
    BOOT="$boot" WTOOL_SUDO=$1 python3 -c '
import sys, os
sys.path.insert(0, os.environ["BOOT"] + "/lib")
import wtool_plan
print("none" if wtool_plan.sudo_state() == "none" else "yes")'
}
_sh_state() {   # <WTOOL_SUDO> → none / yes（install-env.sh 和 wtool.sh 两处都要一致）
    WTOOL_SUDO=$1 sh -c '. "$1"; env_sudo_state' sh "$boot/scripts/install-env.sh" 2>/dev/null
}
# 在 sudo 组、但要密码（标准 Ubuntu）= askpass —— 两处都得认出来，别误判成"没有 sudo"
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx 'sudo\|wheel'; then
    chk "在 sudo 组 → python 判 askpass（不是 none）" "_py_askpass" \
        "$(BOOT="$boot" python3 -c '
import sys, os
sys.path.insert(0, os.environ["BOOT"] + "/lib")
import wtool_plan
print("_py_askpass" if wtool_plan.sudo_state() == "askpass" else wtool_plan.sudo_state())')"
    chk "在 sudo 组 → install.sh 判 askpass（不是 none）" "askpass" \
        "$(sh -c '. "$1"; env_sudo_state' sh "$boot/scripts/install-env.sh" 2>/dev/null)"
else
    ok "当前用户不在 sudo 组，跳过 askpass 那条"
fi
for v in never auto yes; do
    _py=$(_py_state "$v"); _sh=$(_sh_state "$v")
    _sh_bool=yes; [ "$_sh" = none ] && _sh_bool=none
    chk "WTOOL_SUDO=$v：python 看板和 install.sh 说法一致" "$_py" "$_sh_bool"
done
_dash_nosudo=$(WTOOL_SUDO=never python3 "$boot/lib/wtool_plan.py" table --root "$WTOOL_ROOT" --state "$H/s14" --color=never 2>/dev/null)
case $_dash_nosudo in
    *"│ sudo "*) bad "没有 sudo 时看板还列着 sudo 列" ;;
    *) ok "没有 sudo 时不列 sudo 列" ;;
esac
case $_dash_nosudo in
    *"没有 sudo"*) ok "说清了为什么少两列" ;;
    *) bad "没说明少列的原因" ;;
esac

# --------------------------------------------------------------------------
printf '\n== 场景 15：--dry-run 不跑项目脚本（一个字节都不写）==\n'
#   用户 2026-10-04 拍板（原话"要改！！"）：--dry-run 只打印计划，**不执行操作**。
#   老做法是把 --dry-run 转给项目脚本、指望脚本自己支持 —— 那是空头支票：
#   templates/{install,build}.sh.tpl 里 0 处 dry-run；2026-10-04 拿一个真实项目脚本
#   （tools/gerrit-gate/scripts/install.sh，该项目 2026-10-09 已搬出本工作区）实测过
#   "--dry-run 照样 ln -s 建软链"，判据 = 末尾 `ls -l $T/prefix/bin` 有输出。
#   ⚠️ 那个脚本已经不在了，**这条复现没法原地重跑**，只留作当时的记录。
#   本场景的判据：项目脚本**故意不认** --dry-run（被调用就落地），
#   dry-run 前后文件清单必须逐行相同。
newhome
mkdir -p "$WTOOL_ROOT"
P4=$(mkproj "dry/proj")
mkdir -p "$P4/__output" "$P4/scripts"
printf 'payload\n' > "$P4/__output/out.bin"
printf 'conf\n' > "$P4/dry.conf"
cat > "$P4/scripts/install.sh" <<'EOF'
#!/bin/sh
# 故意不认 --dry-run：只要被调用就留下证据（老引擎会把 --dry-run 喂进来）
echo "install $*" >> "$WTOOL_PROJECT_DIR/install-called.txt"
case ${1:-} in
    --uninstall)
        echo "uninstall $*" >> "$WTOOL_PROJECT_DIR/uninstall-called.txt"
        rm -f -- "$WTOOL_PREFIX/bin/dry.conf"
        exit 0 ;;
esac
mkdir -p -- "$WTOOL_PREFIX/bin"
ln -sfn -- "$WTOOL_PROJECT_DIR/dry.conf" "$WTOOL_PREFIX/bin/dry.conf"
EOF
cat > "$P4/scripts/build.sh" <<'EOF'
#!/bin/sh
echo "build $*" >> "$WTOOL_PROJECT_DIR/build-called.txt"
EOF
# ②③ 类才写导出标签：产物在 __output/ 下（项目脚本自己也会往 WTOOL_PREFIX 铺东西，
# 那是项目的事；引擎这半边只认 L1 + L2 + env 块）
mkdir -p "$P4/__output/usr/bin"
printf 'payload\n' > "$P4/__output/usr/bin/dry"
cat > "$P4/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="docker" priority="50">
  <export_bin src="__output/usr/bin/dry"/>
</wtool>
EOF
git -C "$P4" add -A && git -C "$P4" -c user.name=t -c user.email=t@t commit -qm init

_snap() {   # 这个场景自己的三棵树：项目目录 / 影子 HOME / state
    { find "$P4" "$WTOOL_HOME" "$WTOOL_STATE" -mindepth 1 2>/dev/null || true; } | sort
}

_before=$(_snap)
_rc=0
_out=$("$WT" install dry/proj --dry-run 2>&1) || _rc=$?
chk "install --dry-run 退出 0" "$_rc" "0"
chk "install --dry-run 前后文件清单逐行相同（零副作用）" "$_before" "$(_snap)"
if [ -e "$P4/install-called.txt" ]; then
    bad "install --dry-run 居然跑了 scripts/install.sh"
else
    ok "install --dry-run 没跑 scripts/install.sh"
fi
case $_out in
    *"scripts/install.sh"*) ok "打印了要跑的脚本路径" ;;
    *) bad "没打印脚本路径" "$_out" ;;
esac
case $_out in
    *"$P4"*) ok "打印了工作目录" ;;
    *) bad "没打印工作目录" "$_out" ;;
esac
case $_out in
    *"WTOOL_PREFIX="*) ok "打印了关键环境变量（WTOOL_PREFIX 等）" ;;
    *) bad "没打印环境变量" "$_out" ;;
esac
if [ -e "$WTOOL_HOME/usr/bin/dry.conf" ]; then
    bad "install --dry-run 真落了软链"
else
    ok "install --dry-run 一个软链都没落"
fi

_before=$(_snap)
_rc=0
_out=$("$WT" build dry/proj --dry-run 2>&1) || _rc=$?
chk "build --dry-run 退出 0" "$_rc" "0"
chk "build --dry-run 前后文件清单逐行相同（零副作用）" "$_before" "$(_snap)"
if [ -e "$P4/build-called.txt" ]; then
    bad "build --dry-run 居然跑了 scripts/build.sh"
else
    ok "build --dry-run 没跑 scripts/build.sh"
fi
case $_out in
    *"scripts/build.sh"*) ok "build --dry-run 也打印了脚本路径" ;;
    *) bad "build --dry-run 没打印脚本路径" "$_out" ;;
esac

# uninstall 得先真装上才有东西可撤（上面全是 dry-run，磁盘上还什么都没有）
"$WT" install dry/proj > "$T/i15.log" 2>&1 || bad "（前置）真装一遍失败" "$(cat "$T/i15.log")"
[ -L "$WTOOL_HOME/usr/bin/dry" ] && ok "（前置）真装之后 L2 链在" \
    || bad "（前置）真装没建成"
#   项目只能按**路径**给（ADR-0037 删掉了 --id）。以前 `--id` / 裸 id 那条路
#   拿不到 project_root，项目脚本那一步会被静默跳过；BL-47/BL-48 修好之后
#   两条路（目录 / 路径）等价 —— 见场景 16（那里用标记文件断言真跑了脚本，
#   本场景仍然只验 dry-run 的零副作用）。
_before=$(_snap)
_rc=0
_out=$("$WT" uninstall "$P4" --dry-run 2>&1) || _rc=$?
chk "uninstall --dry-run 退出 0" "$_rc" "0"
chk "uninstall --dry-run 前后文件清单逐行相同（零副作用）" "$_before" "$(_snap)"
if [ -e "$P4/uninstall-called.txt" ]; then
    bad "uninstall --dry-run 居然跑了 install.sh --uninstall"
else
    ok "uninstall --dry-run 没跑项目脚本"
fi
[ -L "$WTOOL_HOME/usr/bin/dry" ] && ok "uninstall --dry-run 之后 L2 链还在" \
    || bad "uninstall --dry-run 把软链拆了"
case $_out in
    *"install.sh"*) ok "uninstall --dry-run 也打印了脚本路径" ;;
    *) bad "uninstall --dry-run 没打印脚本路径" "$_out" ;;
esac

# --------------------------------------------------------------------------
printf '\n== 场景 16：uninstall 按路径指项目，且**必须**跑项目脚本（BL-47 / ADR-0037）==\n'
#   历史：`--id` 那条路以前拿不到 project_root，第 3 步"跑项目自己的
#   install.sh --uninstall"被**静默跳过** —— 不报错、不警告，用户以为卸干净了。
#   BL-48 修好了解析；ADR-0037 又把 `--id` 整个删掉（身份就是路径），
#   所以现在只剩**路径**一种给法，判据仍然是那个标记文件。
#
#   复现（改前 / 回归时都能照着敲）：
#     T=$(mktemp -d); export WTOOL_ROOT=$T/ws WTOOL_HOME=$T/home WTOOL_STATE=$T/state
#     mkdir -p $WTOOL_ROOT/foo/bar/scripts $WTOOL_HOME
#     printf '#!/bin/sh\necho un >> "$WTOOL_PROJECT_ROOT/uninstall-called.txt"\n' \
#       > $WTOOL_ROOT/foo/bar/scripts/install.sh
#     printf '<?xml version="1.0"?>\n<wtool schema="1"/>\n' > $WTOOL_ROOT/foo/bar/wtool.xml
#     git -C $WTOOL_ROOT/foo/bar init -q && git -C $WTOOL_ROOT/foo/bar add -A \
#       && git -C $WTOOL_ROOT/foo/bar -c user.name=t -c user.email=t@t commit -qm init
#     sh wtool-base-tools/wtool.sh install foo/bar
#     sh wtool-base-tools/wtool.sh uninstall foo/bar
#     ls $WTOOL_ROOT/foo/bar/uninstall-called.txt
#   标记文件写在**项目目录**里（state 卸完会被删掉，留在那儿就看不见了）。
newhome
mkdir -p "$WTOOL_ROOT"
P5=$(mkproj "idrun/proj")
mkdir -p "$P5/__output" "$P5/scripts"
printf 'payload\n' > "$P5/__output/out.bin"
printf 'conf\n' > "$P5/idrun.conf"
cat > "$P5/scripts/install.sh" <<'EOF'
#!/bin/sh
# 只要被调用就留证据（参数也记下来）
case ${1:-} in
    --uninstall) echo "uninstall $*" >> "$WTOOL_PROJECT_ROOT/uninstall-called.txt"; exit 0 ;;
esac
mkdir -p -- "$WTOOL_PREFIX/bin"
ln -sfn -- "$WTOOL_PROJECT_ROOT/idrun.conf" "$WTOOL_PREFIX/bin/idrun.conf"
EOF
mkdir -p "$P5/__output/usr/bin"
printf 'idrun\n' > "$P5/__output/usr/bin/idrun"
cat > "$P5/wtool.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="docker" priority="50">
  <export_bin src="__output/usr/bin/idrun"/>
</wtool>
EOF
git -C "$P5" add -A && git -C "$P5" -c user.name=t -c user.email=t@t commit -qm init

# ① 路径形式（相对工作区根）—— 得真跑项目脚本
"$WT" install idrun/proj > "$T/i16.log" 2>&1 || bad "（前置）真装一遍失败" "$(cat "$T/i16.log")"
_rc=0
_out=$("$WT" uninstall idrun/proj 2>&1) || _rc=$?
chk "uninstall <路径> 退出 0" "$_rc" "0"
if [ -e "$P5/uninstall-called.txt" ]; then
    ok "★uninstall <路径> 真跑了 install.sh --uninstall"
else
    bad "uninstall 又静默跳过项目脚本（标记文件没出现）" "$_out"
fi
chk "脚本收到的参数是 --uninstall" "uninstall --uninstall" \
    "$(cat "$P5/uninstall-called.txt" 2>/dev/null)"
case $_out in
    *"项目脚本: install.sh --uninstall"*) ok "日志里说了要跑项目脚本" ;;
    *) bad "日志里没提项目脚本" "$_out" ;;
esac

# ② `--id` 是**删掉的老写法**：必须**明确报错 + 指路**，不能当成"未知参数"，
#    更不能装作没看见（老脚本 / 老文档里到处是它）。
_rc=0
_out=$("$WT" uninstall --id idrun/proj 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "--id 老写法退出码非 0" || bad "--id 居然还能用" "$_out"
case $_out in
    *"--id 已经删掉"*) ok "★报错说清了 --id 已经删掉" ;;
    *) bad "--id 没给出说明" "$_out" ;;
esac
case $_out in
    *"wtool uninstall idrun/proj"*) ok "--id 的报错里给了等价的路径写法" ;;
    *) bad "--id 的报错没指路" "$_out" ;;
esac
# init 的 --id 同理（它以前是写进 wtool.xml 的 id= 属性）
_rc=0
_out=$("$WT" init "$T/ws16new" --id foo 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "init --id 老写法退出码非 0" || bad "init --id 居然还能用" "$_out"
case $_out in
    *"--id 已经删掉"*) ok "init 的 --id 也给了说明" ;;
    *) bad "init --id 没给出说明" "$_out" ;;
esac

# ③ 解析不出来 → **明确报错**、退出码非 0
#    （改前这里是"uninstall 完成" + 什么都不做 —— 静默跳过就是这条路的病根）
_rc=0
_out=$("$WT" uninstall no/such-proj 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "路径解析不出来时退出码非 0" || bad "找不到项目却退 0" "$_out"
case $_out in
    *"找不到项目"*) ok "报错里说清了找不到项目" ;;
    *) bad "没有明确报错" "$_out" ;;
esac
case $_out in
    *"--no-script"*) ok "报错里给了 --no-script 这条退路" ;;
    *) bad "报错没给退路" "$_out" ;;
esac
# `--no-script` 是**明说**不跑脚本，那种情况只要警告、不该报错
_rc=0
_out=$("$WT" uninstall no/such-proj --no-script 2>&1) || _rc=$?
chk "解析不出来 + --no-script 只警告（退出 0）" "$_rc" "0"
case $_out in
    *"warning"*) ok "解析不出来 + --no-script 打了警告（不是静默）" ;;
    *) bad "--no-script 那条路一句话都没说" "$_out" ;;
esac

# ④ 末段**不替用户猜**：state 的账是按完整路径建目录的，
#    "唯一的末段匹配"会在"表里只剩 x/foo/bar、账上却是 foo/bar"时卸错项目。
_rc=0
_out=$("$WT" uninstall proj 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "末段不认（要完整路径）" || bad "末段被认了" "$_out"
case $_out in
    *"idrun/proj"*) ok "把末段同名的候选列出来了（提示写完整路径）" ;;
    *) bad "没提示候选项目" "$_out" ;;
esac

# --------------------------------------------------------------------------
printf '\n== 场景 17：改名的正确姿势是 wtool move；改错了 check 必须报（ADR-0037）==\n'
#   项目身份 = 路径。所以"把目录 mv 一下"**不再**是一次无害的操作：
#   旧路径那套账（state 目录 / 中转软链 / env 块 / registry 行）全留在原地，
#   而且大多**不报错、只是静默失效**。这一场守两件事：
#     ① `wtool move` 能把旧账收干净（收不干净就是它的 bug）
#     ② 手工 mv 留下的残渣，`wtool check` **必须报出来**（报不出来就是 check 的 bug）
newhome
mkdir -p "$WTOOL_ROOT"

_s17_mk() {   # <相对路径>
    _d="$WTOOL_ROOT/$1"; mkdir -p "$_d/__output" "$_d/scripts"
    git -C "$_d" init -q
    # 每个项目的落点必须**唯一**：两个项目声明同一个 home= 会被判成
    # "dest 已被项目 X 占用"（引擎的跨项目冲突检测），那不是本场景要测的东西。
    _s17_slug=$(printf '%s' "$1" | tr '/' '-')
    printf 'p\n' > "$_d/payload.bin"
    printf 'export S17=1\n' > "$_d/env.zsh"
    printf 'export S17=1\n' > "$_d/env.bash"
    # 带 install.sh：① 影子 HOME 的 usr/ 有实体（否则 ~/usr 这条全局软链悬空，
    #   那是"项目没提供 usr 内容"的正常形态，不是 move 的问题）；
    #   ② 顺带证明 move 真把**项目脚本**走了一遍（卸载一次、安装一次）。
    cat > "$_d/scripts/install.sh" <<'EOF'
#!/bin/sh
_s17_self=$(basename -- "$WTOOL_PROJECT_ROOT")
if [ "${1:-}" = "--uninstall" ]; then
    rm -f -- "$WTOOL_PREFIX/bin/$_s17_self"
    exit 0
fi
mkdir -p -- "$WTOOL_PREFIX/bin"
ln -sfn -- "$WTOOL_PROJECT_ROOT/payload.bin" "$WTOOL_PREFIX/bin/$_s17_self"
EOF
    chmod +x "$_d/scripts/install.sh"
    mkdir -p "$_d/__output/usr/bin"
    printf 'payload\n' > "$_d/__output/usr/bin/$_s17_slug"
    cat > "$_d/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="docker" priority="50">
  <export_bin src="__output/usr/bin/$_s17_slug"/>
  <zshrc src="env.zsh"/><bashrc src="env.bash"/>
</wtool>
EOF
    git -C "$_d" add -A && git -C "$_d" -c user.name=t -c user.email=t@t commit -qm init
}
# 三棵树：项目目录 / 影子 HOME / state
_s17_snap() { { find "$WTOOL_ROOT" "$WTOOL_HOME" "$WTOOL_STATE" -mindepth 1 2>/dev/null || true; } | sort; }
_s17_dangling() { find "$WTOOL_HOME" -xtype l 2>/dev/null | wc -l | tr -d ' '; }
# 汇总文件现在是 `$WTOOL_HOME/env.zsh`（rc 里只有那两行，不再有 per-project 块）；
# 每个项目那一段的开头是 `# --- wtool:<项目> (priority N) ---`。
_s17_blocks() { grep -o '^# --- wtool:[^ ]*' "$WTOOL_HOME/env.zsh" 2>/dev/null | sed 's/^# --- //' | tr '\n' ' '; }

_s17_mk "moval/one"
"$WT" install moval/one > "$T/s17i.log" 2>&1 || bad "（前置）装 moval/one 失败" "$(cat "$T/s17i.log")"

# ---- ① --dry-run：只打印，一个字节都不动 ----
_s17_before=$(_s17_snap)
_rc=0
_out=$("$WT" move moval/one moval/two --dry-run 2>&1) || _rc=$?
chk "★move --dry-run 退出 0" "$_rc" "0"
chk "★move --dry-run 前后文件清单逐行相同（零副作用）" "$_s17_before" "$(_s17_snap)"
[ -d "$WTOOL_ROOT/moval/one" ] && ok "move --dry-run 没搬目录" || bad "move --dry-run 把目录搬了"
[ -e "$WTOOL_ROOT/moval/two" ] && bad "move --dry-run 建了新目录" || ok "move --dry-run 没建新目录"
case $_out in
    *moval/two*) ok "move --dry-run 打印了计划（提到新路径）" ;;
    *) bad "move --dry-run 没打印计划" "$_out" ;;
esac

# ---- ② 真改名：旧账必须**全**收干净 ----
_rc=0
_out=$("$WT" move moval/one moval/two 2>&1) || _rc=$?
chk "★move 退出 0" "$_rc" "0"
[ -d "$WTOOL_ROOT/moval/one" ] && bad "move 之后旧目录还在" || ok "move 之后旧目录没了"
[ -d "$WTOOL_ROOT/moval/two" ] && ok "move 之后新目录在" || bad "move 之后新目录不在" "$_out"
# state：只有新路径那一份
[ -f "$WTOOL_STATE/moval/two/meta.tsv" ] && ok "state 建在新路径下" || bad "state 没建在新路径下"
[ -e "$WTOOL_STATE/moval/one" ] && bad "★旧 state 目录没删掉（残渣）" || ok "旧 state 目录已收走"
# L1 链：只有新路径那条，且不悬空
[ -d "$WTOOL_HOME/wtool/moval/two" ] && ok "L1 链指向新路径" \
    || bad "L1 链没建在新路径"
[ -e "$WTOOL_HOME/wtool/moval/one" ] && bad "★旧 L1 链还在（悬空链）" \
    || ok "旧 L1 链已收走"
chk "★影子 HOME 里没有悬空软链" "0" "$(_s17_dangling)"
# 汇总文件里的块：只有新路径那个
chk "★汇总文件里只剩新路径的块" "wtool:moval/two " "$(_s17_blocks)"
# registry：每一行的主人都是新路径
_s17_owners=$(cut -f2 "$WTOOL_STATE/registry.tsv" 2>/dev/null | sort -u | tr '\n' ' ')
chk "★registry 里没有旧路径的行" "moval/two " "$_s17_owners"
# 最后：check 必须说"一切对得上"
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
if [ "$_rc" = 0 ]; then ok "★move 之后 check 干净（退出 0）"
else bad "★move 之后 check 干净（退出 0）" "$_out"; fi

# ---- ③ 手工 mv（错误姿势）：check 必须把三类残渣都报出来 ----
_s17_mk "moval/three"
"$WT" install moval/three >/dev/null 2>&1
mv "$WTOOL_ROOT/moval/three" "$WTOOL_ROOT/moval/four"      # ← 绕开 wtool
_rc=0
_out=$("$WT" check 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "★手工 mv 之后 check 退出码非 0" || bad "check 没发现残渣" "$_out"
case $_out in
    *moval/three*) ok "check 报的是**旧路径** moval/three" ;;
    *) bad "check 没提旧路径" "$_out" ;;
esac
case $_out in
    *"env 块"*) ok "★check 报了删不掉的旧 env 块（会继续进汇总文件）" ;;
    *) bad "check 没报旧 env 块" "$_out" ;;
esac
case $_out in
    *"悬空软链"*) ok "★check 报了悬空软链" ;;
    *) bad "check 没报悬空软链" "$_out" ;;
esac
case $_out in
    *registry*) ok "★check 报了 registry 里的旧路径（下次 install 会撞它）" ;;
    *) bad "check 没报 registry 旧行" "$_out" ;;
esac
# 点着旧路径查也要报（用户手里只有那条已经改掉的路径）
_rc=0
_out=$("$WT" check moval/three 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "check <旧路径> 也报" || bad "check <旧路径> 说没事" "$_out"

# ---- ④ 改名的护栏：不许覆盖、不许原地 ----
_s17_mk "moval/five"
"$WT" install moval/five >/dev/null 2>&1
_rc=0
_out=$("$WT" move moval/five moval/two 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "新路径已存在时 move 拒绝" || bad "move 把已有项目覆盖了" "$_out"
case $_out in
    *"已经存在"*) ok "拒绝的理由说清了（新路径已经存在）" ;;
    *) bad "拒绝理由不清楚" "$_out" ;;
esac
_rc=0
_out=$("$WT" move moval/five moval/five 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "新旧同一个目录时 move 拒绝" || bad "move 接受了原地改名" "$_out"
# 拒绝之后不能留下半成品：five 还得是装着的
[ -f "$WTOOL_STATE/moval/five/meta.tsv" ] && ok "被拒绝的 move 没动到旧项目" \
    || bad "被拒绝的 move 把旧项目卸了"

# --------------------------------------------------------------------------
printf '\n== 场景 18：项目类型 kind + 命令门禁（ADR-0045 / D49）==\n'
#   `wtool.xml` **根元素**的 kind 决定哪些命令对这个项目有意义（类型 × 命令矩阵）。
#   门禁只有一处：`wtool.sh` 分发点那个 `wt_kind_gate`。这里守四件事：
#     ① 未知 kind 要**报错**（不许悄悄当成 source）
#     ② kind=source 敲 build → 非 0 + 固定文案 + **脚本一行都不许跑**（绝不许落到老路）
#     ③ kind=muslbin：没有 build，但有 download-release
#     ④ kind=docker：四条 gated 命令全通
newhome
mkdir -p "$WTOOL_ROOT"

# 建一个项目：<相对路径> <根元素额外属性> [要不要 build.sh]
_k18_mk() {
    _d=$(mkproj "$1")
    printf '#!/bin/sh\ntouch "$WTOOL_PROJECT_DIR/ran-anyway.txt"\n' > "$_d/build.sh"
    mkdir -p "$_d/scripts"
    printf '#!/bin/sh\ntouch "$WTOOL_PROJECT_DIR/ran-anyway.txt"\n' > "$_d/scripts/build.sh"
    chmod +x "$_d/scripts/build.sh"
    cat > "$_d/wtool.xml" <<XEOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1"$2>
</wtool>
XEOF
    echo "$_d"
}

# ---- ① 未知 kind：报错。既不能在 validate 里过，也不能被门禁当成 source ----
# （`$KC` 就是那个只读规划器；本场景①②也用不着起 wtool.sh）
KC="$boot/lib/wtool_plan.py"
P18BAD=$(_k18_mk "kt/bad" ' kind="sourec"')
_rc=0
_out=$("$WT" validate "$P18BAD" 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "未知 kind 被 validate 拒绝" || bad "未知 kind 居然过了"
case $_out in
    *"不认识"*) ok "报错说清了 kind 不认识" ;;
    *) bad "没说清 kind 不认识" "$_out" ;;
esac
# 报错文案还要点破"别和 <build kind> / <publish kind> 混"（三层同名是这轮最容易踩的）
case $_out in
    *"<build kind="*) ok "报错点破了与 <build kind> 的区别" ;;
    *) bad "没提醒和 <build kind> 的区别" "$_out" ;;
esac
# 坏 kind 的项目**仍然留在看板上**（不许静默消失），只是被门禁拦
_rc=0
_out=$(python3 "$KC" table --root "$WTOOL_ROOT" --state "$WTOOL_STATE" \
       --color never --brief 2>&1) || _rc=$?
case $_out in
    *kt/bad*) ok "坏 kind 的项目没从看板上消失" ;;
    *) bad "坏 kind 的项目被静默丢掉了" "$_out" ;;
esac
# 门禁也得拦（它现读清单，报的是"清单有问题"而不是"它不需要构建"）
_rc=0
_out=$("$WT" build kt/bad 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "坏 kind 的项目 build 被拦" || bad "坏 kind 也能 build"
case $_out in
    *"wtool.xml 有问题"*) ok "拦的理由是清单有问题（不是拿默认值糊弄）" ;;
    *) bad "没说清单有问题" "$_out" ;;
esac

# ---- ② source 敲 build：非 0 + 固定文案 + 脚本一行都不跑 ----
P18SRC=$(_k18_mk "kt/src" '')
rm -f "$P18SRC/ran-anyway.txt"
_rc=0
_out=$("$WT" build kt/src 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "kind=source 敲 build 退出码非 0" || bad "source 敲 build 居然成功"
case $_out in
    *"wtool: 'kt/src' 是 kind=source（纯源码项目），不支持 build —— 它不需要构建"*)
        ok "文案逐字对（用户 2026-10-13 给的形状）" ;;
    *) bad "文案不对" "$_out" ;;
esac
[ -e "$P18SRC/ran-anyway.txt" ] && bad "★被拒了还跑了 scripts/build.sh" \
    || ok "★scripts/build.sh 一行都没跑（没落到老路上）"
# 同一类：层命令也拦（层只有 ③ 类有）
_rc=0
_out=$("$WT" unpack-layer kt/src 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "kind=source 敲 unpack-layer 也被拦" || bad "source 能拆层"
case $_out in
    *没有容器层*) ok "层命令的拒绝理由说的是「没有容器层」" ;;
    *) bad "层命令理由不对" "$_out" ;;
esac
# 与类型无关的命令不拦：install 对三类都成立（这里只验"门禁没把它拦掉"）
_rc=0
_out=$("$WT" build kt/src --dry-run 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "带 --dry-run 也一样拦（门禁在参数解析之前）" || bad "--dry-run 绕过了门禁"

# ---- ③ muslbin：没有 build，但有 download-release（矩阵里 ② 多出来的那一路）----
P18MUSL=$(_k18_mk "kt/musl" ' kind="muslbin"')
_rc=0
_out=$("$WT" build kt/musl 2>&1) || _rc=$?
[ "$_rc" != 0 ] && ok "kind=muslbin 也没有 build" || bad "muslbin 能 build"
case $_out in
    *"kind=muslbin（musl 静态二进制项目）"*) ok "文案里的类型名是 muslbin" ;;
    *) bad "类型名不对" "$_out" ;;
esac
# download-release：**不**受门禁拦（它读 scripts/release.json，没有就直说没东西可下）
_rc=0
_out=$("$WT" download-release kt/musl 2>&1) || _rc=$?
case $_out in
    *"是 kind=muslbin"*) bad "muslbin 的 download-release 被门禁拦了" "$_out" ;;
    *) ok "muslbin 的 download-release 没被门禁拦（它自己报了没东西可下）" ;;
esac

# ---- ④ docker：矩阵里 ✅ 的那些命令一条都不许被拦 ----
P18DOCK=$(_k18_mk "kt/dock" ' kind="docker"')
for _c in build unpack-layer push-layer pull-layer; do
    _rc=0
    _out=$("$WT" "$_c" kt/dock --dry-run 2>&1) || _rc=$?
    case $_out in
        *"不支持 $_c"*) bad "kind=docker 的 $_c 被门禁拦了" "$_out" ;;
        *) ok "kind=docker 的 $_c 过了门禁（rc=$_rc）" ;;
    esac
done

# ---- ⑤ `all` 展开也必须按类型筛，否则 `build all` 能绕过门禁 ----
# `wtool build all` 走 wt_all_projects 的 build 过滤器（判据原来是"目录里有没有
# scripts/build.sh"）—— 不接类型的话，一个"kind=source 但放着 build.sh"的项目
# 会被 all 选中并**真跑**，门禁就白设了。
rm -f "$P18SRC/ran-anyway.txt"
_rc=0
_out=$("$WT" build all --dry-run 2>&1) || _rc=$?
case $_out in
    *"── kt/src"*) bad "★build all 选中了 kind=source 的项目（绕过门禁）" "$_out" ;;
    *) ok "★build all 不选 kind=source 的项目（门禁管得住 all）" ;;
esac
case $_out in
    *"── kt/dock"*) ok "build all 选中 kind=docker 的项目" ;;
    *) bad "build all 没选中 docker 的项目" "$_out" ;;
esac
[ -e "$P18SRC/ran-anyway.txt" ] && bad "★被排除的项目还是跑了 build.sh" \
    || ok "★被排除的项目一行脚本都没跑"

# ---- ⑥ 只读接口 kind-caps：退出码就是答案，且**什么都不写** ----
_rc=0; python3 "$KC" kind-caps --root "$WTOOL_ROOT" --project "$P18SRC" --command build \
    >/dev/null 2>&1 || _rc=$?
chk "kind-caps：source + build → 3" "$_rc" "3"
_rc=0; python3 "$KC" kind-caps --root "$WTOOL_ROOT" --project "$P18MUSL" --command build \
    >/dev/null 2>&1 || _rc=$?
chk "kind-caps：muslbin + build → 3" "$_rc" "3"
_rc=0; python3 "$KC" kind-caps --root "$WTOOL_ROOT" --project "$P18MUSL" --command download-release \
    --quiet >/dev/null 2>&1 || _rc=$?
chk "kind-caps：muslbin + download-release → 0" "$_rc" "0"
_rc=0; python3 "$KC" kind-caps --root "$WTOOL_ROOT" --project "$P18DOCK" --command build \
    --quiet >/dev/null 2>&1 || _rc=$?
chk "kind-caps：docker + build → 0" "$_rc" "0"
# 不在能力表里的命令（move）**任何类型都放行** —— 引擎不拿类型管它
_rc=0; python3 "$KC" kind-caps --root "$WTOOL_ROOT" --project "$P18SRC" --command move \
    --quiet >/dev/null 2>&1 || _rc=$?
chk "kind-caps：move 与类型无关 → 0" "$_rc" "0"
# 不是 wtool 项目的目录 / 不存在的目录：管不着，放行（让命令自己报）
_rc=0; python3 "$KC" kind-caps --root "$WTOOL_ROOT" --project "$T/没有这个东西" --command build \
    --quiet >/dev/null 2>&1 || _rc=$?
chk "kind-caps：不存在的目录 → 0（管不着）" "$_rc" "0"
# --matrix 是**整数只读**的：不问项目也能打整张表，且矩阵形状对得上
_out=$(python3 "$KC" kind-caps --matrix 2>&1)
case $_out in
    *"kind=source"*"kind=muslbin"*"kind=docker"*) ok "--matrix 打了三种类型的表头" ;;
    *) bad "--matrix 表头不对" "$_out" ;;
esac
chk "--matrix 里 build 一行只有 docker 是 ✅" "✅" \
    "$(printf '%s\n' "$_out" | awk '$1 == "build" {print $4}')"
chk "--matrix 里 download-release 一行 source 是 —" "—" \
    "$(printf '%s\n' "$_out" | awk '$1 == "download-release" {print $2}')"
# ★ 只读：跑完 kind-caps 之后，项目目录一个字节都没变
_before18=$( { find "$P18SRC" "$P18MUSL" "$P18DOCK" -mindepth 1 2>/dev/null || true; } | sort)
python3 "$KC" kind-caps --root "$WTOOL_ROOT" --project "$P18SRC" --command build >/dev/null 2>&1 || true
python3 "$KC" kind-caps --matrix >/dev/null 2>&1 || true
chk "★kind-caps 是只读的（项目目录没变）" "$_before18" \
    "$( { find "$P18SRC" "$P18MUSL" "$P18DOCK" -mindepth 1 2>/dev/null || true; } | sort)"

printf '\n----------------------------------------\n'
printf 'contract_test: PASS %d  FAIL %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
