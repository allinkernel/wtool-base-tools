#!/bin/sh
# install.sh —— **安装器的唯一入口**（ADR-0045 §1.8 / D42）。做完就停，然后告诉你下一步跑什么。
#
# 它对用户只有一个承诺：
#     **source 了 `$WTOOL_HOME/env.zsh`（bash 用 env.bash）之后，`wtool` 这条命令就能用。**
# 它不装任何项目 —— 那是 `wtool bootstrap` 的事。
#
# 三条入口（DESIGN §1.8 / §10.1；后两条由下面的职责①自己建/修）：
#
#     $WTOOL_HOME/install.sh
#        └─► $WTOOL_HOME/wtool/install.sh
#               └─► $WTOOL_HOME/wtool/<安装器项目>/scripts/install.sh      ← 本文件
#
#   ⚠️ 项目名**不写死**：`<安装器项目>` 是"引擎住在哪个项目里"现算出来的
#      （= 本文件所在目录的上一级，相对工作区根的路径）。今天它叫 wtool-base-tools
#      （2026-10-13 由 `bootstrap` 改名，ADR-0045 §7.1）—— 这里一行都没动过。
#
# 六项职责（D42；**每一步失败都非 0 退出**，并说清是哪一步）：
#
#   第 0 步  准备运行环境（发行版差异拆在 install-<发行版><版本>.sh 里）
#   ① 装安装器项目本体（L1：$WTOOL_HOME/wtool/<项目>）+ **两条入口链**
#   ② 建 var/ 账本，并把**这次动作**记进去
#        （删掉 var/ 之后 `wtool check` 必须报错，不许静默"一切对得上"）
#   ③ 建 manifest 三件套 $WTOOL_HOME/wtool/.repo/manifests/{default.xml,.sha256,.commitid}
#        满血工作区（.repo/projects **且** .repo/project-objects，D17）
#            → default.xml 是**指向 live 的绝对链**，.sha256 / .commitid **现场算**
#        bundle / 没有 repo
#            → default.xml 是**包内副本**，.sha256 / .commitid **只校验、不覆盖**
#              （对不上就停手并说清；差一点都不许往下走）
#   ④ 建 env.{zsh,bash}：**先**加载安装器项目自己 → 保证 `wtool` 可用、
#        `$WTOOL_HOME/usr/bin` 在 PATH 里
#   ⑤ 起一个**新的** zsh/bash 子进程：在里面 source env.<shell> + 跑 `wtool check` 当验收
#   ⑥ **问过用户才**改 rc：默认只打印那两行，用户明确同意（交互确认 / `--write-rc`）才代写；
#        **非交互（没有终端）绝不许挂住** —— 一律只打印
#
# 一切操作都在 `$WTOOL_HOME` 内（只有 ⑥ 用户点头后才动 rc）。
#
# 用法：
#   ./install.sh                 装（装到 $WTOOL_HOME；没给就 $HOME/.wtool）
#   ./install.sh --dry-run       只说要做什么，一个字节都不写
#   ./install.sh --home <目录>   装到别处（= rc 里那行 `export WTOOL_HOME=<目录>`）
#   ./install.sh --write-rc      你已经在命令行上明确同意写 rc 那两行（不再问）
#   ./install.sh --no-rc         连问都不问，只打印那两行
#   WTOOL_MIRROR=mirrors.ustc.edu.cn ./install.sh    顺带换 apt 源
set -eu

say()  { printf 'wtool-install: %s\n' "$*"; }
warn() { printf 'wtool-install: 警告: %s\n' "$*" >&2; }
die()  { printf 'wtool-install: 错误: %s\n' "$*" >&2; exit 1; }

