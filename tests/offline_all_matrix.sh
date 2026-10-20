#!/bin/bash
# offline_all_matrix.sh —— **三个发行版各一份整机包的功能矩阵**（宿主上跑）
#
# 用法：
#     bash offline_all_matrix.sh <整机包所在目录> [<发行版>...]
#     例：bash offline_all_matrix.sh ~/self/wtool/__release 22.04 24.04 26.04
#
# 对每个发行版起一个**干净容器**（`wtool/accept-ubuntu<版本>`，见
# `Dockerfile.acceptance`：发行版本体 + python3/git/curl，**没有** .wtool），
# 把包只读挂进去、在一个**不同的 `$HOME`** 里解开，跑
# `offline_all_acceptance.sh`（解包 → install.sh → check → 逐项目探针）。
#
# 输出三样：
#   1) 每个发行版一份原始日志：`<目录>/accept-ubuntu<版本>.log`
#   2) **矩阵表**：行 = 项目，列 = 22.04/24.04/26.04，格 = ✅/❌
#   3) 汇总行：`MATRIX-SUMMARY <发行版> <项目数> <通过> <失败>`
#
# 退出码：0 = 三个发行版**全绿**；1 = 有 ❌（**这时不许发布**）。
#
# 为什么用 `-v`/`--network=host` 之外什么都不给：容器里只跑验收脚本，
# 不联网（包已经在本地）；`--network=host` 只是让 `install.sh` 第 0 步的
# 那点探测不至于卡住。
set -u

PUB=${1:-}
shift || true
DISTS=${*:-22.04 24.04 26.04}
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P)
IT=${HERE}/offline_all_acceptance.sh

[ -n "$PUB" ] || { echo "用法: bash $0 <整机包目录> [<发行版>...]" >&2; exit 2; }
PUB=$(cd -- "$PUB" && pwd -P)
[ -f "$IT" ] || { echo "缺 $IT" >&2; exit 2; }
[ -d "$PUB" ] || { echo "目录不存在: $PUB" >&2; exit 2; }

declare -A RESULT   # "distro|pid" → "OK|FAIL"
declare -A DETAIL
PIDS=()
KIND=()
declare -A SEEN
ANY_FAIL=0

for v in $DISTS; do
    asset="wtool-all-ubuntu${v}.tar.gz"
    log="$PUB/accept-ubuntu${v}.log"
    img="wtool/accept-ubuntu${v}:latest"
    # 分卷包：`__release/` 里只有 `*.part-aa…`（整包被挪进 scratch 了）→ 容器里先拼回来
    if [ ! -f "$PUB/$asset" ] && ! ls "$PUB/$asset".part-* >/dev/null 2>&1; then
        echo "✗ 缺包：$PUB/$asset（连分卷都没有）" >&2; ANY_FAIL=1; continue
    fi
    _npart=$(ls "$PUB/$asset".part-* 2>/dev/null | wc -l | tr -d ' ')
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "→ 建验收镜像 $img"
        ( cd "$HERE" && docker build -q -f Dockerfile.acceptance \
            --build-arg BASE="wtool/pack-ubuntu${v}:latest" -t "$img" . ) || {
            echo "✗ 建不了 $img（先确认 wtool/pack-ubuntu${v}:latest 在）" >&2
            ANY_FAIL=1; continue
        }
    fi
    echo "===== ubuntu $v：$asset"
    # 容器里：/pkg 只读，$HOME 用一个**每个发行版都不同**的目录
    docker run --rm --network=host \
        -v "$PUB":/pkg:ro \
        -v "$IT":/accept.sh:ro \
        "$img" \
        bash -c "set -e; mkdir -p /home/target-${v}; \
                 if [ -f /pkg/${asset} ]; then TAR=/pkg/${asset}; \
                 else cat /pkg/${asset}.part-* > /tmp/${asset}; TAR=/tmp/${asset}; fi; \
                 if [ -f /pkg/${asset}.sha256 ]; then \
                     want=\$(cut -d' ' -f1 /pkg/${asset}.sha256); got=\$(sha256sum \$TAR | cut -d' ' -f1); \
                     [ \"\$want\" = \"\$got\" ] && echo \"✔ 拼回来的整包 sha256 与 .sha256 一致：\$got\" \
                       || { echo \"✗ 整包 sha256 对不上：\$got != \$want\"; exit 1; }; fi; \
                 HOME=/home/target-${v} bash /accept.sh \$TAR /home/target-${v}" \
        2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" != 0 ]; then
        echo "✗ ubuntu $v 验收失败（rc=$rc）—— 见 $log" >&2
        ANY_FAIL=1
    fi
    while IFS= read -r line; do
        case $line in
            MATRIX-SUMMARY*)
                echo "  $line" ;;
            MATRIX$'\t'*)
                IFS=$'\t' read -r _tag pid kind res det <<< "$line"
                RESULT["$v|$pid"]="$res"
                DETAIL["$v|$pid"]="$det"
                if [ -z "${SEEN[$pid]:-}" ]; then
                    SEEN[$pid]=1; PIDS+=("$pid"); KIND["$pid"]="$kind"
                fi ;;
        esac
    done < <(grep -a '^MATRIX' "$log" 2>/dev/null)

    # `~/usr` 那条判据也必须在日志里看到
    if ! grep -q 'HOME/usr 仍然不存在' "$log"; then
        echo "✗ ubuntu $v 没打印「\$HOME/usr 仍然不存在」—— 这条判据没验到" >&2
        ANY_FAIL=1
    fi
