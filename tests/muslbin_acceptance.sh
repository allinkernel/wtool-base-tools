#!/bin/sh
# muslbin_acceptance.sh —— **容器里真下载、真解包、真装**的验收
# （ADR-0045 第 ⑦.2 块建的，第 ⑦.3 块加了 hook 类与 B 档工具）
#
# 怎么跑（**宿主一个字节都不碰**；容器用完即弃；**不装 apt** —— 这台机器上 apt 走代理
# 极慢，所以 python3 / git / curl / sha256sum 全用宿主挂进来的，见下面那段 PATH）：
#
#   docker run --rm --network=host -v /:/h:ro -v ~/self/wtool:/wtool:ro \
#     -v ~/self/wtool/bootstrap/tests:/wtc:ro \
#     ubuntu:24.04 bash -c 'sh /wtc/muslbin_acceptance.sh'
#
#   ⚠️ `--network=host` 是**必须**的：容器里 127.0.0.1 是容器自己，而宿主代理在
#      http://127.0.0.1:7897 —— 不共享网络命名空间就一个字节都下不来。
#      ⚠️ 工作区是只读挂载，所以脚本把项目**拷**进 /work 再动。
#   ‼️ **别和别的下载任务同时跑**：引擎的 `wt_dl_one` 带 `--speed-limit 4096
#      --speed-time 60`（代理"慢慢磨"时要自己判失败，不挂死），宿主那边正在下
#      几十 MB 时这里会被饿到 4 KiB/s 以下 → curl 主动失败 → download-release 报
#      "直链和 api.github.com 两条路都失败"。**那不是引擎坏了**（第 ⑦.3 块第一次
#      跑就撞上了），等带宽空出来重跑即可。
#
# 验的是这些**真事**（都联网，走上游 GitHub release）：
#   ① 一个 `.tar.gz` 资产（bat，成员带一层目录前缀）
#   ② 一个 `.zip` 资产（procs，成员在归档根上）
#   ③ 一个带 `<generate>` 的 ③ 类老朋友（fzf：`fzf --zsh` / `fzf --bash`）
#   ④ **hook 类**（第 ⑦.3 块）：zoxide / direnv —— `<generate>` 出各自的 shell 集成，
#      **zsh 与 bash 两份都验**（source 完在**交互** shell 里函数真的注册了）
#   ⑤ **B 档纯二进制**（第 ⑦.3 块）：rclone（zip）/ watchexec（`.tar.xz`，新格式）/
#      qsv（56 MB 的 zip，最慢，放最后）
# 走完 download-release → unpack-release → install → `<工具> --version`，再验：
#   · sha256 不匹配那条路**真的**非 0，而且 `__release/` 里不留半成品
#   · `<generate>` 的产物在 `__output/` 下、内容非空、`uninstall` 之后消失
set -eu

# 容器里不装任何东西：宿主工具通过 `-v /:/h:ro` 挂进来（照 home_acceptance.sh 的做法）
export LD_LIBRARY_PATH=/h/lib/x86_64-linux-gnu:/h/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}
export PATH=/h/usr/bin:/h/bin:/usr/bin:/bin
export GIT_TEMPLATE_DIR=/h/usr/share/git-core/templates
export GIT_EXEC_PATH=/h/usr/lib/git-core
# 宿主代理（`--network=host` 下 127.0.0.1 才是宿主）
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897
export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
# ‼️ **CA 证书也要从宿主接进来**：基础镜像里没有 ca-certificates，而 `curl` 是宿主的
#    （挂在 /h/usr/bin）—— 它默认去 `/etc/ssl/certs/ca-certificates.crt` 找根证书，
#    找不到就报 "error setting certificate file"，表现为 **HTTP 000 / 一个字节都下不来**。
#    症状看着像"网络不通/代理坏了"，实际是证书路径的事（实测踩过）。
if [ -d /h/etc/ssl/certs ] && [ ! -e /etc/ssl/certs ]; then
    mkdir -p /etc/ssl
    ln -sfn /h/etc/ssl/certs /etc/ssl/certs