# 解析自身真实路径：manifest 的 linkfile 会在工作区根目录放一个指向本脚本的
# 软链，$WTOOL_HOME 下那两条入口链也指到这儿。不处理的话"项目目录"会被误判。
self=$0
while [ -L "$self" ]; do
    target=$(readlink -- "$self")
    case $target in
        /*) self=$target ;;
        *)  self=$(dirname -- "$self")/$target ;;
    esac
done
here=$(cd -- "$(dirname -- "$self")" && pwd -P)      # = <安装器项目>/scripts
proj=$(cd -- "$here/.." && pwd -P)                   # = <安装器项目>

# ==========================================================================
# 被引擎调用时（`wtool install <安装器项目>` / `wtool uninstall <安装器项目>`）：
# **立刻退出** —— 而且必须抢在**参数解析之前、第 0 步之前**。
#
#   · 参数要在这一层之前：引擎卸载时跑的是 `scripts/install.sh --uninstall`
#     （契约见 docs/spec.md），那个开关本脚本不认识 —— 排在解析后面就是
#     "未知参数: --uninstall" 直接失败（实测：pairing 场景 9 当场红）。
#   · 第 0 步也要在这一层之前：引擎正装着东西的时候突然去跑 apt，既莫名其妙
#     又需要 root（**这条踩过**）。
#   · 更不能反过来调 `wtool install`：那会变成
#     install.sh → wtool install → install.sh 的无限递归。
# L1 / 账本 / env 汇总都是引擎的活，这里一个字节都不写。
# ==========================================================================
if [ -n "${WTOOL_PROJECT_ID:-}" ]; then
    say "由引擎调用（项目 ${WTOOL_PROJECT_ID}）：L1 / 账本 / env 汇总都由引擎负责，这里不重复做"
    exit 0
fi

HOME_DIR=${HOME:-/root}
DRY_RUN=0
# rc 落点模式（2026-10-21 用户口径）：
#   auto  默认。**先判断这是不是一台"借用的机器"**，再决定改不改 `~/.bashrc`：
#          自己的机器（home 模式）→ 问一次要不要写 rc；
#          借用机器（portable 模式）→ **一个字节都不碰** `~/.bashrc`/`~/.zshrc`，
#          改成在用户目录下生成 `wtool-bashrc` / `wtool-zshrc`，让用户手动 source。
#   home / file / none 强制那一种。write / print / ask 是旧名（兼容，别再用）。
RC_MODE=auto
PORTABLE=auto                                        # auto | 1（强制 portable）| 0（强制 home）
PREFIX_DIR=""
WTOOL_HOME_ARG=""
while [ $# -gt 0 ]; do
    case $1 in
        --dry-run)  DRY_RUN=1 ;;
        --home)     WTOOL_HOME_ARG=${2:-}
                    [ -n "$WTOOL_HOME_ARG" ] || die "--home 要跟一个目录"
                    shift ;;
        --home=*)   WTOOL_HOME_ARG=${1#--home=} ;;
        --prefix)   PREFIX_DIR=${2:-}
                    [ -n "$PREFIX_DIR" ] || die "--prefix 要跟一个目录"
                    shift ;;
        --prefix=*) PREFIX_DIR=${1#--prefix=} ;;
        --portable) PORTABLE=1 ;;
        --rc-mode)  RC_MODE=${2:-auto}
                    [ -n "$RC_MODE" ] || die "--rc-mode 要跟 auto|home|file|none"
                    shift ;;
        --rc-mode=*) RC_MODE=${1#--rc-mode=} ;;
        --write-rc) RC_MODE=write ;;
        --no-rc)    RC_MODE=none ;;
        -h|--help)
            # 打印文件头那段注释（不写死行号，改一行注释不会错位）
            awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$self"
            exit 0 ;;
        *) die "未知参数: $1（用法：./install.sh --help）" ;;
    esac
    shift
done

# `$WTOOL_HOME` = **`.wtool` 根目录**（ADR-0045 §1.1 / D47 / D48）——
# 不再有"被管理的家目录"那一层。取值优先级：
#     --prefix <目录>  >  --home <目录>  >  环境里的 $WTOOL_HOME
#       >  **自己所在的那个 `.wtool`**（整机包解到 `~/某人/.wtool` 时自动认出来）
#       >  $HOME/.wtool
# ⚠️ 实测踩过：这里原来只看 `$HOME`，于是跑一遍测试就把**真** `~/.wtool/bootstrap`
#    （那时安装器项目还叫这个名字）指向了已删除的 /tmp 目录（悬空软链）。
#    所以：环境里给了就用它。
#
# ‼️ "自己所在的那个 `.wtool`" 是 2026-10-21 加的：借用机器上用户会把整机包解到
#    `~/wangshaowei/.wtool` 再跑 `~/wangshaowei/.wtool/install.sh`。那时若还默认
#    `$HOME/.wtool`，就会**装到别人的家目录根上** —— 正是要避免的事。
_self_wh=""
_self_up=$(dirname -- "$(dirname -- "$proj")")       # <X>/.wtool/wtool/<项目> → <X>/.wtool
if [ "$(basename -- "$_self_up")" = ".wtool" ] && [ -d "$_self_up" ]; then
    _self_wh=$_self_up
fi
if [ -n "$PREFIX_DIR" ]; then
    case $PREFIX_DIR in
        /*) ;;
        *)  die "--prefix 要绝对路径（例：--prefix $HOME/wangshaowei）: $PREFIX_DIR" ;;
    esac
    WTOOL_HOME_ARG=${PREFIX_DIR%/}/.wtool
    [ "$PORTABLE" = auto ] && PORTABLE=1
fi
WTOOL_HOME_DIR=${WTOOL_HOME_ARG:-${WTOOL_HOME:-${_self_wh:-$HOME_DIR/.wtool}}}
case $WTOOL_HOME_DIR in
    /*) ;;
    *)  die "WTOOL_HOME 得是绝对路径（rc 里那行 `export WTOOL_HOME=…` 写的就是它）: $WTOOL_HOME_DIR" ;;
esac
[ "$WTOOL_HOME_DIR" = "/" ] || WTOOL_HOME_DIR=${WTOOL_HOME_DIR%/}

# 工作区根与项目身份。算法和引擎一致（`wtool.sh` 里就是 `dirname <引擎目录>`）：
# 环境里给了 WTOOL_ROOT 就以它为准（那是引擎导出的）。
ws=${WTOOL_ROOT:-$(dirname -- "$proj")}
[ -d "$ws" ] && ws=$(cd -- "$ws" && pwd -P)
case $proj in
    "$ws"/*) proj_rel=${proj#"$ws"/} ;;     # = 项目身份（相对工作区根的路径）
    *)       proj_rel=$(basename -- "$proj") ;;
esac

# ==========================================================================
# 落点模式：**home**（自己的机器）还是 **portable**（借用的机器）
#
# 用户 2026-10-21 原话（大意）：这台机器可能是借的，`~/.bashrc` 动不得，
# 东西只能放 `~/wangshaowei` 下、配置也只能写 `~/wangshaowei/wtool-bashrc`，
# 用户每次手动 `source` 一下就拿到 wtool 命令和新 PATH。
# 所以安装器**不该一上来就问"要不要改 .bashrc"**，先判断这是不是一台别人的机器。
#
# 判据（任一成立 → portable；判据**打印出来**，绝不静默切换）：
#   ① 用户显式 `--portable` / `--prefix`
#   ② `$WTOOL_HOME` 不在 `$HOME/.wtool`（回退到 `~/某人/.wtool` 那种）
#   ③ `$HOME` 的属主不是当前用户（借来的账号/共享家目录）
#   ④ `~/.bashrc` 或 `~/.zshrc` 存在但**不可写**
#   ⑤ `$HOME` 落在网络/共享挂载上（nfs/cifs/fuse/9p/vboxsf/virtiofs）
# 都拿不到证据时按 home 处理，并且 rc 那一步**非交互照样只打印、绝不代写**。
# ==========================================================================
_mode=home
_mode_reason=""
if [ "$PORTABLE" = 1 ]; then
    _mode=portable
    if [ -n "$PREFIX_DIR" ]; then _mode_reason="--prefix $PREFIX_DIR（= 借用机器）"
    else _mode_reason="--portable（用户明说）"; fi
elif [ "$PORTABLE" != 0 ]; then
    if [ "$WTOOL_HOME_DIR" != "$HOME_DIR/.wtool" ]; then
        _mode=portable
        _mode_reason="\$WTOOL_HOME 不在 \$HOME/.wtool（是 $WTOOL_HOME_DIR）"
    else
        _home_owner=$(stat -c %u -- "$HOME_DIR" 2>/dev/null || echo "")
        if [ -n "$_home_owner" ] && [ "$(id -u)" != "0" ] && [ "$_home_owner" != "$(id -u)" ]; then
            _mode=portable
            _mode_reason="\$HOME 的属主（uid $_home_owner）不是当前用户（uid $(id -u)）"
        fi
    fi
    if [ "$_mode" = home ]; then
        for _rcf in "$HOME_DIR/.bashrc" "$HOME_DIR/.zshrc"; do
            if [ -e "$_rcf" ] && [ ! -w "$_rcf" ]; then
                _mode=portable
                _mode_reason="$_rcf 不可写（不是你的文件）"
                break
            fi
        done
    fi
    if [ "$_mode" = home ]; then
        _fstype=$(findmnt -n -o FSTYPE -T "$HOME_DIR" 2>/dev/null | head -1 || true)
        case $_fstype in
            nfs*|cifs|smb*|fuse*|9p|vboxsf|virtiofs)
                _mode=portable
                _mode_reason="\$HOME 落在共享/网络挂载上（$_fstype）" ;;
        esac
    fi
fi
if [ "$_mode" = portable ]; then
    say "落点模式：**portable**（检测到：${_mode_reason:-用户指定}）"
    say "  → 不碰 \$HOME/.bashrc / .zshrc；生成 $WTOOL_HOME_DIR/../wtool-bashrc 与 wtool-zshrc"
else
    say "落点模式：home（自己的机器）"
fi
case $RC_MODE in
    auto)  if [ "$_mode" = portable ]; then RC_MODE=file; else RC_MODE=ask; fi ;;
    print|ask_old) RC_MODE=ask ;;
    write|print) : ;;                        # 旧名，原样保留语义
    home|file|none) : ;;
    *) die "--rc-mode 只能是 auto|home|file|none（给的是 $RC_MODE）" ;;
esac

# ==========================================================================
# 第 0 步：准备运行环境（发行版不同，做法不同）
#
# 这一步会**先给国内几个镜像站测速**（各下一个约 1.4 MB 的索引、最多 3 秒），
# 把结果画成表让你挑，然后才装包 —— "源能用"不等于"源快"：实测官方源比国内
# 镜像慢 15 倍，而这一步要下几十 MB（python3 + git + curl）。
# 不想挑：WTOOL_MIRROR=official 保持系统源，WTOOL_MIRROR=<代号|主机名> 直接指定；
# 没有终端可问时（脚本里跑）自动选最快的那个。细节见 scripts/install-env.sh 顶部。
#
# wtool 要能跑，最少需要 python3（规划器）和 git（读项目的 HEAD）。
# 最小化的 docker 镜像里这两个都没有，所以要先把它们装上 ——
# 否则下一步自举出来的东西一调用就报"缺少依赖"。
# ==========================================================================
say "第 0 步：准备运行环境"

# 探测发行版。读 /etc/os-release 的 ID + VERSION_ID，
# 拼出 install-<ID><主版本号>.sh（如 ubuntu20）。
_env_profile=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    _id=${ID:-}
    _ver=${VERSION_ID:-}
    _major=${_ver%%.*}
    for _cand in "$here/install-$_id$_major.sh" "$here/install-$_id.sh"; do
        [ -f "$_cand" ] && { _env_profile=$_cand; break; }
    done
    say "  系统：${PRETTY_NAME:-$_id $_ver}"
fi

# env 脚本要用它来试探 git 能不能读仓库（候选是工作区里的项目，不写死名字）
WTOOL_WS_DIR=$ws
export WTOOL_WS_DIR

if [ -n "$_env_profile" ]; then
    say "  用环境脚本：$(basename -- "$_env_profile")"
    if [ "$DRY_RUN" = 1 ]; then
        say "  [dry-run] 会先给国内几个镜像站测速、让你挑一个（WTOOL_MIRROR=official 可跳过）"
        say "  [dry-run] 然后装 python3 / git / ca-certificates / curl（+ ansible）"
    else
        # 先加载共用逻辑，再由 profile 声明"自己不一样的地方"并调用 env_prepare。
        # profile 里不重复写装包换源那些 —— 那些所有发行版都一样。
        [ -f "$here/install-env.sh" ] || die "缺少 $here/install-env.sh"
        # shellcheck disable=SC1091
        . "$here/install-env.sh"
        # shellcheck disable=SC1090
        . "$_env_profile"
    fi
else
    warn "  没有匹配的环境脚本（找过 install-${_id:-?}${_major:-}.sh）"
    warn "  请手动确认这几个命令可用：python3 git curl"
    warn "  缺的话：apt-get install -y --no-install-recommends ca-certificates git python3 curl"
fi

# ==========================================================================
# 小工具：建/修一条**相对**软链
#
# 两条入口链的两端**都在 `$WTOOL_HOME` 里面** —— 和 L2 链同理（D45）：
# 写相对目标，整棵 `.wtool` 被 tar 走、搬到别的机器／目录之后照样有效。
# `readlink -f` 会一路解到工作区里那个真脚本（那正是 ① 的判据）。
# ==========================================================================
link_rel() {   # <落点> <相对目标>
    _lx_dest=$1; _lx_target=$2
    if [ -L "$_lx_dest" ]; then
        _lx_cur=$(readlink -- "$_lx_dest" 2>/dev/null || true)
        if [ "$_lx_cur" = "$_lx_target" ]; then
            say "  已在：$_lx_dest -> $_lx_target"
            return 0
        fi
        say "  改指向：$_lx_dest：$_lx_cur -> $_lx_target"
    elif [ -e "$_lx_dest" ]; then
        die "① 失败：$_lx_dest 已经存在而且**不是软链**。先自己确认里面没有你要的东西，处理掉再重试（绝不覆盖你的文件）。"
    else
        say "  建链：$_lx_dest -> $_lx_target"
    fi
    mkdir -p -- "$(dirname -- "$_lx_dest")"
    ln -sfn -- "$_lx_target" "$_lx_dest"
}

# ==========================================================================
# 职责 ⓪b：**整机包**里的账本占位符展开（`{{WTOOL_HOME}}` / `{{HOME}}`）
#
# 整机包是"另一台机器"的 `.wtool` 拷贝，账本（`var/**`：`journal.tsv` /
# `registry.tsv` / env 块）里记着**源机的绝对路径**（`/home/某人/.wtool/usr/bin/rg`、
# `/home/某人/usr`）。打包时 `pack-offline-release all` 把它们写成占位符，
# 这里展开成**本机**的 —— 必须抢在 ① 之前：① 里的 `wtool install` 会按账本
# 重算 env 汇总与环境块。
#
# 开发机上没有占位符 → 整段是 no-op（一个字节都不碰）。
# ⚠️ 不做这一步的后果（2026-10-20 实测）：目标机 `$HOME` 只要不叫源机那个名字，
#    `wtool check` 就对**每个项目**报"不见了"（9 个项目 20 条）、
#    install.sh 第⑤步自检当场 rc=1 —— 用户第一眼看到的就是"包坏了"。
# ==========================================================================
if [ "$DRY_RUN" = 1 ]; then
    say "⓪b [dry-run] 展开账本里的 {{WTOOL_HOME}} / {{HOME}} 占位符（开发机上没有 → no-op）"
elif grep -rqsF -e '{{WTOOL_HOME}}' -e '{{HOME}}' -- "$WTOOL_HOME_DIR/var" 2>/dev/null; then
    say "⓪b 展开账本占位符（这是从整机包解出来的 .wtool）"
    python3 - "$WTOOL_HOME_DIR/var" "$WTOOL_HOME_DIR" "$HOME_DIR" <<'PY' || die "⓪b 失败：账本占位符展开不了"
import os, sys
root, whome, uhome = sys.argv[1], sys.argv[2].rstrip(os.sep), sys.argv[3].rstrip(os.sep)
# 空值必须挡掉：uhome == "" 时替换会把每个 "/" 都写坏（灾难性）
pairs = [(w, p) for w, p in ((whome, "{{WTOOL_HOME}}"), (uhome, "{{HOME}}")) if w]
n = 0
for dirpath, _dn, fns in os.walk(root):
    for f in fns:
        p = os.path.join(dirpath, f)
        try:
            t = open(p, "r", encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        nt = t
        for src, ph in pairs:                  # WTOOL_HOME 是 HOME 的子路径 → 先换它
            nt = nt.replace(ph, src)
        if nt != t:
            open(p, "w", encoding="utf-8").write(nt)
            n += 1
print("   ✔ 展开 %d 个账本文件" % n)
PY
else
    say "⓪b 账本里没有占位符（开发机 / 直接从 git 装的）—— 跳过"
fi

# ==========================================================================
# 职责①：装安装器项目本体 + 两条入口链
#
# `wtool install <安装器项目>` 会建 L1（`$WTOOL_HOME/wtool/<项目>` → 本目录，
# 开发机=绝对链 / bundle=本来就是实体）、写 env 块、重算 env.{zsh,bash}。
# 这一步的输出**绝不吞**：吞掉的话 install 拒绝时用户看到的是一片安静（踩过）。
# ==========================================================================
say "① 装安装器项目本体：$proj_rel"
if [ "$DRY_RUN" = 1 ]; then
    say "  [dry-run] wtool install $proj（L1：$WTOOL_HOME_DIR/wtool/$proj_rel）"
    say "  [dry-run] 两条入口链：$WTOOL_HOME_DIR/install.sh → wtool/install.sh → $proj_rel/scripts/install.sh"
else
    [ -x "$proj/wtool.sh" ] || die "① 失败：这里不是安装器项目（找不到可执行的 wtool.sh）: $proj"
    # --force 是有意的：安装器常常来自一个开发副本（工作区挂载进来、或有未提交
    # 改动）—— 那种情况下"版本记录不准"，但不该因此拦住"让 wtool 能用"。
    if ! WTOOL_HOME="$WTOOL_HOME_DIR" WTOOL_STATE="$WTOOL_HOME_DIR/var" \
         WTOOL_PREFIX="$WTOOL_HOME_DIR/usr" WTOOL_MANAGED_HOME="$HOME_DIR" \
         "$proj/wtool.sh" install "$proj" --force; then
        die "① 失败：wtool install $proj 没成功（原因就在上面那几行）—— 这一步不过，后面几步全是空的"
    fi
    [ -x "$WTOOL_HOME_DIR/wtool/$proj_rel/wtool.sh" ] \
        || die "① 失败：L1 不在（$WTOOL_HOME_DIR/wtool/$proj_rel/wtool.sh 不可执行）"
    link_rel "$WTOOL_HOME_DIR/wtool/install.sh" "$proj_rel/scripts/install.sh"
    link_rel "$WTOOL_HOME_DIR/install.sh" "wtool/install.sh"
    _real=$(readlink -f -- "$WTOOL_HOME_DIR/install.sh" 2>/dev/null || true)
    [ "$_real" = "$here/install.sh" ] \
        || die "① 失败：$WTOOL_HOME_DIR/install.sh 解析到「$_real」，期望「$here/install.sh」"
    say "  ✔ 入口链通了：$WTOOL_HOME_DIR/install.sh → $here/install.sh"
fi

# ==========================================================================
# 职责①c：**本发行版那一套产物**（整机包带所有 target，这里选自己这套）
#
# 2026-10-21 口径：整机包的内容**不许取决于"在哪个容器里打的"** —— 所以 ③ 类
# （docker）项目的 `__output/ubuntu_22.04|24.04|26.04/usr` **三份都进包**，
# 而 `__output/usr` 只是"选哪套"的别名链（包里指向打包时钉死的那一套）。
# 挑哪一套是**目标机**的事：这里按 /etc/os-release 的 `ID` + `VERSION_ID` 把
# `__output/usr` 重新指过去（精确命中优先；没有就退到"不高于本机版本的最高那套"）。
#
# 开发机 / 单项目自足包那边 `__output/` 下没有 `ubuntu_*` 目录 → 整段是 no-op。
# 判据是**目录在不在**，不是"我猜你是什么系统"。
# ==========================================================================
say "①c 选本发行版的那套产物（整机包里 ③ 类带全部 target）"
if [ "$DRY_RUN" = 1 ]; then
    say "  [dry-run] 按 /etc/os-release（${_id:-?} ${_ver:-?}）把 */__output/usr 指到 ubuntu_<版本>/usr"
