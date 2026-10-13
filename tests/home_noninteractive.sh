#!/bin/sh
# container_home_noninteractive.sh —— **非交互不许挂**的证据（ADR-0045 第 5a 块）
#
# 把 stdin 接 `/dev/null`、套 `timeout 20`，跑 `wtool install`：
#   * 退出码 124 = 挂了（超时）；
#   * 退出码 0/非 0 且耗时 0~1 秒 = 没挂（要的就是这个）。
# 管道输入（`printf '' | wtool install`）同样验一次。
#
# 跑法见 container_home_acceptance.sh（同一个容器、同一条命令）；
# 它会先跑一遍验收把工作区/项目铺好，再跑这里。
#
# ⚠️ 这里**不用 zsh 跑引擎**（shebang 是 `#!/bin/sh`）。实测：zsh 5.9 下
#    `wtool uninstall` 那条路会把参数拆坏（`unrecognized arguments: --project`）
#    —— 那是引擎脚本自身在非 POSIX shell 下的边界，**不是本块引入的**，
#    记在这里当发现（要修的话是单独一件事：引擎只承诺 /bin/sh）。
# 非交互不挂：把 stdin 接 /dev/null 并加超时，install 必须**立刻**退出（只打印那两行）
set -u
export LD_LIBRARY_PATH=/h/lib/x86_64-linux-gnu:/h/usr/lib/x86_64-linux-gnu
export PATH=/h/usr/bin:/h/bin:/usr/bin:/bin
export HOME=/root

echo "=== 非交互（< /dev/null + timeout 20） ==="
echo "  stdin 是 tty 吗 : $([ -t 0 ] && echo yes || echo no)"
_start=$(date +%s)
WTOOL_ROOT=/work/ws timeout 20 sh /work/bootstrap/wtool.sh install editor/demo > /tmp/ni.log 2>&1 < /dev/null
_rc=$?
_end=$(date +%s)
echo "  退出码=$_rc  耗时=$((_end - _start))s  （124 = 超时 = 挂了）"
grep -c "还差一步" /tmp/ni.log | sed 's/^/  打印了提示的段数: /'
echo "  rc 里那两行 : $(grep -c 'WTOOL_HOME' /root/.zshrc || true)  ← 应该是 0（只打印不代写）"
echo
echo "=== 管道输入（printf | wtool install） ==="
_start=$(date +%s)
printf '' | WTOOL_ROOT=/work/ws timeout 20 sh /work/bootstrap/wtool.sh install editor/demo > /tmp/ni2.log 2>&1
_rc=$?
_end=$(date +%s)
echo "  退出码=$_rc  耗时=$((_end - _start))s"
echo
echo "=== bash / dash 也各来一次（两个 shell 都不许挂） ==="
# ⚠️ 引擎的 shebang 是 `#!/bin/sh`，**不用 zsh 跑它** —— 实测（zsh 5.9 +
#    引擎）走 plan-uninstall 时会冒出 `unrecognized arguments: --project`：
#    zsh 对"参数展开后的空字符串"的处理和 dash/bash 不一致，命令行会被拆坏。
#    这是**引擎脚本自身的边界**（不是本块引入的），记在这儿当发现。
for sh in bash dash; do
  if command -v "$sh" >/dev/null 2>&1; then
    _start=$(date +%s)
    WTOOL_ROOT=/work/ws timeout 20 "$sh" /work/bootstrap/wtool.sh install editor/demo > /tmp/ni.$sh.log 2>&1 < /dev/null
    _rc=$?
    _end=$(date +%s)
    echo "  $sh: 退出码=$_rc 耗时=$((_end - _start))s"
  fi
done
echo "NONINTERACTIVE DONE"