fi
# ‼️ **zsh 的模块**也要接进来：zsh 是按**编译进去的路径**找 `zle` / `parameter` /
#    `datetime` 这些 .so 的（宿主那份是 `/usr/lib/x86_64-linux-gnu/zsh/5.9/zsh/`），
#    容器里那个路径不存在 → `zle` / `bindkey` / `add-zsh-hook` 全成
#    "command not found"（实测：`zle -l` 报 cannot open shared object file）。
#    **hook 类的 shell 集成恰恰靠它们**（zoxide/navi 绑键、atuin/direnv 挂钩子），
#    不补这条软链，验出来的就不是用户机器上的那个行为。照上面 CA 证书同一招。
if [ -d /h/usr/lib/x86_64-linux-gnu/zsh ] && [ ! -e /usr/lib/x86_64-linux-gnu/zsh ]; then
    mkdir -p /usr/lib/x86_64-linux-gnu
    ln -sfn /h/usr/lib/x86_64-linux-gnu/zsh /usr/lib/x86_64-linux-gnu/zsh
fi
# ‼️ 还有 **zsh 的函数目录**：`add-zsh-hook` 是 autoload 出来的（不是模块），
#    它住在 `/usr/share/zsh/functions/Misc/`。容器里没有 zsh，于是
#    `add-zsh-hook: function definition file not found` —— 症状是"钩子函数定义了但
#    没挂上去"（atuin / direnv / starship 都走它），只看函数名会以为一切正常。
if [ -d /h/usr/share/zsh ] && [ ! -e /usr/share/zsh ]; then
    ln -sfn /h/usr/share/zsh /usr/share/zsh
fi
# git 要有个身份才能 commit（假工作区要建成 git 仓库）
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

echo "=== 0. 环境 ==="
echo "镜像    : $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "python3 : $(python3 --version 2>&1)"
echo "curl    : $(curl --version 2>&1 | head -1)"
echo "代理    : $http_proxy"

WORK=/work; rm -rf "$WORK"; mkdir -p "$WORK"
# 引擎：工作区是只读挂载 → 拷一份出来当"满血工作区"
# ‼️ **过渡窗口**（2026-10-13）：本地目录可能还叫 `bootstrap/`，也可能已经改成
#    `wtool-base-tools/`（改名是用户的一次性切换）—— 两个名字都认。
_eng_src=/wtool/wtool-base-tools
[ -d "$_eng_src" ] || _eng_src=/wtool/bootstrap
[ -d "$_eng_src" ] || { echo "找不到引擎目录（/wtool/wtool-base-tools 或 /wtool/bootstrap）" >&2; exit 1; }
echo "  引擎目录: $_eng_src"
cp -a "$_eng_src" "$WORK/wtool-base-tools"
rm -rf "$WORK/wtool-base-tools/lib/__pycache__" "$WORK/wtool-base-tools/.git"
BOOT="$WORK/wtool-base-tools"
WT="sh $BOOT/wtool.sh"

# 假 HOME + 假工作区（**绝不碰真 $HOME**）
export HOME="$WORK/home"
export WTOOL_HOME="$WORK/home/.wtool"
export WTOOL_STATE="$WORK/home/.wtool/var"
export WTOOL_MANAGED_HOME="$WORK/home"
export WTOOL_LOG_ROOT="$WORK/home/.wtool-logs"
export WTOOL_ROOT="$WORK/ws"
mkdir -p "$WTOOL_HOME" "$WTOOL_ROOT" "$WTOOL_LOG_ROOT"
printf '# 用户自己的 zshrc\nsetopt auto_cd\n' > "$HOME/.zshrc"

echo
echo "=== 1. 从真工作区拷 ② 类项目（A 档 + 第 ⑦.3 块的 hook 类 / B 档）==="
# 默认七个；`WTOOL_ACC_BIG=1` 时带上 qsv（56 MB，最慢的一节，见下面 E 段）
PROJS="bat procs fzf zoxide direnv atuin starship navi rclone watchexec"
if [ "${WTOOL_ACC_BIG:-0}" = 1 ]; then PROJS="$PROJS qsv"; fi
for p in $PROJS; do
    # 缺一个就**当场说清缺谁**再停：静默少拷一个的后果是后面某节"工具不存在"，
    # 看起来像引擎坏了（第 ⑦.3 块第一次跑就是这么挂的：qsv 还没加进来）
    [ -d "/wtool/tools/musl-bins/$p" ] || {
        echo "❌ 工作区里没有 /wtool/tools/musl-bins/$p/ —— 项目没加进来？"; exit 1; }
    mkdir -p "$WTOOL_ROOT/tools/musl-bins/$p"
    cp -a /wtool/tools/musl-bins/$p/. "$WTOOL_ROOT/tools/musl-bins/$p/"