else
    if python3 - "$WTOOL_HOME_DIR" "${_id:-}" "${_ver:-}" <<'PY'
import os, sys
home, osid, osver = sys.argv[1], sys.argv[2], sys.argv[3]
if not osid or not osver:
    print("  · 读不出发行版（ID/VERSION_ID 空）—— 一个都不动")
    raise SystemExit(0)
root = os.path.join(home, "wtool")
if not os.path.isdir(root):
    print("  · 没有 wtool/ 目录 —— 跳过")
    raise SystemExit(0)
outs = []
for dirpath, dirnames, _fns in os.walk(root):        # 不跟软链，__output 都是实体目录
    if os.path.basename(dirpath) == "__output":
        outs.append(dirpath)
        dirnames[:] = []
if not outs:
    print("  · 一个 __output/ 都没有 —— 跳过")
    raise SystemExit(0)


def vkey(name):
    try:
        return tuple(int(x) for x in name.split("."))
    except ValueError:
        return None


n_ok = 0
for out in outs:
    cands = [d for d in os.listdir(out)
             if d.startswith("ubuntu_") and os.path.isdir(os.path.join(out, d))]
    if not cands:
        continue                                  # ①② 类 / 单套产物：不动
    want = "ubuntu_" + osver
    pick = want if want in cands else None
    if pick is None:                              # 退：不高于本机版本的最高那套
        have = [(vkey(c[len("ubuntu_"):]), c) for c in cands]
        have = [(k, c) for k, c in have if k]
        mine = vkey(osver) or ()
        le = [(k, c) for k, c in have if k <= mine]
        pick = max(le)[1] if le else None
        if pick is None:
            print("  ! %s：三套里没有不高于 %s 的（有 %s）—— 保持原样"
                  % (os.path.relpath(out, home), osver, ", ".join(sorted(cands))))
            continue
        print("  · %s：没有精确的 %s，退到 %s"
              % (os.path.relpath(out, home), want, pick))
    alias = os.path.join(out, "usr")
    target = pick + "/usr"                         # 相对链：整棵 .wtool 搬走也有效
    if os.path.islink(alias) and os.readlink(alias) == target:
        n_ok += 1
        continue
    if os.path.lexists(alias) and not os.path.islink(alias):
        print("  ! %s 是实体目录而不是链 —— 不覆盖，跳过" % os.path.relpath(alias, home))
        continue
    if os.path.islink(alias):
        os.remove(alias)
    os.symlink(target, alias)
    print("  ✔ %s → %s" % (os.path.relpath(alias, home), target))
    n_ok += 1
