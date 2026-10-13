#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wtool_zip —— 打包/解包工具（引擎执行层调用，不是规划器）。

为什么不用系统的 `zip` 命令：这台机器上的 Info-ZIP **不设 UTF-8 名字标志**
（实测 `zip -UN=UTF8 源码.txt` 出来的条目 flag_bits=0，用别的工具解开是乱码），
而我们的归档里**条目名**有中文（`wtool-base/原理.md` 这种路径；资产名本身
从 2026-10-09 起是 ASCII 的 `source.zip` / `release.zip` —— GitHub 不接受
非 ASCII 资产名，见 harness/docs/hazards.md H27）。python3 的 zipfile 是
标准库（引擎本来就依赖 python3），会正确设置 UTF-8 标志，还顺带解决了
"权限位要不要留住"（output 里的可执行文件必须留住）。

它和 tar/gzip 一样只是个**工具**：由 lib/wtool_fs.sh 调用，
只写调用方指定的路径，自己不做任何决定。

用法：
  wtool_zip.py create  <out.zip> <base-dir> <list-file>
      列表文件里是相对 base-dir 的路径（一行一个），必须已按名排序 ——
      这样同样的树打出来的字节是一样的。
      --prefix=P                      包内路径前缀
      --extra <绝对路径> <包内路径>    额外塞一个文件/软链（不加前缀）
  wtool_zip.py create-tar <out.tar.gz> <base-dir> <list-file>
      同上，但打的是 **tar.gz** —— 安装器包 `wtool-base-tools.tar.gz` 是 tar
      （用户那条命令是 `tar xzf`，见 ADR-0045 / D59）。uid/gid/mtime 归零、
      gzip 头不带文件名，所以同样的内容打出来字节一样。
  wtool_zip.py extract <zip> <dest-dir>
      按 zip 里的路径铺开；拒绝 .. 与绝对路径；还原 unix 权限位；
      软链条目按软链建（跟随软链打包的包不受影响）。
  wtool_zip.py extract-tree <zip|tar.gz|tar.xz> <dest-dir> --from=<glob>
      **声明式解包**（ADR-0045 / D57）：只取归档里匹配 <glob> 的成员，并把 glob 里
      **第一个通配符之前的目录前缀**剥掉，余下部分铺到 dest-dir 下。
      例：--from='__output/**'、dest=<项目>/__output
          → 归档里的 `__output/ubuntu_24.04/usr/bin/zsh`
            落在 `<项目>/__output/ubuntu_24.04/usr/bin/zsh`。
      一个都没匹配上 → 报错（不静默成功：那说明 release.json 的对照表写错了）。
  wtool_zip.py extract-member <资产> <dest-file> [--member=<归档内成员>]
      **② muslbin 的取货口**（ADR-0045 第 ⑦.2 块 / `<muslbin member= dest=>`）：
      从上游资产里取出**一个成员**，写到 dest-file（父目录自动建，权限 0755）。
        · 资产是 `.zip` / `.tar.gz` / `.tgz` / `.tar` / `.tar.xz` / `.txz` →
          必须有 --member=<成员名>；找不到那个成员 → 报错并列出归档里**有哪些**
          （不静默成功）。
        · 资产是**裸文件**（jq / yq / shfmt / b3sum 那种没有归档的）→ 不带 --member，
          资产本身就是那个二进制。
      ⚠️ 归档只按**扩展名**认（不猜内容）；认得出是归档、但不是上面这几种压缩的
      （如 `.tar.zst`）→ 报错，绝不静默当成裸文件（那会装出一个敲了就
      `exec format error` 的"二进制"）。