done
ls -1 "$WTOOL_ROOT/tools/musl-bins"
git -C "$WTOOL_ROOT" init -q
git -C "$WTOOL_ROOT" add -A
git -C "$WTOOL_ROOT" commit -qm "容器验收：② 类项目（含 hook 类与 B 档）"

# 下载重试（**只给手动验收脚本用**）：代理会"慢慢磨"，而引擎的 `wt_dl_one` 带
# `--speed-limit 4096 --speed-time 60`（宁可失败也不挂死）—— 于是一次网络抖动就会
# 让整份验收从头再来。这里给它三次机会；`curl -C -` 会**接着下**（.part 续传），
# 所以重试不是重下。三次都失败才算失败（每次的输出照样打出来，不吞）。
dl_retry() {   # <项目 id>
    _n=0
    while :; do
        _n=$((_n + 1))
        if $WT download-release "$1"; then return 0; fi
        if [ "$_n" -ge 3 ]; then echo "    ❌ 三次都没下来"; exit 1; fi
        echo "    （第 $_n 次没下来，等 10 秒重试；.part 会续传）"
        sleep 10
    done
}

e2e_one() {   # <工具名> <--version 输出里必须出现的那一段>
    _t=$1; _want=$2
    _pid="tools/musl-bins/$_t"
    echo
    echo "──────────────────────────────────────────────"
    echo "### $_pid"
    echo "--- ① wtool download-release $_pid"
    dl_retry "$_pid"
    echo "--- __release/ 里有什么"
    ls -l "$WTOOL_ROOT/$_pid/__release/" | sed 's/^/    /'
    echo "--- ② wtool unpack-release $_pid"
    $WT unpack-release "$_pid"
    echo "--- __output/ 里有什么"
    find "$WTOOL_ROOT/$_pid/__output" -mindepth 1 -printf '    %y %M %p\n' | sort
    echo "--- ③ wtool install $_pid"
    $WT install "$_pid"
    echo "--- ④ $WTOOL_HOME/usr/bin/$_t --version"
    _v=$("$WTOOL_HOME/usr/bin/$_t" --version 2>&1 | head -1)
    echo "    $_v"
    # 期望值用"必须出现的子串"：各工具的 --version 格式不统一
    # （fzf 只打版本号、procs 打一堆环境信息），盯着前缀会冤枉好的
    case $_v in
        *"$_want"*) echo "    ✅ 跑起来了" ;;
        *)          echo "    ❌ 输出里没有 [$_want]"; exit 1 ;;
    esac
    echo "--- ⑤ check"
    $WT check >/dev/null && echo "    ✅ check 干净"
}

echo
echo "########## A. .tar.gz 资产：bat ##########"
e2e_one bat "bat "

echo
echo "########## B. .zip 资产：procs ##########"
e2e_one procs "procs "

echo
echo "########## C. 带 <generate> 的：fzf ##########"
e2e_one fzf "0.74.5"
FZ="$WTOOL_ROOT/tools/musl-bins/fzf"
echo "--- <generate> 的产物（install 时生成的）"
ls -l "$FZ/__output/fzf.zsh" "$FZ/__output/fzf.bash" | sed 's/^/    /'
echo "--- 生成物的头两行（zsh）"
head -2 "$FZ/__output/fzf.zsh" | sed 's/^/    /'
echo "--- 账本里的 generate 行"
grep '^generate' "$WTOOL_STATE/tools/musl-bins/fzf/journal.tsv" | cut -c1-120 | sed 's/^/    /'
echo "--- source 项目的 env.zsh，看补全/按键绑定有没有真的进到这个 shell 里"
# 判据取"fzf 相关的别名 + 函数 ≥ 1"：fzf 各个版本的 `--zsh` 输出不一样
# （老版定义 fzf-file-widget 这类函数，新版还会加别名），盯着某一个名字会过时。
# 有没有 zsh 不影响别的结论 —— 生成物本身下面照样验（非空 + 进账 + 卸载删掉）。
zsh -n "$FZ/__output/fzf.zsh" && echo "    ✅ 生成物是语法正确的 zsh（zsh -n 通过）"
cat > "$WORK/fzf-check.zsh" <<'ZEOF'
. "$WTOOL_HOME/wtool/tools/musl-bins/fzf/env.zsh" >/dev/null 2>&1 || true
_a=$(alias 2>/dev/null | grep -c "^fzf" || true)
_f=$(typeset +f 2>/dev/null | grep -c "^fzf" || true)
echo "    这个 shell 里 fzf 相关的别名 $_a 个 / 函数 $_f 个"
if [ $((_a + _f)) -gt 0 ]; then
    echo "    ✅ 生成物被 source 进来了"