print("  ✔ %d 个项目选了本发行版（%s %s）的那套" % (n_ok, osid, osver))
PY
    then :; else warn "①c 没跑成（不影响已装的东西；③ 类可能会用打包机那套产物）"; fi
fi

# ==========================================================================
# 职责①b：工作区根目录的入口软链（install.sh / uninstall.sh / README.md / guide.md）
#
# 用 `repo sync` 拿到的客户端，这些软链由 repo 按 manifest 的 linkfile 建；
# 但**从发布包解压出来的工作区没有 repo 客户端**，那些软链就不存在 —— 而
# README 恰恰让人跑 `./install.sh`。这里补上，让两条路拿到的工作区长得一样。
# （这不算第二份真相：manifest 仍是对 repo 客户端的权威描述，这里只是兜底。
#   ⚠️ 安装器项目名**不写死**：install.sh / uninstall.sh 两条按 `$proj_rel` 算。
#   把这一整段改成"照 manifest 的 linkfile 驱动"是另一件事 —— DESIGN §10.2 的
#   ENG 清单第 ③ 条（现在这里还是 4 条硬编码 + 兜底，不是 5 条全驱动）。）
# ==========================================================================
ws_ln() {   # <链接名> <相对工作区根的目标>
    _wl_dest=$ws/$1; _wl_target=$2
    if [ "$DRY_RUN" = 1 ]; then
        say "  [dry-run] $1 -> $_wl_target"
        return 0
    fi
    [ -e "$ws/$_wl_target" ] || { say "  $1 跳过（$ws/$_wl_target 不在）"; return 0; }
    if [ -L "$_wl_dest" ]; then
        [ "$(readlink -- "$_wl_dest")" = "$_wl_target" ] && return 0
    elif [ -e "$_wl_dest" ]; then
        warn "  $1 已存在且不是软链，跳过（怕覆盖你的东西）"
        return 0
    fi
    ln -sfn -- "$_wl_target" "$_wl_dest" && say "  $1 -> $_wl_target"
}
say "①b 工作区根目录入口（$ws）"
ws_ln install.sh   "$proj_rel/scripts/install.sh"
ws_ln uninstall.sh "$proj_rel/scripts/uninstall.sh"
# 用户文档仓：**2026-10-13 由 `wtool-base` 改名成 `wtool-doc`**（ADR-0045 §7.1）。
# ⚠️ 这里原来是写死的 `wtool-base/…` —— 改名之后 `ws_ln` 会因为"源不在"**静默跳过**
#    （只打一句"跳过"），根目录就少两条入口软链。名字跟着清单的 `path=` 走。
ws_ln README.md    wtool-doc/README.md
ws_ln guide.md     wtool-doc/guide.md

# ==========================================================================
# 职责②：建 var/ 账本，并记下**这次动作**
#
# 账本（registry.tsv / <项目>/journal.tsv / meta.tsv / env 块）是引擎写的，
# 装安装器那一步已经建好。这里补的是**安装器自己**那两笔账：
#   · actions.tsv —— 时间线：这台机器上 install.sh 跑过几次、每次装到哪
#   · links.tsv   —— 两条入口链（`check` 照它验、卸载照它收）
# 落点故意叫 `var/installer/`、文件名故意不叫 meta.tsv（那个名字是"一个项目
# 装着"的判据，会被 `check` 当成一个不存在的项目报残渣）。
# ==========================================================================
say "② 账本（$WTOOL_HOME_DIR/var）"
_rec_dir=$WTOOL_HOME_DIR/var/installer
if [ "$DRY_RUN" = 1 ]; then
    say "  [dry-run] 记这次动作：$WTOOL_HOME_DIR/var/（registry.tsv 由引擎写，installer/ 记入口链与时间线）"
else
    mkdir -p -- "$_rec_dir" || die "② 失败：建不了 $_rec_dir（$WTOOL_HOME_DIR 写不进去？）"
    _now=$(date +%Y-%m-%dT%H:%M:%S%z)
    printf '%s\tinstall.sh\t项目=%s\tWTOOL_HOME=%s\n' \
        "$_now" "$proj_rel" "$WTOOL_HOME_DIR" >> "$_rec_dir/actions.tsv" \
        || die "② 失败：写不了 $_rec_dir/actions.tsv"
    # 截断重写（幂等：跑十遍也只有这两行）—— 先写临时文件再 mv，读的人不会撞见半个
    {
        printf 'install.sh\twtool/install.sh\t%s\n' "$_now"
        printf 'wtool/install.sh\t%s/scripts/install.sh\t%s\n' "$proj_rel" "$_now"
    } > "$_rec_dir/links.tsv.tmp" || die "② 失败：写不了 $_rec_dir/links.tsv"
    mv -f -- "$_rec_dir/links.tsv.tmp" "$_rec_dir/links.tsv" || die "② 失败：落不了 $_rec_dir/links.tsv"
    [ -n "$(ls -A -- "$WTOOL_HOME_DIR/var" 2>/dev/null || true)" ] \
        || die "② 失败：$WTOOL_HOME_DIR/var 还是空的（账本没建起来）"
    [ -f "$WTOOL_HOME_DIR/var/registry.tsv" ] \
        || warn "  var/registry.tsv 不在（引擎那一步该写它）—— 后面的 check 会报出来"
    say "  ✔ $_rec_dir/{actions.tsv,links.tsv}；引擎的账在 $WTOOL_HOME_DIR/var/{registry.tsv,<项目>/}"
