#!/bin/bash
# pack_all_docker.sh —— **在三个发行版容器里各打一份整机包**（用户点名"在 docker 里打"）
#
# 用法：
#     bash pack_all_docker.sh <round 名字> [<发行版>...]
#     例：bash pack_all_docker.sh run1
#
# 每个发行版一个容器（`wtool/pack-ubuntu<版本>`：发行版本体 + python3 + git），
# **工作区挂在宿主同名绝对路径**上（`var/<项目>/meta.tsv` 的 project_root、L1 的
# target 列都是这个绝对路径 —— 用别的路径打出来的包会跟宿主上打的不是同一份）。
# 临时 `$WTOOL_HOME` 在容器的 `$TMPDIR` 里，它的路径在打包时被换成
# `{{WTOOL_HOME}}` / `{{HOME}}` 占位符，所以**不需要**同名。
#
# 三个容器**并行**（IO 密集、互不干扰：各写自己的 `wtool-all-ubuntu<版本>.*`）。
#
# 证据落在 `$EV/`（默认 /tmp/wtool-evidence/<round>/）：
#   <发行版>.log          打包全过程（含 planner 的 warn/error、check 结果）
#   digest-<发行版>.txt   包内容的**确定性指纹**（文件清单 + 内容 sha256）
#
# 退出码：0 = 三个都成功；非 0 = 有失败（日志里看）。
set -u

ROUND=${1:?用法: bash pack_all_docker.sh <round 名字> [<发行版>...]}
shift || true
DISTS=${*:-22.04 24.04 26.04}
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
WS=$(cd -- "$HERE/.." && pwd -P)          # = 工作区根（wtool-base-tools 的上一层）
WS=$(cd -- "$WS/.." && pwd -P)
EV=${EV:-/tmp/wtool-evidence/$ROUND}
mkdir -p -- "$EV"
echo "工作区 : $WS"
echo "证据   : $EV"
echo "发行版 : $DISTS"

# `SEQ=1`：**串行**打（默认并行）。为什么要有这个开关：
# 三个容器同时 install 时，各自的 `<generate>` 会往**同一个**工作区 `__output/`
# 写临时文件（`__output/x.wtool-new.<容器里的 pid>`，pid 常常撞），于是同一个
# 文件被两个容器同时写 → 账本里记的 sha256 每次都不一样（2026-10-21 实测：
# starship/atuin/fzf 三条 generate 的 hash 三次三个值）。要"两次打包逐字节相同"，
# 就在串行里比 —— 并行跑出来的包**不是**可复现的基准。
SEQ=${SEQ:-0}
pids=""
run_one() {
    v=$1
    docker run --rm --network=host --user "$(id -u):$(id -g)" \
            -e HOME=/tmp/packhome \
            -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory \
            -e GIT_CONFIG_VALUE_0='*' \
            -e WTOOL_ALL_DIGEST_OUT="/ev/digest-${v}.txt" \
            -v "$WS":"$WS" \
            -v "$WS/__release":"$WS/__release" \
            -v "$EV":/ev \
            "wtool/pack-ubuntu${v}:latest" \
            bash -c "mkdir -p /tmp/packhome && cd '$WS' && \
                     env -u WTOOL_HOME -u WTOOL_STATE -u WTOOL_PREFIX \
                         -u WTOOL_ROOT -u WTOOL_MANAGED_HOME -u WTOOL_PROJECT_ID \
                         -u WTOOL_PROJECT_DIR -u WTOOL_PROJECT_ROOT \
                         PATH=/usr/bin:/bin \
                         bash wtool-base-tools/wtool.sh pack-offline-release all \
                              --os-version='$v'" \
            > "$EV/$v.log" 2>&1
    echo "$v rc=$?" >> "$EV/rc.txt"
}
for v in $DISTS; do
    img="wtool/pack-ubuntu${v}:latest"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "✗ 没有镜像 $img" >&2; exit 2
    fi
    if [ "$SEQ" = 1 ]; then
        run_one "$v" || rc_seq=1
    else
        ( run_one "$v" ) &
        pids="$pids $!"
    fi
done
rc=${rc_seq:-0}
for p in $pids; do
    wait "$p" || rc=1
done
echo "---- 结果 ----"
cat -- "$EV/rc.txt" 2>/dev/null
for v in $DISTS; do
    printf '%-6s ' "$v"
    if [ -f "$WS/__release/wtool-all-ubuntu${v}.tar.gz" ]; then
        printf '%12s  %s\n' "$(wc -c < "$WS/__release/wtool-all-ubuntu${v}.tar.gz" | tr -d ' ')" \
               "$(sha256sum "$WS/__release/wtool-all-ubuntu${v}.tar.gz" | cut -d' ' -f1)"
    else
        printf '（没有产物）\n'
    fi
done
grep -h '^整机包检查' "$EV"/*.log 2>/dev/null
exit $rc