else
    echo "    ❌ 生成物没被 source 进来"
    exit 1
fi
ZEOF
if command -v zsh >/dev/null 2>&1; then
    # ‼️ 必须用 **-i**（交互式）：fzf 的 `--zsh` 输出把按键绑定/补全包在
    #    `if [[ $- == *i* ]]` 里 —— 非交互的 `zsh -c` 一个定义都不会注册，
    #    那不是"生成物坏了"，是**没在用户真正用它的那个环境里试**
    #    （实测踩过：非交互下别名 0 个 / 函数 0 个，差点误判成没 source 进来）。
    if ! env -i HOME="$HOME" PATH="$PATH" WTOOL_HOME="$WTOOL_HOME" \
             LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" zsh -f -i "$WORK/fzf-check.zsh" 2>/dev/null; then
        echo "    ❌ source env.zsh 之后 fzf 的定义没进来"; exit 1
    fi
else
    echo "    （容器里没有 zsh，跳过这一条）"
fi
chk=$(grep -c . "$FZ/__output/fzf.zsh" || true)
echo "    生成物 fzf.zsh 有 ${chk:-0} 行非空内容"
[ "${chk:-0}" -gt 0 ] || { echo "    ❌ 生成物是空的"; exit 1; }
echo "--- uninstall：生成物必须消失（二进制不归 <generate> 管，要留着）"
$WT uninstall "$FZ" >/dev/null
[ ! -e "$FZ/__output/fzf.zsh" ] && [ ! -e "$FZ/__output/fzf.bash" ] \
    && echo "    ✅ 两个生成物都被删掉了" \
    || { echo "    ❌ 生成物没删干净"; exit 1; }
[ -x "$FZ/__output/usr/bin/fzf" ] && echo "    ✅ 二进制还在（它不归 <generate> 管）"
"$WTOOL_HOME/usr/bin/fzf" --version >/dev/null 2>&1 \
    && { echo "    ❌ L2 链没撤掉"; exit 1; } || echo "    ✅ L2 链撤掉了"

echo
echo "########## D. hook 类（第 ⑦.3 块）：zoxide / direnv / atuin / starship / navi ##########"
# 判据是"source 完 env 之后，**这个 shell 里**那个函数真的注册了"：
#   · zsh 用 `zsh -f -i`（**-i 是关键**：zoxide/direnv 的 init 输出把注册包在
#     交互式判断里，非交互的 `zsh -c` 一个定义都不会有 —— 不是生成物坏了，
#     是没在用户真正用它的环境里试。fzf 那节已经踩过一次）
#   · bash 用 `bash --noprofile --norc -i`
hook_one() {   # <工具> <--version 里必须出现的子串> <zsh 里该出现的函数> <bash 里该出现的函数>
    _t=$1; _want=$2; _fz=$3; _fb=$4
    _pid="tools/musl-bins/$_t"
    echo
    echo "──────────────────────────────────────────────"
    echo "### $_pid"
    echo "--- ① download-release → ② unpack-release → ③ install"
    dl_retry "$_pid"
    $WT unpack-release   "$_pid"
    $WT install          "$_pid"
    _d="$WTOOL_ROOT/$_pid"
    echo "--- ④ $WTOOL_HOME/usr/bin/$_t --version"
    _v=$("$WTOOL_HOME/usr/bin/$_t" --version 2>&1 | head -1)
    echo "    $_v"
    case $_v in
        *"$_want"*) echo "    ✅ 跑起来了" ;;
        *)          echo "    ❌ 输出里没有 [$_want]"; exit 1 ;;
    esac
    echo "--- ⑤ <generate> 的两份产物（install 时生成的）"
    ls -l "$_d/__output/$_t.zsh" "$_d/__output/$_t.bash" | sed 's/^/    /'
    for _s in zsh bash; do
        _n=$(grep -c . "$_d/__output/$_t.$_s" || true)
        [ "${_n:-0}" -gt 0 ] || { echo "    ❌ $_t.$_s 是空的"; exit 1; }
        echo "    $_t.$_s 有 ${_n} 行非空内容，头一行：$(head -1 "$_d/__output/$_t.$_s")"
    done
    echo "--- 账本里的 generate 行"
    grep '^generate' "$WTOOL_STATE/$_pid/journal.tsv" | cut -c1-140 | sed 's/^/    /'
    echo "--- ⑥ zsh -f -i 里 source env.zsh 之后函数注册了吗（要 [$_fz]）"
    cat > "$WORK/hook-$_t.zsh" <<ZEOF