fi

# ==========================================================================
# 职责③：manifest 三件套
#
#   $WTOOL_HOME/wtool/.repo/manifests/default.xml          ← 保留 `.repo` 段（D18）
#   $WTOOL_HOME/wtool/.repo/manifests/default.xml.sha256
#   $WTOOL_HOME/wtool/.repo/manifests/default.xml.commitid
#
# 两种环境的**唯一区别**（DESIGN §1.6 / §1.10）：
#   · 满血工作区（.repo/projects 且 .repo/project-objects）→ default.xml 是
#     **指向 live 清单的绝对链**，永远跟 live 同步；.sha256/.commitid 现场算。
#   · bundle / 拷贝来的 .wtool（两条缺）→ 三件套**随包而来**，只校验、不覆盖。
#
# 第三种（两者都没有 = DESIGN §1.10 的"只有 wtool 一份"）**不硬失败**：
# 那种机器上本来就没有 manifest，wtool 自己照样能用（`install`/`check` 都不读
# 三件套）；只是 `pack-release` / `pack-offline-release` 用不了 —— 这一条明说。
# ==========================================================================
_man_dir=$WTOOL_HOME_DIR/wtool/.repo/manifests
_man_xml=$_man_dir/default.xml
_man_sha=$_man_xml.sha256
_man_cid=$_man_xml.commitid
_live=$ws/.repo/manifests/default.xml

_hash_of() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

say "③ manifest 三件套（$_man_dir）"
if [ -d "$ws/.repo/projects" ] && [ -d "$ws/.repo/project-objects" ]; then
    # ---- 满血工作区 ----
    [ -f "$_live" ] || die "③ 失败：这是满血工作区（.repo/projects + .repo/project-objects 都在），
       却找不到 live 清单 $_live —— 工作区是坏的，先把它修好再装。"
    if [ "$DRY_RUN" = 1 ]; then
        say "  [dry-run] 满血工作区：default.xml = 指向 live 的绝对链（$_live）"
        say "  [dry-run] .sha256 / .commitid 现场算（sha256sum + git rev-parse HEAD）"
    else
        mkdir -p -- "$_man_dir" || die "③ 失败：建不了 $_man_dir"
        if [ -L "$_man_xml" ]; then
            _cur=$(readlink -f -- "$_man_xml" 2>/dev/null || true)
            if [ "$_cur" = "$_live" ]; then
                say "  default.xml 已经指向 live，跳过"
            else
                say "  default.xml 改指向 live：$_cur -> $_live"
                ln -sfn -- "$_live" "$_man_xml"
            fi
        elif [ -e "$_man_xml" ]; then
            # 同一个位置上有 live 又有包内副本（罕见）——**以 live 为准**（§1.6 备注）
            if [ "$(_hash_of "$_man_xml")" != "$(_hash_of "$_live")" ]; then
                warn "  这里的 default.xml 和 live 清单**不一样** —— 以 live 为准（那份副本换成链）"
            else
                say "  这里的 default.xml 和 live 一致 —— 换成链（免得以后两边跑偏）"
            fi
            rm -f -- "$_man_xml"
            ln -sfn -- "$_live" "$_man_xml"
        else
            ln -sfn -- "$_live" "$_man_xml" || die "③ 失败：建不了链 $_man_xml"
        fi
        _h=$(_hash_of "$_man_xml")
        [ -n "$_h" ] || die "③ 失败：算不出 $_man_xml 的 sha256"
        printf '%s  %s\n' "$_h" "default.xml" > "$_man_sha.tmp" \
            || die "③ 失败：写不了 $_man_sha"
        mv -f -- "$_man_sha.tmp" "$_man_sha"
        _cid=$(git -C "$ws/.repo/manifests" rev-parse HEAD 2>/dev/null || true)
        [ -n "$_cid" ] || die "③ 失败：读不到 live 清单仓的 HEAD
       （git -C $ws/.repo/manifests rev-parse HEAD 失败）—— .commitid 没东西可写"
        printf '%s\n' "$_cid" > "$_man_cid.tmp" || die "③ 失败：写不了 $_man_cid"
        mv -f -- "$_man_cid.tmp" "$_man_cid"
        say "  ✔ default.xml -> $_live（绝对链，永远跟 live 同步）"
        say "  ✔ sha256=$_h  commitid=$_cid"
    fi
elif [ -e "$_man_xml" ] || [ -L "$_man_xml" ]; then
    # ---- bundle / 拷贝来的 .wtool：三件套随包而来，只校验、不覆盖 ----
    if [ "$DRY_RUN" = 1 ]; then
        say "  [dry-run] 包内副本：只校验 .sha256 / .commitid，一个字都不覆盖"
    else
        [ -f "$_man_xml" ] || die "③ 失败：$_man_xml 不是个能读的文件（是悬空链？）
       满血工作区那边没有 repo 元数据，包内这份又读不到 —— 三件套没法校验。"
        [ -f "$_man_sha" ] || die "③ 失败：$_man_sha 不在（三件套不全：包内副本必须自带 .sha256）"
        [ -f "$_man_cid" ] || die "③ 失败：$_man_cid 不在（三件套不全：包内副本必须自带 .commitid）"
        _want=$(cut -d' ' -f1 < "$_man_sha" | head -1)
        _got=$(_hash_of "$_man_xml")
        [ -n "$_want" ] || die "③ 失败：$_man_sha 是空的，校验不了"
        if [ "$_want" != "$_got" ]; then
            die "③ 失败：default.xml 和它的 .sha256 **对不上** —— 包坏了 / 被改过，停手。
      $_man_sha 里记的是：$_want
      $_man_xml 实际的  ：$_got
      修法：重新解一次包（别手工改这两个文件），或者拿一份带三件套的 .wtool 过来。"
        fi
        _cid=$(head -1 "$_man_cid" | tr -d '[:space:]')
        case $_cid in
            ''|*[!0-9a-fA-F]*)
                die "③ 失败：$_man_cid 里不是一个 commit id：「$_cid」" ;;
        esac
        say "  ✔ 包内副本校验通过：sha256=$_got  commitid=$_cid（只校验，没覆盖）"
    fi
else
    # ---- 只有 wtool 一份（DESIGN §1.10）：没有 manifest 可用 ----
    warn "③ 这台机器上**没有 manifest 可用**：既不是满血工作区
      （缺 $ws/.repo/projects 或 .repo/project-objects），包内也没有
      $_man_xml —— 三件套建不出来。
      wtool 自己照样能用（install / check 都不读三件套），但
      pack-release / pack-offline-release 这类要 manifest 的命令用不了。
      等你有满血工作区、或拿到带三件套的包，再跑一次 install.sh 就有了。"
fi

# ==========================================================================
# 职责④：env.{zsh,bash} —— **先**加载安装器项目自己
#
# 它们是引擎在 ① 里按 (priority, 项目路径) 现算出来的汇总（ADR-0045 §1.2 / D48）：
# 每个项目的 env 块按 priority 升序 source，安装器项目 priority=5（最早）——
# 所以 `wtool` 命令、`$WTOOL_HOME/usr/bin` 一定先于别的项目就位。
# ==========================================================================
say "④ env.{zsh,bash}（先加载安装器项目自己，保证 wtool 可用）"
if [ "$DRY_RUN" = 1 ]; then
    say "  [dry-run] 校验 $WTOOL_HOME_DIR/env.{zsh,bash} 在，且第一个块是 $proj_rel"
else
    [ -f "$WTOOL_HOME_DIR/env.zsh" ] \
        || die "④ 失败：$WTOOL_HOME_DIR/env.zsh 没建出来（引擎的 env 汇总那一步没走到）"
    [ -f "$WTOOL_HOME_DIR/env.bash" ] \
        || die "④ 失败：$WTOOL_HOME_DIR/env.bash 没建出来（同上；两个 shell 都得有，不然没 zsh 的机器上用不了）"
    _first=$(awk '/^# --- wtool:/{sub(/^# --- wtool:/,""); sub(/ \(priority.*/,""); print; exit}' \
             "$WTOOL_HOME_DIR/env.zsh" 2>/dev/null || true)
    case $_first in
        "$proj_rel") say "  ✔ 第一个 env 块就是安装器项目自己（priority 最小 = 最先加载）" ;;
        "")          warn "  env.zsh 里一个 env 块都没有 —— 安装器项目的 env 没进去（看它的 wtool.xml）" ;;
        *)           warn "  第一个 env 块是「$_first」，不是安装器项目「$proj_rel」—— 如果 wtool 命令找不到，先看这两个的 priority" ;;
    esac
