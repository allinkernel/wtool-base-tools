#!/bin/bash
# verify_offline_releases.sh —— 逐个 release 页核对：**gh 的 digest vs 本地 sha256**
#
# 用法：
#   bash verify_offline_releases.sh <tag> <本地资产目录>[:<另一个目录>...] [<仓库>...]
#   例：bash verify_offline_releases.sh offline-2026-10-21 /tmp/rel-run14:/tmp/rel-run15:/tmp/rel-run16
#
# 本地那把 sha256 从哪来：`pack-offline-release` 会给每个资产写一份同名 `.sha256`
# （内容 `<sha>  <文件名>`）。脚本把所有给定目录（递归）里的 `.sha256` 收成一张
# `文件名 → sha256` 的表，再拿它去对页上每个资产的 `digest`。
#
# 判据（逐页打印）：
#   1. 资产名全 ASCII；
#   2. gh 给了 `digest`，且与本地同名文件的 sha256 **逐字相同**；
#   3. 本地有的资产名在页上都能找到（不漏传）；
#   4. 打印每页资产数 + 合计。
set -u
TAG=${1:?用法见文件头}
DIRS=${2:?本地资产目录（冒号分隔）}
shift 2
WS=$(cd -- "$(dirname -- "$0")/../.." && pwd -P)
PY="$WS/wtool-base-tools/lib/wtool_plan.py"

mapfile -t REPOS < <(
    if [ $# -gt 0 ]; then printf '%s\n' "$@"; exit 0; fi
    python3 "$PY" publish-list --root "$WS" 2>/dev/null | while IFS=$'\t' read -r _prio pid path kind _s _t _to; do
        [ "$kind" = "none" ] && continue
        python3 "$PY" publish-info "$path" 2>/dev/null | awk -F'\t' '$1=="repo"{print $2}'
    done | sort -u
)

python3 - "$TAG" "$DIRS" "${REPOS[@]}" <<'PY'
import json, os, subprocess, sys

tag, dirs = sys.argv[1], sys.argv[2].split(":")
repos = [r for r in sys.argv[3:] if r]

# ---- 本地 sha256 表：所有 *.sha256（内容是 `<sha>  <name>`）------------------
want = {}     # name -> sha
src = {}      # name -> 本地路径
for d in dirs:
    for dp, _dn, fns in os.walk(d):
        for f in fns:
            if not f.endswith(".sha256"):
                continue
            p = os.path.join(dp, f)
            try:
                txt = open(p, encoding="utf-8").read().split("\n")[0].split()
            except OSError:
                continue
            if len(txt) >= 2:
                want[txt[1]] = txt[0]
                src[txt[1]] = os.path.join(os.path.dirname(p), txt[1])
print("本地资产表：%d 个（来自 %s）" % (len(want), " ".join(dirs)))

fail = 0
total = 0
seen = set()
for repo in repos:
    try:
        out = subprocess.check_output(
            ["gh", "api", "repos/%s/releases/tags/%s" % (repo, tag)],
            stderr=subprocess.DEVNULL).decode()
    except subprocess.CalledProcessError:
        print("── %-34s ✗ 没有 release（tag %s）" % (repo, tag))
        fail += 1
        continue
    d = json.loads(out)
    assets = d.get("assets", [])
    total += len(assets)
    print("── %-34s 资产 %d 个" % (repo, len(assets)))
    for a in sorted(assets, key=lambda x: x["name"]):
        name, size = a["name"], a["size"]
        digest = (a.get("digest") or "").replace("sha256:", "")
        probs = []
        if any(ord(c) > 127 for c in name):
            probs.append("非 ASCII")
        if not digest:
            probs.append("gh 没给 digest")
        lsha = want.get(name, "")
        if lsha and digest and digest != lsha:
            probs.append("digest≠本地 sha256")
        if not lsha:
            probs.append("本地没有同名 .sha256（没传过？）")
        seen.add(name)
        print("   %-2s %-56s %10d  %s%s" % (
            "✔" if not probs else "✗", name, size,
            (digest[:16] + "…") if digest else "-",
            ("  ← " + " / ".join(probs)) if probs else ""))
        if probs:
            fail += 1

missing = [n for n in sorted(want) if n not in seen]
if missing:
    print("⚠️ 本地有、页上没找到的 %d 个：" % len(missing))
    for n in missing[:40]:
        print("     - %s" % n)
print("\n合计资产数：%d；不一致/缺失条目：%d；本地表里未上传：%d" % (total, fail, len(missing)))
sys.exit(1 if (fail or missing) else 0)
PY