. "\$WTOOL_HOME/wtool/tools/musl-bins/$_t/env.zsh"
if typeset -f $_fz >/dev/null 2>&1; then
    echo "    ✅ 函数 $_fz 已注册"
else
    echo "    ❌ 函数 $_fz 没注册"; typeset +f | head -20 | sed 's/^/       /'; exit 1
fi
ZEOF
    env -i HOME="$HOME" PATH="$WTOOL_HOME/usr/bin:$PATH" WTOOL_HOME="$WTOOL_HOME" \
        LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
        zsh -f -i "$WORK/hook-$_t.zsh"
    echo "--- ⑦ bash --noprofile --norc -i 里 source env.bash 之后函数注册了吗（要 [$_fb]）"
    cat > "$WORK/hook-$_t.bash" <<BEOF
. "\$WTOOL_HOME/wtool/tools/musl-bins/$_t/env.bash"
if declare -F $_fb >/dev/null 2>&1; then
    echo "    ✅ 函数 $_fb 已注册"
else
    echo "    ❌ 函数 $_fb 没注册"; declare -F | head -20 | sed 's/^/       /'; exit 1
fi
BEOF
    env -i HOME="$HOME" PATH="$WTOOL_HOME/usr/bin:$PATH" WTOOL_HOME="$WTOOL_HOME" \
        LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
        bash --noprofile --norc -i "$WORK/hook-$_t.bash"
    echo "--- ⑧ uninstall：两份生成物都要消失，L2 链也要撤掉"
    $WT uninstall "$_pid" >/dev/null
    [ ! -e "$_d/__output/$_t.zsh" ] && [ ! -e "$_d/__output/$_t.bash" ] \
        && echo "    ✅ 两份生成物都被删掉了" \
        || { echo "    ❌ 生成物没删干净"; exit 1; }
    [ -x "$_d/__output/usr/bin/$_t" ] && echo "    ✅ 二进制还在（它不归 <generate> 管）"
    "$WTOOL_HOME/usr/bin/$_t" --version >/dev/null 2>&1 \
        && { echo "    ❌ L2 链没撤掉"; exit 1; } || echo "    ✅ L2 链撤掉了"
}

hook_one zoxide "zoxide " "__zoxide_z" "__zoxide_z"
# ⚠️ direnv 的 `--version` **只打版本号**（`2.38.2`），不带命令名 —— 拿 "direnv " 去比会冤枉好的
hook_one direnv "2.38.2" "_direnv_hook" "_direnv_hook"
# atuin：zsh 侧那个钩子叫 `_atuin_preexec`（单下划线），bash 侧是 `__atuin_preexec`
#        （双下划线，靠 bash-preexec 挂进 `preexec_functions`）—— **两边名字不一样**，
#        所以 hook_one 才要四个参数（实测出来的，不是猜的）
hook_one atuin "atuin " "_atuin_preexec" "__atuin_preexec"
# starship：zsh 侧 `prompt_starship_precmd`，bash 侧 `starship_precmd`（也差一个前缀）。
#        ⚠️ 它的 `init bash` 输出只是**一行 eval**（`eval -- "$(starship init bash
#        --print-full-init)"`），所以那个绝对路径是**安装时**写进去的 —— 正好也验了
#        "生成物用的是刚链上的那份二进制"。
hook_one starship "starship " "prompt_starship_precmd" "starship_precmd"
# navi：`navi widget <shell>`（不是 `init`），两边都叫 `_navi_widget`
hook_one navi "navi " "_navi_widget" "_navi_widget"