fi

# ==========================================================================
# 职责⑤：自检 —— 起一个**新的** zsh/bash 子进程，在里面 source env.<shell>
#         并跑 `wtool check` 当验收
#
# 为什么要起新进程：**当前这个 shell 里 PATH 是启动时定下的**，光看自己说明不了
# "新开的终端里 wtool 能用"。判据必须是"新进程 + 只 source 那个文件"。
# 而且 PATH 要先**摘掉** wtool 的目录 —— 不然"wtool 能用"可能只是这个 shell
# 本来就带着它，验不出 env.<shell> 到底有没有干活。
#
# 退出码（非 0 = 这一步没过，install.sh 也跟着非 0）：
#   3 = source env.<shell> 就失败   4 = source 之后找不到 wtool 命令
#   5 = \$WTOOL_HOME/usr/bin 不在 PATH 里   6 = wtool check 报了问题
#
# ‼️ 子进程里**只摘 WTOOL_\***（而不是 `env -i` 清空一切）：容器验收里实测撞过 ——
#    python3 是宿主挂进来的，靠 `LD_LIBRARY_PATH` 找 libexpat，`env -i` 一清就
#    "error while loading shared libraries: libexpat.so.1"（引擎还没跑就死了）。
#    "干净"要的是"**没有 wtool 的痕迹**"：所有引擎变量都是 `WTOOL_` 前缀，
#    逐个 -u 掉即可；PATH 也换成摘掉 wtool 目录的那一份。这比 `env -i` 更像
#    "用户新开一个终端"（新终端当然继承机器的库路径与 locale）。
# ==========================================================================
say "⑤ 自检：起新进程 source env.<shell> + wtool check"
_selfcheck_ok=0
if [ "$DRY_RUN" = 1 ]; then
    say "  [dry-run] 起 zsh / bash 子进程：. \$WTOOL_HOME/env.<shell>; command -v wtool; wtool check"
    _selfcheck_ok=1
else
    _clean_path=$(printf '%s' "${PATH:-/usr/bin:/bin}" | tr ':' '\n' \
        | awk -v h="$WTOOL_HOME_DIR" -v p="$proj" \
              'length($0) && index($0,h)==0 && index($0,p)==0 {printf "%s%s", sep, $0; sep=":"}')
    [ -n "$_clean_path" ] || _clean_path=/usr/bin:/bin
    # 要摘掉的变量（-u 列表）：环境里所有 WTOOL_ 开头的（引擎自己导出的那一批）
    _unset_args=""
    for _uv in $(env | sed -n 's/^\(WTOOL[A-Za-z_]*\)=.*/-u \1/p'); do
        _unset_args="$_unset_args $_uv"
    done

    for _sh in zsh bash; do
        if ! command -v "$_sh" >/dev/null 2>&1; then
            say "  $_sh：这台机器上没有，跳过"
            continue
        fi
        _log=$_rec_dir/selfcheck.$_sh.log
        # ‼️ 判据是"**这个** WTOOL_HOME 里的 wtool"，不只是"PATH 上有 wtool" ——
        #    机器上装过两份时，光看 `command -v` 会被**另一份**蒙过去（实测：
        #    跑测试那个 shell 的 PATH 里本来就有别的 wtool，这一步就成了假绿）。
        _code="WTOOL_HOME=\$1; export WTOOL_HOME
. \"\$WTOOL_HOME/env.$_sh\" || { echo \"SELFCHECK-FAIL source env.$_sh 失败\"; exit 3; }
_w=\$(command -v wtool 2>/dev/null) || _w=''
[ -n \"\$_w\" ] || { echo 'SELFCHECK-FAIL source 之后找不到 wtool 命令'; exit 4; }
case \"\$_w\" in \"\$WTOOL_HOME\"/*) ;; *) echo \"SELFCHECK-FAIL wtool 解析到 \$_w —— 不在 \$WTOOL_HOME 里（PATH 上是不是有别的 wtool？）\"; exit 4 ;; esac
case \":\$PATH:\" in *\":\$WTOOL_HOME/usr/bin:\"*) ;; *) echo 'SELFCHECK-FAIL PATH 里没有 \$WTOOL_HOME/usr/bin'; exit 5 ;; esac
echo \"SELFCHECK-OK wtool=\$_w\"
wtool check || exit 6"
        _rc=0
        # shellcheck disable=SC2086
        env $_unset_args HOME="$HOME_DIR" PATH="$_clean_path" \
            "$_sh" -c "$_code" _ "$WTOOL_HOME_DIR" > "$_log" 2>&1 || _rc=$?
        if [ "$_rc" = 0 ]; then
            say "  $_sh：✔ $(sed -n 's/^SELFCHECK-OK //p' "$_log" | head -1)"
            say "        （PATH 摘掉了 wtool 目录、WTOOL_* 也全摘了 —— wtool 是 source env.$_sh 之后才有的）"
            _selfcheck_ok=1
            continue
        fi
        # 没过：把子进程看到的东西原样贴出来，并说清是哪一步
        case $_rc in
            3) _why="source \$WTOOL_HOME/env.$_sh 就失败了" ;;
            4) _why="source 之后**找不到 wtool 命令**，或者它解析到的不是 \$WTOOL_HOME 里那一个（env 块里的 PATH 没生效）" ;;
            5) _why="PATH 里**没有 \$WTOOL_HOME/usr/bin**" ;;
            6) _why="\`wtool check\` 报了问题（工作区里那些项目的账对不上）" ;;
            *) _why="子进程退出码 $_rc" ;;
        esac
        warn "  $_sh：✘ 第 ⑤ 步没过 —— $_why"
        sed 's/^/        /' "$_log" >&2
        if [ "$_rc" = 6 ]; then
            # 分清"装坏了"和"工作区里别的项目有旧账"—— 后者不该让人以为安装器坏了
            _only=0
            # shellcheck disable=SC2086
            env $_unset_args HOME="$HOME_DIR" PATH="$_clean_path" "$_sh" -c \
                "WTOOL_HOME=\$1; export WTOOL_HOME; . \"\$WTOOL_HOME/env.$_sh\" >/dev/null 2>&1; wtool check \"\$2\"" \
                _ "$WTOOL_HOME_DIR" "$proj_rel" >> "$_log" 2>&1 || _only=$?
            if [ "$_only" = 0 ]; then
                warn "        上面那些**不是安装器自己的问题**：只看「$proj_rel」是干净的（wtool check $proj_rel 退出 0）"
            else
                warn "        只看「$proj_rel」也不干净 —— 这是安装器自己那一份没装对"
            fi
        fi
        warn "        这一轮的自检输出留在：$_log"
    done
    [ "$_selfcheck_ok" = 1 ] \
        || die "⑤ 失败：zsh / bash 里**没有一个**能通过验收（上面写了每个失败在哪一步）。
       wtool 可能已经装上了，但"source env 就能用"这个承诺没兑现 —— 修好再重跑一次 ./install.sh。"
fi

# ==========================================================================
# 职责⑥：rc 两行 —— **问过用户才改**
#
# 用户 rc 的**最后两行**（ADR-0045 §1.2 / D48）：
#     export WTOOL_HOME=~/.wtool
#     source ${WTOOL_HOME}/env.zsh          （bash 用户写 env.bash）
#
# 默认**只打印**。只有两种"用户明确同意"才代写：
#   · 交互确认（有终端时问一句，回答 y）；
#   · `--write-rc`（你在命令行上已经说了要写）。
# 非交互（管道 / `< /dev/null` / CI）**不问、不写、也不挂住** —— 只打印。
# ==========================================================================
if [ "$WTOOL_HOME_DIR" = "$HOME_DIR/.wtool" ]; then
    _rc_home_line="~/.wtool"                      # 装在默认位置 → 写 `~`（换个用户名也能用）