"""

import fnmatch
import gzip
import os
import shutil
import stat
import sys
import tarfile
import zipfile

# 打包时间固定成 zip 能表达的最早时间：归档里不该有"什么时候打的"，
# 那样同样的内容每次打出来字节不同（依赖它算 sha256 的分卷就对不上了）。
FIXED_DATE = (1980, 1, 1, 0, 0, 0)

# 支持的归档格式（**按扩展名认，不猜内容**）。今天用得到的就这些：
# ③ 的 release.zip、离线自足包 release-offline.zip / source-offline.zip 是 zip；
# ② 的上游资产绝大多数是 .tar.gz（29 个里 23 个），两个是 .zip，
# 四个（jq/yq/shfmt/b3sum）**根本没有归档**，资产本身就是二进制。
# `.tar.xz` / `.txz` 是第 ⑦.3 块加的：上游只发 `.tar.xz` 的有好几家
# （watchexec、csvlens），而解压不需要新依赖 —— `tarfile.open(…, "r:*")`
# 按内容自动认，lzma 是 python 标准库（没有外部 `xz` 命令也能解）。
ARCHIVE_EXTS = (".zip", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz")
# 认得出是压缩包、但今天不支持的：**报错**，不静默当裸文件（见 extract-member 的说明）
ARCHIVE_LIKE_EXTS = (".tar.bz2", ".tbz2", ".tar.zst",
                     ".tzst", ".7z", ".rar", ".lz4", ".lz", ".zst")


def die(msg):
    sys.stderr.write("wtool_zip: error: %s\n" % msg)
    return 1


def archive_kind(path):
    """`.zip` → "zip"；`.tar` / `.tar.gz` / `.tgz` / `.tar.xz` / `.txz` → "tar"；其余 → ""。"""
    low = path.lower()
    if low.endswith(".zip"):
        return "zip"
    if low.endswith((".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz")):
        return "tar"
    return ""


def _norm_member(name):
    """成员名归一：`\\` → `/`、去掉前导 `./`、去掉首尾 `/`。

    两边都要归一：归档里可能是 `eza`，而清单里写的是 `./eza`（**实测**：
    `tools/musl-bins/eza/wtool.xml` 就写着 `member="./eza"`）。
    """
    n = name.replace("\\", "/")
    while n.startswith("./"):
        n = n[2:]
    return n.strip("/")


def safe_join(dest, name):
    """zip 里的路径 -> 落点；越界（..、绝对路径、盘符）返回 None。"""
    name = name.replace("\\", "/")
    if name.startswith("/") or (len(name) > 1 and name[1] == ":"):
        return None
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        return None
    if not parts:
        return None
    return os.path.join(dest, *parts)


def do_create(out, base, listfile, prefix="", extras=()):
    with open(listfile, encoding="utf-8", errors="surrogateescape") as fh:
        names = [line.rstrip("\n") for line in fh if line.strip()]
    if not names and not extras:
        return die("文件列表是空的: %s" % listfile)
    tmp = out + ".tmp.%d" % os.getpid()
    entries = [(prefix + n, os.path.join(base, n)) for n in names]
    # --extra 给的是**包内完整路径**，不再加前缀
    entries += [(arc, src) for arc, src in extras]
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as zf:
        for arc, src in entries:
            if not os.path.lexists(src):
                os.unlink(tmp)
                return die("列表里的文件不存在: %s" % src)
            info = zipfile.ZipInfo(arc, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            if os.path.islink(src):
                # **软链要留着是软链**，不是跟着它把内容拷一份：
                # 源码树里 themes/x.zsh-theme -> real.zsh-theme 这种相对链，
                # 拷成实体文件之后目录结构和链接关系就没了
                # （tar 时代踩过：--transform 连指向一起改写，解压全是断链）。
                target = os.readlink(src)
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                zf.writestr(info, target.encode("utf-8", "surrogateescape"))
                continue
            st = os.lstat(src)          # 不跟随：权限位用文件自己的
            info.external_attr = (stat.S_IMODE(st.st_mode) & 0xFFFF) << 16
            if os.path.isdir(src):
                info.external_attr |= 0x10
                zf.writestr(info, b"")
                continue
            with open(src, "rb") as fh:
                zf.writestr(info, fh.read())
    os.replace(tmp, out)
    return 0


def do_extract(archive, dest):
    if not os.path.isfile(archive):
        return die("包不存在: %s" % archive)
    os.makedirs(dest, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            target = safe_join(dest, info.filename)
            if target is None:
                return die("包里有越界路径，拒绝解开: %s" % info.filename)
            mode = (info.external_attr >> 16) & 0xFFFF
            if info.is_dir() or stat.S_ISDIR(mode):
                os.makedirs(target, exist_ok=True)
                continue
            if stat.S_ISLNK(mode):
                link_to = zf.read(info).decode("utf-8", "surrogateescape")
                if os.path.lexists(target):
                    os.unlink(target)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                os.symlink(link_to, target)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(info) as src, open(target, "wb") as fh:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    fh.write(chunk)
            if mode:
                os.chmod(target, stat.S_IMODE(mode))
    return 0


def _read_list(listfile):
    with open(listfile, encoding="utf-8", errors="surrogateescape") as fh:
        return [line.rstrip("\n") for line in fh if line.strip()]


def do_create_tar(out, base, listfile, prefix="", extras=()):
    """和 do_create 同一张清单，但打 tar.gz（安装器包要 `tar xzf` 才解得开）。"""
    names = _read_list(listfile)
    if not names and not extras:
        return die("文件列表是空的: %s" % listfile)
    tmp = out + ".tmp.%d" % os.getpid()
    entries = [(prefix + n, os.path.join(base, n)) for n in names]
    entries += [(arc, src) for arc, src in extras]      # --extra 给的是包内完整路径
    for _arc, src in entries:
        if not os.path.lexists(src):
            return die("列表里的文件不存在: %s" % src)
    # mtime=0 + 不带文件名：同样的内容每次打出来字节一样（和 zip 那条同一个理由）
    with open(tmp, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w",
                              format=tarfile.GNU_FORMAT) as tf:
                for arc, src in entries:
                    info = tf.gettarinfo(src, arcname=arc)
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    if info.islnk() or info.issym():
                        tf.addfile(info)             # 软链：只写链本身（不跟进去）
                        continue
                    if info.isdir():
                        tf.addfile(info)
                        continue
                    with open(src, "rb") as fh:
                        tf.addfile(info, fh)
    os.replace(tmp, out)
    return 0


def glob_base(glob):
    """`from` 的目录前缀：**第一个通配符之前**最后一个 `/`（含它）。

    解包时剥掉这一段，余下的路径拼到 `to` 下面（见 extract-tree 的说明）。
    `__output/**` → `__output/`；`wtool.xml`（没有通配符）→ ``（原样保留）。
    """
    cut = len(glob)
    for ch in "*?[":
        pos = glob.find(ch)
        if pos >= 0:
            cut = min(cut, pos)
    head = glob[:cut]
    slash = head.rfind("/")
    return head[:slash + 1] if slash >= 0 else ""


def iter_members(archive):
    """统一的成员视图：**zip 和 tar.gz 走同一段代码**（yield 期间归档保持打开）。

    yield `(name, isdir, link_to, mode, opener)`：
      name      成员名（`\\` 统一成 `/`；**不**去 `./` 前缀，匹配时两边都归一）
      isdir     目录
      link_to   软链目标（None = 不是软链）
      mode      权限位（0 = 归档里没记）
      opener    0 参可调用 → 二进制流（当上下文管理器用；目录/软链是 None）
    """
    kind = archive_kind(archive)
    if kind == "zip":
        with zipfile.ZipFile(archive) as zf:
            for info in zf.infolist():
                name = info.filename.replace("\\", "/")
                mode = (info.external_attr >> 16) & 0xFFFF
                isdir = info.is_dir() or stat.S_ISDIR(mode)
                link = None
                if stat.S_ISLNK(mode):
                    link = zf.read(info).decode("utf-8", "surrogateescape")
                yield (name, isdir, link, stat.S_IMODE(mode),
                       (lambda info=info: zf.open(info)))
        return
    if kind == "tar":
        # "r:*" 按内容自动认压缩（gz/bz2/xz 都认）。调用方已经把"扩展名不认识"
        # 的挡在外面了，所以这里不会悄悄解开一个我们不支持的格式。
        with tarfile.open(archive, "r:*") as tf:
            for m in tf.getmembers():
                if m.isdir():
                    yield (m.name, True, None, stat.S_IMODE(m.mode), None)
                elif m.issym():
                    yield (m.name, False, m.linkname, stat.S_IMODE(m.mode), None)
                elif m.isfile() or m.islnk():
                    # 硬链也走 extractfile（tarfile 会去找同一归档里的目标）
                    yield (m.name, False, None, stat.S_IMODE(m.mode),
                           (lambda m=m: tf.extractfile(m)))
                # 设备 / fifo / 其它：不铺（我们的归档里没有这些东西）
        return
    raise ValueError("不是归档（扩展名不在 %s 里）: %s"
                     % ("/".join(ARCHIVE_EXTS), archive))


def _place(dest_root, rel, isdir, link, mode, opener):
    """把一个成员铺到 `dest_root/rel` 下；成功返回 None，失败返回错误串。"""
    target = safe_join(dest_root, rel)
    if target is None:
        return "包里有越界路径，拒绝解开: %s" % rel
    if isdir:
        os.makedirs(target, exist_ok=True)
        return None
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if link is not None:
        if os.path.lexists(target):
            os.unlink(target)
        os.symlink(link, target)
        return None
    src = opener() if opener else None
    if src is None:
        return None
    with src, open(target, "wb") as fh:
        while True:
            chunk = src.read(1 << 20)
            if not chunk:
                break
            fh.write(chunk)
    if mode:
        os.chmod(target, stat.S_IMODE(mode))
    return None


def do_extract_tree(archive, dest, glob):
    """声明式解包：只取匹配 `glob` 的成员，剥掉 glob 的目录前缀后铺到 dest 下。

    zip 与 tar.gz 都走这里（`iter_members` 把两者的差别吃掉了）。
    """
    if not os.path.isfile(archive):
        return die("包不存在: %s" % archive)
    if not glob:
        return die("extract-tree 需要 --from=<glob>")
    prefix = glob_base(glob)
    # 先扫一遍名字：**一个都没匹配上就不许建 dest** —— 半拉子目录比报错更难查
    # （实测踩过：旧布局的包解不开，却在项目里留下一个空的 __output/）。
    try:
        names = [n for n, _d, _l, _m, _o in iter_members(archive)]
    except (ValueError, zipfile.BadZipFile, tarfile.TarError) as exc:
        return die("解不开 %s：%s\n  支持 .zip / .tar.gz / .tgz / .tar / .tar.xz / .txz 六种（按扩展名认）"
                   % (archive, exc))
    if not any(fnmatch.fnmatchcase(n.replace("\\", "/"), glob) for n in names):
        return die("归档里没有一个成员匹配 --from=%s（%s）—— release.json 的对照表对不上包"
                   % (glob, archive))
    n = 0
    os.makedirs(dest, exist_ok=True)
    for name, isdir, link, mode, opener in iter_members(archive):
        flat = name.replace("\\", "/")
        if not fnmatch.fnmatchcase(flat, glob):
            continue
        if prefix:
            if not flat.startswith(prefix):
                return die("成员 %s 不以前缀 %s 开头（对照表写错了？）" % (name, prefix))
            rel = flat[len(prefix):]
        else:
            rel = flat
        rel = rel.strip("/")
        if not rel:
            continue                              # 就是那个目录本身
        err = _place(dest, rel, isdir, link, mode, opener)
        if err:
            return die(err)
        n += 1
    sys.stdout.write("wtool_zip: 按 %s 解开 %d 个成员 → %s\n" % (glob, n, dest))
    return 0


def _member_hint(names, member):
    """成员找不到时的提示：把归档里的成员列几行出来（人一眼能看出该写什么）。"""
    shown = [n for n in names if n and not n.endswith("/")][:12]
    more = len(names) - len(shown)
    return ("  归档里没有成员 [%s]。它里面有这些（前 %d 个）：\n    %s%s"
            % (member, len(shown), "\n    ".join(shown),
               ("\n    …… 还有 %d 个" % more) if more > 0 else ""))


def do_extract_member(asset, dest_file, member):
    """② muslbin 的取货：从上游资产里取出**一个成员**写到 dest_file。

    `member` 为空 = 资产本身就是那个二进制（裸文件资产，如 jq / yq / shfmt / b3sum）。
    归档资产必须有 `member`（清单里缺省时由 py 补成 `dest` 的 basename）。
    """
    if not os.path.isfile(asset):
        return die("资产不存在: %s（先 wtool download-release）" % asset)
    if not member:
        # 裸文件：**先看扩展名**——认得出是压缩包却当成裸文件是最坏的结果
        # （装出来的"二进制"敲一下就是 exec format error，而 sha256 还是对的）。
        low = asset.lower()
        if low.endswith(ARCHIVE_EXTS):
            return die("%s 是归档（%s），必须给 --member=<归档内成员>"
                       % (asset, os.path.basename(asset)))
        if low.endswith(ARCHIVE_LIKE_EXTS):
            return die("%s 看着是压缩包，但引擎只认 %s（按扩展名，不猜内容）。\n"
                       "  要么换成受支持的资产，要么找助手加一种格式。"
                       % (os.path.basename(asset), " / ".join(ARCHIVE_EXTS)))
        # 裸文件：直接搬过去（资产本身就是那个静态二进制）
        os.makedirs(os.path.dirname(os.path.abspath(dest_file)), exist_ok=True)
        tmp = dest_file + ".part.%d" % os.getpid()
        shutil.copyfile(asset, tmp)
        os.chmod(tmp, 0o755)
        os.replace(tmp, dest_file)
        return 0
    want = _norm_member(member)
    try:
        names = [n for n, _d, _l, _m, _o in iter_members(asset)]
    except (ValueError, zipfile.BadZipFile, tarfile.TarError) as exc:
        return die("解不开 %s：%s\n  支持 .zip / .tar.gz / .tgz / .tar / .tar.xz / .txz 六种（按扩展名认）"
                   % (asset, exc))
    if not any(_norm_member(n) == want for n in names):
        return die("在 %s 里找不到成员 [%s]（清单 <muslbin member=> 写错了？）\n%s"
                   % (os.path.basename(asset), member, _member_hint(names, member)))
    os.makedirs(os.path.dirname(os.path.abspath(dest_file)), exist_ok=True)
    tmp = dest_file + ".part.%d" % os.getpid()
    for name, isdir, link, mode, opener in iter_members(asset):
        if _norm_member(name) != want:
            continue
        if isdir:
            return die("成员 [%s] 在 %s 里是个目录，<muslbin member=> 得指向一个文件"
                       % (member, os.path.basename(asset)))
        if link is not None:
            return die("成员 [%s] 在 %s 里是软链（指向 %s）—— <muslbin member=> "
                       "得指向一个真文件" % (member, os.path.basename(asset), link))
        src = opener() if opener else None
        if src is None:
            return die("读不出成员 [%s]（%s）" % (member, asset))
        with src, open(tmp, "wb") as fh:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                fh.write(chunk)
        # **一律 0755**：<muslbin> 的产物就是那个要执行的二进制（它要能被敲）。
        # 归档里没记权限位（zip 常见）时这一条就是唯一保证。
        os.chmod(tmp, 0o755)
        os.replace(tmp, dest_file)
        sys.stdout.write("wtool_zip: 取出 [%s] → %s\n" % (member, dest_file))
        return 0
    return die("在 %s 里找不到成员 [%s]" % (asset, member))


def _parse_create_args(argv):
    """create / create-tar 共用的参数解析。出错时返回 int（退出码）。"""
    out, base, listfile = argv[1], argv[2], argv[3]
    prefix, extras, i = "", [], 4
    while i < len(argv):
        if argv[i] == "--prefix" or argv[i].startswith("--prefix="):
            if "=" in argv[i]:
                prefix = argv[i].split("=", 1)[1]
                i += 1
            else:
                prefix = argv[i + 1]
                i += 2
        elif argv[i] == "--extra":
            if i + 2 >= len(argv):
                return die("--extra 需要 <绝对路径> <包内路径>")
            extras.append((argv[i + 2], argv[i + 1]))
            i += 3
        else:
            return die("不认识的参数: %s" % argv[i])
    return (out, base, listfile, prefix, extras)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[0]
    if cmd in ("create", "create-tar"):
        if len(argv) < 4:
            return die("用法: %s <out> <base-dir> <list-file> "
                       "[--prefix=P] [--extra <abs-path> <arcname>]..." % cmd)
        parsed = _parse_create_args(argv)
        if not isinstance(parsed, tuple):
            return parsed
        out, base, listfile, prefix, extras = parsed
        if cmd == "create":
            return do_create(out, base, listfile, prefix, extras)
        return do_create_tar(out, base, listfile, prefix, extras)
    if cmd == "extract":
        if len(argv) != 3:
            return die("用法: extract <zip> <dest-dir>")
        return do_extract(argv[1], argv[2])
    if cmd == "extract-tree":
        glob = ""
        args = []
        i = 1
        while i < len(argv):
            if argv[i] == "--from" or argv[i].startswith("--from="):
                if "=" in argv[i]:
                    glob = argv[i].split("=", 1)[1]
                    i += 1
                else:
                    glob = argv[i + 1]
                    i += 2
                continue
            args.append(argv[i])
            i += 1
        if len(args) != 2:
            return die("用法: extract-tree <zip> <dest-dir> --from=<glob>")
        return do_extract_tree(args[0], args[1], glob)
    if cmd == "extract-member":
        member = ""
        args = []
        i = 1
        while i < len(argv):
            if argv[i] == "--member" or argv[i].startswith("--member="):
                if "=" in argv[i]:
                    member = argv[i].split("=", 1)[1]
                    i += 1
                else:
                    member = argv[i + 1]
                    i += 2
                continue
            args.append(argv[i])
            i += 1
        if len(args) != 2:
            return die("用法: extract-member <资产> <dest-file> [--member=<归档内成员>]\n"
                       "  （不带 --member = 资产本身就是那个二进制：jq/yq/shfmt 那种）")
        return do_extract_member(args[0], args[1], member)
    return die("未知子命令: %s" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