echo
echo "########## E. B 档纯二进制（第 ⑦.3 块）：rclone / watchexec / qsv ##########"
# rclone  —— 32 MB 的 .zip（Go 静态）
# watchexec—— `.tar.xz`：**第 ⑦.3 块刚给引擎加的那种格式**（以前会报"只认四种"）
e2e_one rclone "rclone "
e2e_one watchexec "watchexec "
# ⚠️ 这条断言必须放在 `e2e_one watchexec` **之后** —— 它看的是 `__release/` 里
#    真下下来的东西（第一次写在了前面，于是必然报"没有 __release/"、还让人以为
#    是格式不支持。顺序错了，结论就反了）。
WX="$WTOOL_ROOT/tools/musl-bins/watchexec"
echo "--- watchexec 的资产就是 .tar.xz（这条证明新格式走的是真链路）"
ls -l "$WX/__release/" | sed 's/^/    /'
case "$(ls "$WX/__release/")" in
    *.tar.xz) echo "    ✅ 下下来的是 .tar.xz，且解包成功（前面 ② 那步没报错）" ;;
    *)        echo "    ❌ 资产不是 .tar.xz"; exit 1 ;;
esac
# qsv —— 56 MB 的 .zip（包里有好几个成员，只取 qsv 本体）。
# ‼️ 它是这个脚本里**最慢**的一节（56 MB 走代理），所以默认**跳过**；
#    要连它一起验：`docker run … -e WTOOL_ACC_BIG=1 bash -c 'sh /wtc/muslbin_acceptance.sh'`。
if [ "${WTOOL_ACC_BIG:-0}" = 1 ]; then
    e2e_one qsv "qsv "
else
    echo
    echo "（跳过 qsv：56 MB，太慢。加 -e WTOOL_ACC_BIG=1 就带上它）"
fi

echo
echo "########## F. sha256 不匹配：必须非 0、且不留半成品 ##########"
BAD="$WTOOL_ROOT/tools/musl-bins/batsha"
mkdir -p "$BAD"
cp -a "$WTOOL_ROOT/tools/musl-bins/bat/." "$BAD/"
# ‼️ 把 A 段下好的那份 **先清掉**：不清的话下面"不留半成品"的断言测的是
#    A 段留下来的好文件，而不是这次失败下载的结果（实测踩过：假红一次）。
rm -rf "$BAD/__release"
# 把清单里的 sha256 改坏一个字符（**只改这一处**：这正是"上游重打了 tag"的形状）
python3 - "$BAD/wtool.xml" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
def flip(m):
    s = m.group(1)
    return 'sha256="%s"' % (("0" if s[0] != "0" else "1") + s[1:])
t2 = re.sub(r'sha256="([0-9a-f]{64})"', flip, t, count=1)
assert t2 != t, "没找到 sha256="
open(p, "w", encoding="utf-8").write(t2)
PY
git -C "$WTOOL_ROOT" add -A && git -C "$WTOOL_ROOT" commit -qm "坏 sha 的对照项目"
set +e
$WT download-release tools/musl-bins/batsha
_rc=$?
set -e
echo "    退出码 = $_rc"
[ "$_rc" != 0 ] || { echo "    ❌ sha256 不匹配却成功了"; exit 1; }
_left=$(ls -A "$BAD/__release" 2>/dev/null || true)
if [ -n "$_left" ]; then
    echo "    ❌ __release/ 里留了东西："$_left; exit 1
fi
echo "    ✅ 非 0，且 __release/ 里没有半成品（连 .part 都没有）"

echo
echo "########## G. 所有装过的工具一起再 check 一次 ##########"
$WT check && echo "✅ 一切对得上（声明 / 日志 / 磁盘）"
echo
echo "全部通过。"