else
    _rc_home_line=$WTOOL_HOME_DIR
fi

# 这个 rc 里已经有那两行了吗（幂等判据：两行都在就算）
rc_has_lines() {   # <rc 文件> <shell>
    _rh_f=$1; _rh_sh=$2
    [ -f "$_rh_f" ] || return 1
    grep -qE "^[[:space:]]*export[[:space:]]+WTOOL_HOME=" "$_rh_f" 2>/dev/null || return 1
    grep -qE "^[[:space:]]*(source|\.)[[:space:]]+\\\$\{?WTOOL_HOME\}?/env\.$_rh_sh([[:space:]]*#.*)?[[:space:]]*$" \
        "$_rh_f" 2>/dev/null || return 1
    return 0
}

rc_write() {   # <rc 文件> <shell>
    _rw_f=$1; _rw_sh=$2
    if rc_has_lines "$_rw_f" "$_rw_sh"; then
        say "  $_rw_f 里已经有那两行了，跳过"
        return 0
    fi
    # 结尾没有换行就先补一个，否则新加的两行会和上一行粘在一起
    if [ -s "$_rw_f" ] && [ -n "$(tail -c 1 -- "$_rw_f" 2>/dev/null || true)" ]; then
        printf '\n' >> "$_rw_f"
    fi
    {
        printf '\n'
        printf 'export WTOOL_HOME=%s\n' "$_rc_home_line"
        printf 'source ${WTOOL_HOME}/env.%s\n' "$_rw_sh"
    } >> "$_rw_f" || die "⑥ 失败：写不了 $_rw_f"
    say "  ✔ 已写进 $_rw_f（最后两行）"
}

# 2026-10-21（用户 VM 实测）：home 模式**缺 rc 就新建**。
#
# 旧逻辑只往「已存在」的 rc 追加 —— 那台机器原本没有 `~/.zshrc`，于是装完
# 什么都没留下，用户只好自己手写两行；手写之后才第一次触发 direnv / zsh 那两个坑，
# 看起来就像"install.sh 没干活"。规矩应当是：
#   · 改**已有**文件 = 动别人的东西 → 问过才写（上面的 rc_write）；
#   · 建**本来没有**的文件 = 不破坏任何东西 → 直接建，并在输出里说清楚。
rc_create() {   # <rc 文件> <shell>   —— 只在文件**不存在**时调用
    _rc_f=$1; _rc_sh=$2
    mkdir -p -- "$(dirname -- "$_rc_f")" 2>/dev/null || true
    {
        printf '# ~/.%src\n' "$_rc_sh"
        printf '# 由 wtool 的 install.sh 创建（这台机器上原来没有这个文件）。\n'
        printf 'export WTOOL_HOME=%s\n' "$_rc_home_line"
        printf 'source ${WTOOL_HOME}/env.%s\n' "$_rc_sh"
    } > "$_rc_f" || die "⑥ 失败：建不了 $_rc_f"
    say "  ✔ 新建 $_rc_f（写入那两行）"
}

# `~/.zshenv` 里那段 module_path/fpath —— **专门为"zsh 当登录 shell"** 的情形。
#
# 为什么必须有：zsh 的 `module_path`/`fpath` 是**编译时前缀**（构建容器里的
# `/root/.wtool/usr/…`），换机器就加载不到动态模块（`zsh/zle`、`zsh/parameter`…），
# 而 `MODULE_PATH` **不允许从环境导入**。`.zshenv` 在**任何 rc、任何模块加载之前**
# 执行，是唯一能修它的地方（2026-10-21 VM 实测：`zsh: failed to load module 'zsh/zle'`）。
# 从 bash 敲 `zsh` 的情形由项目 `env.*` 导出的 ZDOTDIR 走 `$WTOOL_HOME/.zshenv`，两条路都覆盖。
zsh_module_path_write() {
    _zs=$HOME_DIR/.zshenv
    if [ -f "$_zs" ] && grep -qF '# >>> wtool: zsh module_path >>>' "$_zs" 2>/dev/null; then
        say "  ✔ $_zs 里已经有 wtool 的 module_path 段（跳过）"
        return 0
    fi
    if [ -s "$_zs" ] && [ -n "$(tail -c 1 -- "$_zs" 2>/dev/null || true)" ]; then
        printf '\n' >> "$_zs"
    fi
    cat >> "$_zs" <<EOF || die "⑥ 失败：写不了 $_zs"
# >>> wtool: zsh module_path >>>
# 由 wtool 的 install.sh 写（幂等，重装不会重复）。删掉这段 → zsh 会去
# 构建容器里的老前缀找动态模块，症状是
# zsh: failed to load module 'zsh/zle' / 'zsh/parameter': ... Permission denied
if [ -n "\${ZSH_VERSION:-}" ] && [ -d "$WTOOL_HOME_DIR/usr/lib/zsh" ]; then
    module_path=("$WTOOL_HOME_DIR/usr/lib/zsh/\$ZSH_VERSION" \$module_path)
    fpath=("$WTOOL_HOME_DIR/usr/share/zsh/\$ZSH_VERSION/functions" "$WTOOL_HOME_DIR/usr/share/zsh/site-functions" \$fpath)
fi
# <<< wtool: zsh module_path <<<
EOF
    say "  ✔ 已写 $_zs（zsh 的 module_path 段）"
}

# portable 模式：**生成两份 rc 文件**（用户手动 source），一个字节都不碰 \$HOME 里的 rc。
# 内容按用户 2026-10-21 给的样子：WTOOL_HOME + PATH（含引擎 bin）+ 库路径 + source env。
# 幂等：重复 source 不叠加 PATH / LD_LIBRARY_PATH（下面两个 case 守卫）。
_write_portable_rc() {   # <shell:bash|zsh>
    _pr_shell=$1
    _pr_dir=$(dirname -- "$WTOOL_HOME_DIR")
    _pr_out="$_pr_dir/wtool-${_pr_shell}rc"
    [ "$DRY_RUN" = 1 ] && { say "  [dry-run] 会生成 $_pr_out"; return 0; }
    {
        printf '# 由 wtool 的 install.sh 生成（2026-10-21，portable 模式：借用机器用）。\n'
        printf '# 用法： source %s\n' "$_pr_out"
        printf '# 这台机器的 %s/.bashrc 可能不是你的，所以 wtool **不碰它**。\n' "$HOME_DIR"
        printf 'export WTOOL_HOME=%s\n' "$WTOOL_HOME_DIR"
        printf 'case ":$PATH:" in\n'
        printf '    *":$WTOOL_HOME/usr/bin:"*) ;;\n'
        printf '    *) export PATH="$WTOOL_HOME/usr/bin:$WTOOL_HOME/wtool/%s/bin:$PATH" ;;\n' "$proj_rel"
        printf 'esac\n'
        printf 'case ":${LD_LIBRARY_PATH:-}:" in\n'
        printf '    *":$WTOOL_HOME/usr/lib:"*) ;;\n'
        printf '    *) export LD_LIBRARY_PATH="$WTOOL_HOME/usr/lib:$WTOOL_HOME/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;\n'
        printf 'esac\n'
        printf '[ -f "$WTOOL_HOME/env.%s" ] && . "$WTOOL_HOME/env.%s"\n' "$_pr_shell" "$_pr_shell"
        # 幂等（用户要求：重复 source 不叠加）—— env.* 里各项目的块是**无条件**
        # prepend 的，source 两次就多两份。这里按"第一次出现"去重：
        #   [A,B] 再 prepend 一次 A,B → [A,B,A,B] → 去重 → [A,B]（稳定）
        printf '# 去重：重复 source 也不叠加 PATH / LD_LIBRARY_PATH\n'
        printf 'PATH=$(printf %%s "$PATH" | tr ":" "\\n" | awk "!seen[\\$0]++" | paste -sd: -)\n'
        printf 'export PATH\n'
        printf 'if [ -n "${LD_LIBRARY_PATH:-}" ]; then\n'
        printf '    LD_LIBRARY_PATH=$(printf %%s "$LD_LIBRARY_PATH" | tr ":" "\\n" | awk "!seen2[\\$0]++" | paste -sd: -)\n'
        printf '    export LD_LIBRARY_PATH\n'
        printf 'fi\n'
    } > "$_pr_out" || die "⑥ 失败：写不了 $_pr_out"
    say "  ✔ 生成 $_pr_out"
}

