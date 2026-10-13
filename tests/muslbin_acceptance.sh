#!/bin/sh
# muslbin_acceptance.sh —— **容器里真下载、真解包、真装**的验收（ADR-0045 第 ⑦.2 块）
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
#
# 验的是三件**真事**（都联网，走上游 GitHub release）：
#   ① 一个 `.tar.gz` 资产（bat，成员带一层目录前缀）
#   ② 一个 `.zip` 资产（procs，成员在归档根上）
#   ③ 一个带 `<generate>` 的项目（fzf：`fzf --zsh` / `fzf --bash` 在 install 时生成）
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
cp -a /wtool/bootstrap "$WORK/wtool-base-tools"
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
echo "=== 1. 从真工作区拷三个 ② 类项目（bat / procs / fzf）==="
for p in bat procs fzf; do
    mkdir -p "$WTOOL_ROOT/tools/musl-bins/$p"
    cp -a /wtool/tools/musl-bins/$p/. "$WTOOL_ROOT/tools/musl-bins/$p/"
done
ls -1 "$WTOOL_ROOT/tools/musl-bins"
git -C "$WTOOL_ROOT" init -q
git -C "$WTOOL_ROOT" add -A
git -C "$WTOOL_ROOT" commit -qm "容器验收：三个 ② 类项目"

e2e_one() {   # <工具名> <--version 输出里必须出现的那一段>
    _t=$1; _want=$2
    _pid="tools/musl-bins/$_t"
    echo
    echo "──────────────────────────────────────────────"
    echo "### $_pid"
    echo "--- ① wtool download-release $_pid"
    $WT download-release "$_pid"
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
echo "########## D. sha256 不匹配：必须非 0、且不留半成品 ##########"
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
echo "########## E. 三个工具一起再 check 一次 ##########"
$WT check && echo "✅ 一切对得上（声明 / 日志 / 磁盘）"
echo
echo "全部通过。"