done

# ---------------------------------------------------------------------------
# 矩阵表
# ---------------------------------------------------------------------------
echo
echo "================ 逐项目功能矩阵（行=项目，列=发行版） ================"
printf '%-34s %-9s' '项目' 'kind'
for v in $DISTS; do printf ' %-7s' "$v"; done
printf '\n'
printf '%.0s-' $(seq 1 70); printf '\n'
for pid in "${PIDS[@]}"; do
    printf '%-34s %-9s' "$pid" "${KIND[$pid]}"
    for v in $DISTS; do
        r=${RESULT["$v|$pid"]:-—}
        case $r in
            OK)    printf ' %-7s' '✅' ;;
            FAIL)  printf ' %-7s' '❌' ;;
            *)     printf ' %-7s' '—' ;;
        esac
    done
    printf '\n'
done
echo
echo "================ 逐发行版计数 ================"
for v in $DISTS; do
    n=0; ok=0; fl=0
    for pid in "${PIDS[@]}"; do
        case ${RESULT["$v|$pid"]:-} in
            OK)   n=$((n+1)); ok=$((ok+1)) ;;
            FAIL) n=$((n+1)); fl=$((fl+1)) ;;
        esac
    done
    _musl=$(for pid in "${PIDS[@]}"; do [ "${KIND[$pid]}" = muslbin ] && echo x; done | wc -l)
    _muslok=$(for pid in "${PIDS[@]}"; do
        [ "${KIND[$pid]}" = muslbin ] && [ "${RESULT[$v|$pid]:-}" = OK ] && echo x; done | wc -l)
    echo "ubuntu $v : 项目 $n / ✅ $ok / ❌ $fl    其中 muslbin ✅ $_muslok / $_musl"
    if [ "$fl" != 0 ]; then
        echo "   ❌ 明细："
        for pid in "${PIDS[@]}"; do
            [ "${RESULT[$v|$pid]:-}" = FAIL ] && echo "     - $pid：${DETAIL[$v|$pid]:-}"
        done
    fi
done

echo
if [ "$ANY_FAIL" != 0 ]; then
    echo "**矩阵有 ❌ / 有验收失败 → 这一版【不可发布】**"
    exit 1
fi
for v in $DISTS; do
    for pid in "${PIDS[@]}"; do
        [ "${RESULT[$v|$pid]:-}" = OK ] || { echo "**$v / $pid 没跑出结果 → 不可发布**"; exit 1; }
    done
done
echo "**矩阵全绿 → 可以发布**"
exit 0