if [ "$RC_MODE" = file ]; then
    say "⑥ portable 模式：生成 wtool-bashrc / wtool-zshrc（**不改** ~/.bashrc / ~/.zshrc）"
    _write_portable_rc bash
    _write_portable_rc zsh
    _pr_dir=$(dirname -- "$WTOOL_HOME_DIR")
    cat <<TIP

  下一步（在这台机器上**手动**执行一次，或者写进你自己的启动脚本）：

      source $_pr_dir/wtool-bashrc        # zsh 用户：source $_pr_dir/wtool-zshrc

  之后 `wtool` 命令、`$WTOOL_HOME/usr/bin` 都在 PATH 上了；想验证：`wtool check`

TIP
fi

if [ "$RC_MODE" != "file" ] && [ "$RC_MODE" != "none" ]; then
say "⑥ rc 两行（默认只打印，问过你才代写）"


# 这个 shell 的 rc 文件（只认存在的；没建过的 rc 绝不代建）
rc_file_of() {   # <shell> → 打印 rc 路径
    case $1 in
        zsh)  printf '%s' "$HOME_DIR/.zshrc" ;;
        *)    printf '%s' "$HOME_DIR/.bashrc" ;;
    esac
}

# 缺的 rc 先建出来（建一个本来不存在的文件不算"改你的东西"，不需要问）；
# 已存在的仍走下面的 case（ask/write/print）。
# 2026-10-21 VM 实测：这段原来被我放在 `else`（"rc 缺两行"那支）里，
# 而 VM 上 `.bashrc`/`.zshrc` 都已有两行 → `_rc_targets` 为空 → 从没执行过 →
# `~/.zshenv` 没被创建。**必须在分支之前**，与 rc 有没有那两行无关。
if [ "$DRY_RUN" != 1 ]; then
    for _sh in zsh bash; do
        _rc_f=$(rc_file_of "$_sh")
        [ -e "$_rc_f" ] || rc_create "$_rc_f" "$_sh"
    done
    # zsh 当登录 shell / 从没 source 过 wtool env 的 shell 里敲 zsh 时，
    # 都走不到 env.* —— 这条单独补在 ~/.zshenv（幂等，靠固定标记判重）。
    zsh_module_path_write
fi

_rc_targets=""
for _sh in zsh bash; do
    _rc_f=$(rc_file_of "$_sh")
    [ -f "$_rc_f" ] || continue
    rc_has_lines "$_rc_f" "$_sh" && continue
    _rc_targets="$_rc_targets $_rc_f"
done

if [ -z "$_rc_targets" ]; then
    say "  ✔ 该有的 rc 里都已经有那两行了（或者你还没建 rc 文件）—— 不用改任何东西"
else
    cat <<TIP

  还差一步：把**这两行**加到你的 rc **最后**（你用的是哪个 shell 就加哪个）：

      export WTOOL_HOME=$_rc_home_line
      source \${WTOOL_HOME}/env.zsh        # bash 用户写 env.bash

TIP
    for _sh in zsh bash; do
        _rc_f=$(rc_file_of "$_sh")
        [ -f "$_rc_f" ] || continue
        say "      $_rc_f ：source \${WTOOL_HOME}/env.$_sh"
    done

    _do_write=0
    case $RC_MODE in
        write) _do_write=1; say "  --write-rc：按你的命令行授权直接写" ;;
        print) _do_write=0; say "  --no-rc：只打印，不碰你的 rc" ;;
        ask)
            if [ -t 0 ] && [ -t 1 ]; then
                printf 'wtool-install: 要我把上面那两行写进%s 吗？[y/N] ' "$_rc_targets"
                _ans=""
                read -r _ans || _ans=""
                case $_ans in
                    y|Y|yes|YES|Yes) _do_write=1 ;;
                    *)               _do_write=0 ;;
                esac
            else
                say "  没有终端可以问（非交互）—— 只打印，一个字节都不动你的 rc"
            fi ;;
    esac

    if [ "$_do_write" = 1 ]; then
        if [ "$DRY_RUN" = 1 ]; then
            say "  [dry-run] 会写进：$_rc_targets"
        else
            for _sh in zsh bash; do
                _rc_f=$(rc_file_of "$_sh")
                [ -f "$_rc_f" ] || continue
                rc_write "$_rc_f" "$_sh"
            done
            say "  ✔ 写好了。新开一个终端（或 exec \$SHELL）就生效。"
        fi
    else
        say "  （wtool **不会**替你改 rc —— 上面那两行自己贴一下就行）"
    fi
fi
fi

# --------------------------------------------------------------------------
# 这一轮的本机日志（ADR-0045 §1.9：日志不跟着迁移、随时可删）。
# 目录是引擎在 ① 里建的那个"最新"目录，这里只追一行安装器自己的流水。
# 一整段都是**尽力而为**：写不进去也不该让安装失败。
# --------------------------------------------------------------------------
if [ "$DRY_RUN" != 1 ]; then
    _log_root=${WTOOL_LOG_ROOT:-${XDG_STATE_HOME:-$HOME_DIR/.local/state}/wtool}
    _log_latest=$(ls -1d -- "$_log_root"/wtool-logs-* 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)
    if [ -n "$_log_latest" ] && [ -d "$_log_latest" ]; then
        {
            printf 'install.sh\t%s\t项目=%s\tWTOOL_HOME=%s\n' \
                "$(date +%Y-%m-%dT%H:%M:%S%z)" "$proj_rel" "$WTOOL_HOME_DIR"
            printf '自检\t%s\tzsh/bash 子进程 source env + wtool check 通过\n' \
                "$(date +%Y-%m-%dT%H:%M:%S%z)"
        } >> "$_log_latest/installer.log" 2>/dev/null || true
    fi
fi

# ==========================================================================
# 完成。**在这里停下**，把下一步交给用户。
# ==========================================================================
_rc=""
[ -f "$HOME_DIR/.zshrc" ] && _rc="~/.zshrc"
[ -f "$HOME_DIR/.bashrc" ] && _rc="${_rc:+$_rc 和 }~/.bashrc"

cat <<TIP

  ────────────────────────────────────────────────────────────
  装好了。这个脚本只负责让 wtool 能用，**没有装任何项目**。

  重新开一个终端（或 exec \$SHELL）之后：
$([ -n "$_rc" ] && printf '      # %s 里那两行就会自动生效\n' "$_rc")

  然后**两步**：先系统层，再用户层（分开是有意的，失败原因完全不同）：

      wtool                # 看项目表：每个项目支持什么、走到哪一步了
      wtool sudo-bootstrap # 系统层：apt 包 + /etc 下的文件（**可能要 sudo、要联网**）
      wtool bootstrap      # 用户层：文件、软链、shell 集成（不要 sudo、不联网）

  wtool bootstrap 不会替你做这些决定，需要时才自己跑：
      wtool build    <项目>    自己编（小时级；声明要容器而本机没有 docker 时会直接拒绝）
      wtool download-release <项目>   从发布页下现成的包到 __release/（分钟级）
      wtool unpack-release   <项目>   照包自带的 dist.json 校验 + 拼卷 + 解到 __output/
      wtool install  <项目>    登记 + 软链 + shell 集成
      wtool uninstall <项目路径>   撤掉（只撤用户层）
      wtool move     <旧路径> <新路径>   项目改名（卸旧的 + mv + 装新的）
      wtool sudo-uninstall <项目>|all   撤系统层（/etc 还原 + 卸掉这次装进来的 apt 包）

  自己发一版（都要先提交，发布只发 __release/ 里已有的东西）：
      wtool pack-release    <项目>    __output/ → __release/（打包 + 分卷，不联网）
      wtool publish-release <项目>    __release/ → GitHub（只上传，成功后写 scripts/release.json）

  想知道每个命令到底做什么，看 README 的第 4 节「这些脚本分别干什么」。
  ────────────────────────────────────────────────────────────

TIP
