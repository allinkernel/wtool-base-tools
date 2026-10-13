# 项目清单规范 `wtool.xml`

每个项目根目录放一份 `wtool.xml`。它是**纯声明**，不含逻辑。

> 📌 **`$WTOOL_HOME` 指 `.wtool` 根目录**（ADR-0045 / D47 的新口径）。
> 今天引擎里那个同名变量还是"**被管理的家目录**"（默认 `$HOME`）—— 整片改名是
> 后面单独一块（DESIGN §7）。所以本文里写的 `$WTOOL_HOME/usr/bin/fzf`
> **今天**就是 `~/.wtool/usr/bin/fzf`：**同一个地方**，只是名字还没换。

## 最小可用清单

**① 纯源码（`kind="source"`，默认）**：源码即产物 —— **不写任何导出标签**。
配置/脚本待在自己仓库里，运行时由 **L1 链**指过来（见下面「L1 / L2 两条链」）。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50">

  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>

</wtool>
```

**②③ 类（`kind="muslbin"` / `kind="docker"`）**：产物在 `__output/` 下，
用**精确语义**的标签导出（没有"任意落点"这回事）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="muslbin" priority="60">

  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>

  <muslbin url="https://github.com/junegunn/fzf/releases/download/v0.67.0/fzf-0.67.0-linux_amd64.tar.gz"
           tag="v0.67.0" sha256="…64 位十六进制…"
           member="fzf" dest="usr/bin/fzf" arch="x86_64"/>

  <export_bin src="__output/usr/bin/fzf"/>      <!-- → $WTOOL_HOME/usr/bin/fzf -->
  <generate dest="__output/fzf.zsh" cmd="fzf --zsh"/>

</wtool>
```

**标签总表**（不认识的标签 `wtool validate` 直接报错）：

| 标签 | 用途 | 适用类型 |
|---|---|---|
| `<wtool kind="source\|muslbin\|docker">` | **项目类型**（根元素），决定支持哪些命令 | 全部 |
| `<zshrc src="env.zsh"/>` | 这份文件的内容并进 `$WTOOL_HOME/env.zsh` | 全部 |
| `<bashrc src="env.bash"/>` | 同上，进 `$WTOOL_HOME/env.bash` | 全部 |
| `<export_bin src="__output/…" [name=]/>` | 把**一个文件**导出到 `$WTOOL_HOME/usr/bin/<name>` | ②③ |
| `<export_usr src="__output/usr" [part=]/>` | 把 `usr/`（或白名单子目录）下的**每个条目**各导出一条 | ③（② 需要时也行） |
| `<muslbin url= tag= sha256= member= dest= arch=/>` | ② 类的**下载声明**（上游静态二进制） | ② |
| `<generate dest="__output/…" cmd=\|script=/>` | **安装时**生成产物（如 `fzf --zsh`） | ②③ |
| `<sudo-install …/>` | 系统层：要跑的脚本 / playbook / `/etc` 下的文件 / 换源 | 全部 |
| `<source url= ref= />` | 上游源码：clone → 固定 ref → 建本地分支 → 铺 overlay | 全部 |
| `<build kind="local\|docker"/>` | 构建方式（ADR-025）。可带 `min-cores=` / `min-mem=` / `min-disk=` 门槛 | ③ |
| `<publish kind= to= />` | 怎么发布（默认 `source`）：推到本项目 remote，或 `to=` 指定的仓、`kind="none"` 不发布 | 全部 |
| `<include src= optional= />` | 拆清单 | 全部 |

<small>⚠️ 表外的标签**一律报错**，`x-*` 也不行 —— 见文末「自定义元素」。
（旧版这张表里写过"`x-*` 自定义"，**那是错的**：`lib/wtool_plan.py` 对任何未知标签
都拒绝，实测 `<x-note>` → `error: 未知元素 <x-note>`、退出码 1。）</small>

<small>⚠️ **`<link>` 已经删掉**（ADR-0045 / D3，不留兼容期）：`$HOME` 里不再有 wtool 建的软链。
它的下场与替代写法见文末「删掉的旧标签」。</small>

---

## `<build>` —— 构建方式

```xml
<build kind="local"/>                                    <!-- 默认：本地直接编 -->
<build kind="docker" min-cores="8" min-mem="16" min-disk="40"/>
```

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `kind` | 否 | `local` | `local` = 本地直接编，产物天然跨发行版；`docker` = 每个发行版一个容器、分层构建。**别的值一律报错** |
| `min-cores` | 否 | 引擎默认 4 | 这台机器至少几个核，不够就拒绝构建并指路 `download-release` |
| `min-mem` | 否 | 引擎默认 8 | 内存 GB 数（按 `/proc/meminfo` 的 MemTotal 算） |
| `min-disk` | 否 | 引擎默认 10 | `$HOME` 所在分区至少剩多少 GB |

`kind` 决定**两件事**，引擎因此不用猜（ADR-025）：

1. **这台机器行不行** —— `kind="docker"` 而机器上没有 docker，
   `wtool build` 在**动手之前**就拒绝（`build.sh` 一行都不会跑），
   并给出 `download-release` + `unpack-release` + `install` 三条命令。
   这台机器够不够编，同样在跑脚本之前判断（不够就加 `--force` 硬上）。
2. **`__output/` 的形状**：

   | kind | `__output/` 下是什么 |
   |---|---|
   | `local` | `__output/<层>/…` —— **没有** `<os>_<ver>/` 那一层 |
   | `docker` | `__output/<os>_<ver>/<层>/…` |

   形状**由声明唯一确定**：`release.json` 的 `targets[]` 就是按这个算的
   （`local` → 空；`docker` → `__output/*/` 的目录名）。所以 `local` 项目的
   `__output/` 里就算有 `bin/`、`main/` 这种目录，也不会被当成"发行版"。

> 只声明 kind，**targets 和层清单不进 XML** —— 那是项目数据，住项目里固定路径的文件：
> `build/targets.tsv`（目标系统 → 基础镜像）、`build/layers.tsv`（层名 / 父层 / 镜像名 /
> 容器里跑的命令）、`build/export.filter`（导出时丢什么）。见 `harness/docs/adr/0029`。
> 有 `build/layers.tsv` 时**引擎驱动容器**（起容器 / commit / 落 `__layer/` / 导 `__output/`）；
> 只有 `scripts/build.sh` 时仍然跑脚本（迁移前的形态）；两个都没有就拒绝构建。

---

## `<wtool>` 根元素

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `schema` | ✅ | — | 清单格式版本。当前只支持 `1`；未知值会被拒绝 |
| `kind` | 否 | `source` | **项目类型**：`source` / `muslbin` / `docker`。决定这个项目支持哪些命令（见下节）。**别的值报错**，不会静默降级成 `source` |
| `id` | ❌ **已删除** | — | **不要写**。项目身份**就是它相对工作区根的路径**（ADR-0037）。还写着 `id` 的清单会**直接报错**，删掉这个属性即可 |
| `priority` | 否 | `100` | 越小越早加载；`<zshrc>`/`<bashrc>` 不写 `priority` 时继承它 |

### 项目类型 `<wtool kind>` —— 它决定哪些命令对这个项目有意义

```xml
<wtool schema="1" kind="source"  priority="50">   <!-- ① 纯源码（默认，可省略不写） -->
<wtool schema="1" kind="muslbin" priority="60">   <!-- ② musl 静态二进制 -->
<wtool schema="1" kind="docker"  priority="20">   <!-- ③ docker 跨发行版构建 -->
```

| 取值 | 项目长什么样 | 内容从哪来 | 发哪个离线包 |
|---|---|---|---|
| `source`（**默认**） | 配置 / 脚本，**源码即产物** | 仓库源码本身 | `source-offline.zip` |
| `muslbin` | 上游 release 的 x86_64-musl 静态二进制 | `download-release`（读 `<muslbin url=…>`） | `release-offline.zip` |
| `docker` | 要按发行版编（每个发行版一套容器层） | `build` → `__layer/` → `__output/` | `release-offline.zip`（开发机另有 `release.zip`） |

**它决定哪些命令对这个项目有意义** —— 完整矩阵与"不适用"的行为契约见
[`spec.md`](spec.md)（§1.5）。一句话：用不到的命令，引擎**直接回一句"不适用"并非 0 退出**，
**不会**假装去找 `scripts/build.sh`，也不会静默成功。

> 例：`kind="source"` 的项目敲 `wtool build terminal/tmux`
> ```
> wtool: 'terminal/tmux' 是 kind=source（纯源码项目），不支持 build —— 它不需要构建
> ```
> 退出码非 0。（① 类是"源码即产物"，配置/脚本**直接链源码路径**，不渲染、不进 `__output/`。）

⚠️ **三个 `kind` 不是一个东西，别混**（这是最容易写错的一处）：

| 写在哪 | 取值 | 回答什么问题 |
|---|---|---|
| **`<wtool kind=…>`（根元素）** | `source` / `muslbin` / `docker` | **这个项目属于哪一类** → 支持哪些命令 |
| `<build kind=…>` | `local` / `docker` | **怎么构建** → `__output/` 的形状（ADR-025） |
| `<publish kind=…>` | `source` / `none` | **怎么发布** → 推到自己仓还是别的仓、发不发 |

`docker` 在前两行里都出现，但一个问的是"**项目类型**"，另一个问的是"**怎么编**"：
一个 `kind="docker"`（根元素）的项目照样可以写 `<build kind="local"/>`（本地直接编）。

### 项目身份 = 路径（没有 `id` 这回事了）

用户 2026-10-04 拍板（ADR-0037）：**干掉项目 id，一律用项目路径指项目。**
原话："项目 id 是个很烦人的东西，直接干掉吧。我们后续就根据项目路径来指定项目即可。
否则改了路径，还要改 id，就很烦。"

所以：

- 身份**只有一个来源** —— 项目目录相对工作区根的路径（`terminal/tmux` 这样的）。
  它出现在 `$WTOOL_HOME/wtool/<路径>`（**L1 链**）、`$WTOOL_STATE/<路径>/` 和 rc 块标记里。
- **改目录 = 换了一个项目**。想改名用 `wtool move <旧路径> <新路径>`
  （= 卸旧的 → mv → 装新的），别自己 `mv`。只 `mv` 会把旧路径那一套账
  （state 目录、L1 链、env 块、registry 行）留在原地，而且它们**大多不报错、
  只是静默失效**；`wtool check` 会把这类残渣报出来。
- 路径里**不要**用 `..`，也别写成绝对路径 —— 项目要待在工作区里。
  工作区**外面**的目录也能 `wtool install /abs/path`，但那种项目拿不到合法的相对路径，
  身份会退化成目录名（`basename`）：能用，但别指望它跨机器稳定。

---

## `<zshrc>` / `<bashrc>` —— 要被 source 的部分

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `src` | ✅ | — | 相对本清单的相对路径 |
| `priority` | 否 | 根元素的 | 排序键 |
| `optional` | 否 | `false` | `src` 不存在时跳过 |

**两个 shell 各一份，内容要等价** —— 受众里有人机器上没有 zsh（公司机器很常见），
只写一份的后果是"那个 shell 的用户敲命令 `command not found`"，而 rc 文件里看起来
明明装过了。所以 `env.zsh` 改了，`env.bash` 要跟着改。

最容易漏的一句（症状：装完了但敲命令找不到）：

```sh
export PATH="$WTOOL_PREFIX/bin:$PATH"      # 装出来的东西
export PATH="$WTOOL_PROJECT_DIR/bin:$PATH" # 项目自己的 bin/
```

它最后进哪儿：

```
env.zsh  的内容 ──► ~/.wtool/.zshrc   ──► ~/.zshrc  里一个 loader 块 source 它
env.bash 的内容 ──► ~/.wtool/.bashrc  ──► ~/.bashrc 里一个 loader 块 source 它

每个 shell 一条**独立**的链：env.zsh 是给 zsh 用的，env.bash 是给 bash 用的（两份内容
等价，各自服务一个 shell）。汇总文件是所有项目共用的；rc 里的 loader 块是全局的、
不属于任何项目。只用 bash 的人靠的就是 env.bash 这条链。
```

`eval "$(wtool doctor --quiet)"` 能把同一批变量直接灌进当前 shell。

---

## L1 / L2 两条链（装一个项目到底发生了什么）

`wtool install` 只做**两类链**，名字和职责分得很开（ADR-0045 §1.3）：

| | **L1「项目接入链」** | **L2「项目导出链」** |
|---|---|---|
| 形状 | `$WTOOL_HOME/wtool/<项目路径>` → **工作区里那个项目目录** | `$WTOOL_HOME/usr/<part>/<条目>` → 项目 `__output/` 里的东西 |
| 回答什么 | **项目在哪** | **项目提供什么** |
| 谁声明 | **引擎自动**（装了就建，惰性：只建装过的那个项目）；`wtool.xml` **不声明它** | `wtool.xml` 的 `<export_bin>` / `<export_usr>` |
| 绝对/相对 | **绝对**（断了能一眼看懂它指哪） | **相对**（`../../wtool/<项目>/…`，两端都在 `.wtool` 里，整棵树搬走依然有效） |
| 卸载 | 只删那一条链 | 按账本逆放 |

```
$WTOOL_HOME/wtool/terminal/tmux  ──►  ~/self/wtool/terminal/tmux        （L1，绝对）
$WTOOL_HOME/usr/bin/fzf          ──►  ../../wtool/tools/musl-bins/fzf/__output/usr/bin/fzf
                                                                        （L2，相对）
```

**L1 让 ① 类项目"源码即产物"成立**：配置/脚本不用渲染、不用拷进 `__output/`，
直接读 `$WTOOL_HOME/wtool/<项目路径>/…` 就是源码本身。

**`$WTOOL_HOME/usr/` 是多项目共享的实体目录**：`usr/<part>` **永远是实体目录**，
里面**一条一链**（否则 fzf 和 zsh 都要往 `usr/bin` 里放东西时会撞死）。
`<part>` 只有 **6 个**白名单值：`bin` `lib` `libexec` `share` `include` `local`（D19）。

> ⚠️ 两条链都**进账本**（`$WTOOL_STATE/<项目>/journal.tsv`），`wtool check` 会逐条验
> "链在不在、指向对不对、**目标还在不在**"——悬空的链（比如工作区搬走了）会被点名，
> 不是"一切对得上"。详见 [`spec.md`](spec.md) §2。

---

## `<export_bin>` —— 导出一个文件

```xml
<export_bin src="__output/usr/bin/fzf"/>              <!-- → usr/bin/fzf -->
<export_bin src="__output/rg-dbg" name="rg"/>         <!-- → usr/bin/rg -->
```

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `src` | ✅ | — | **必须在项目的 `__output/` 之下**（那是"构建出来的 / 下载解压出来的"），而且**必须是一个文件** |
| `name` | 否 | `src` 的 basename | 落点文件名，只能是一个文件名（不含 `/`） |

落点**固定**是 `$WTOOL_HOME/usr/bin/<name>` —— **没有 `dest=` 这个口子**（D6）。
指向目录、指到源码树、写 `dest=`、`name` 里带 `/`，都**报错**，不静默忽略。

---

## `<export_usr>` —— 逐条目导出一个 `usr/` 子树

```xml
<export_usr src="__output/usr"/>                  <!-- usr/ 下每个白名单子项各展开一条 -->
<export_usr src="__output/usr" part="share"/>     <!-- 只要 usr/share/ -->
```

准确语义（**最容易写错的一条**，D7）：

> 对 `src` 下的每个**直接子项** `X`：保证 `$WTOOL_HOME/usr/X` 是**实体目录**，
> 再把 `X` 里的**每个条目**各建一条链（条目可以是文件，也可以是一整棵子目录）。

| 情形 | 结果 |
|---|---|
| 不带 `part` | `src` 下每个直接子目录各展开一份；**遇到白名单外的子目录 → 报错并列出它**（要加白名单得先找用户拍板） |
| 带 `part` | 只处理那一个；`part` 不在 6 个白名单里 → 报错 |
| `src` 下有**散文件** | 警告（散文件不属于任何 part，不会被导出） |
| `src` 还不存在（没 build / 没 download） | 报错，并给出 `download-release` / `unpack-release` / `build` 三条命令 |

`$WTOOL_HOME/usr/<part>` **不是链，是实体目录** —— 它归所有项目共用。

---

## `<muslbin>` —— ② 类的下载声明

```xml
<muslbin url="https://github.com/junegunn/fzf/releases/download/v0.67.0/fzf-0.67.0-linux_amd64.tar.gz"
         tag="v0.67.0" sha256="…64 位十六进制…"
         member="fzf" dest="usr/bin/fzf" arch="x86_64"/>
```

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `url` | ✅ | — | 上游资产地址（`http(s)://`） |
| `tag` | ✅ | — | 上游版本，**钉死**（不许浮动） |
| `sha256` | ✅ | — | 下载后的校验值；不是 64 位十六进制 → 报错（写错等于没有校验） |
| `dest` | ✅ | — | 解到 **`__output/` 下的相对路径**（例 `usr/bin/fzf`），**不写 `__output/` 前缀** |
| `member` | 否 | `dest` 的 basename | **归档里**要取的那个成员名（含目录前缀时写全，例 `bat-v0.26.1-…/bat`） |
| `arch` | 否 | `x86_64` | 目前只做 `x86_64`（D32），写别的报错 |

**资产有两种形状，判据是 `url` 的扩展名**（按扩展名认，不猜内容）：

| 形状 | `url` 的样子 | `member` | 引擎怎么取 |
|---|---|---|---|
| **归档** | `.zip` / `.tar` / `.tar.gz` / `.tgz` | 缺省 = `dest` 的 basename | 从里面取**那一个**成员，写到 `__output/<dest>`，权限 0755 |
| **裸文件** | 其余（release 页上挂的就是那个二进制：`jq` / `yq` / `shfmt` / `b3sum` 那种） | **不许写**（写了 → 报错） | 下到的东西**本身就是**那个二进制，直接落到 `__output/<dest>` |
| 认得出是压缩包但不支持的（`.tar.xz` …） | —— | —— | **报错**（不静默当裸文件 —— 那会装出一个 `exec format error` 的"二进制"） |

只对 `kind="muslbin"` 的项目有意义 —— 写在别的类型上**报错**。

**这两条命令就是它接的线**（都是**开发机**命令，要联网）：

```sh
wtool download-release <项目>   # 读这条声明 → 下到 <项目>/__release/<URL 的 basename>，按 sha256 校验
wtool unpack-release   <项目>   # 从 __release/ 里取下 member → <项目>/__output/<dest>（还是按 sha256 校验一次）
wtool install          <项目>   # <export_bin src="__output/<dest>"> 建 L2 链，再跑 <generate>
```

- `download-release` **按 sha256 把关**：不匹配 → 非 0 停下、`__release/` 里不留半成品
- `unpack-release` 对 ② 类**不读 `scripts/release.json`**（② 类按设计就没有它，D50）——
  上面这张表就是它的对照表（D57：**必须有声明**，声明写在哪个文件里是次要的）
- `member` 写错 / 归档里没有 → 报错并**列出归档里有哪些成员**

---

## `<generate>` —— 安装时生成产物

```xml
<generate dest="__output/fzf.zsh"  cmd="fzf --zsh"/>          <!-- 跑一条命令 -->
<generate dest="__output/fzf.bash" script="scripts/gen-fzf.bash"/>  <!-- 或跑一个脚本 -->
```

| 属性 | 必填 | 说明 |
|---|---|---|
| `dest` | ✅ | **必须在 `__output/` 之下**（D41）：生成物是**安装期产物**，不进源码树、不进 git |
| `cmd` | 二选一 | 要跑的命令；它的 **stdout** 就是生成物的内容 |
| `script` | 二选一 | 项目里的相对路径脚本；文件不存在 → 报错 |

`cmd` 与 `script` **都给 / 都不给** → 报错。生成物由该项目自己的
`env.zsh` / `env.bash` 去 source（典型例子：fzf 的 `fzf --zsh`）。

执行契约（`wtool install` 时跑，实现见 `docs/spec.md` §4 的
`<generate>`：安装期产物）：

- cwd = **项目根**；`PATH` 前面加 `$WTOOL_HOME/usr/bin`
  （所以 `cmd="fzf --zsh"` 用的就是**刚链上的**那份二进制）
- 产物写 `__output/<dest>`：先写临时文件再 `mv` —— 失败不留半个生成物，重复 install 是覆盖更新
- 产物**进 journal** → `wtool uninstall` 会把它删掉；`check` 发现它不见了会报出来
- 命令失败 / 产物是**空的** → `install` 当场**非 0**（说清命令、cwd、退出码）
- `--dry-run` 只打印"会生成哪个路径、跑什么"，不跑不写

---

## 删掉的旧标签

| 旧 | 现在 |
|---|---|
| `<link home= wtool= subproject=/>` | **报错**（ADR-0045 / D3，不留兼容期）—— `$HOME` 里不再有 wtool 建的软链（D1）。<br>① 类：删掉这条即可（配置/脚本直接读 `$WTOOL_HOME/wtool/<项目路径>/…`）；<br>②③ 类：改用 `<export_bin>` / `<export_usr>` 导到 `$WTOOL_HOME/usr/…` |
| `<link home= produced-by="install.sh"/>` | 同上 —— "实体由脚本铺、链由引擎建"这套不做了 |
| `<link src= dest=/>`（更老的写法） | 同上 |
| `<env src= shells=/>` | 用 `<zshrc src="env.zsh"/>` / `<bashrc src="env.bash"/>`。老写法**仍然认**，但每次解析都警告 |
| `<provision>` / `<system-file>` | 并进 `<sudo-install>`（老写法仍然认，警告） |

**`$HOME` 里现在只剩两行**（rc 的最后两行）：

```sh
export WTOOL_HOME=~/.wtool
source ${WTOOL_HOME}/env.zsh        # bash 用户写 env.bash
```

要让用户敲到命令、拿到环境变量，写进**本项目的 `env.zsh` / `env.bash`**
（比如包装函数 `tmux() { command tmux -f "$WTOOL_HOME/wtool/terminal/tmux/tmux.conf" "$@"; }`），
而不是往 `$HOME` 里建软链。

## `<sudo-install>` —— 系统层（`/etc`、apt 包、要跑的脚本）

一个标签覆盖三类内容，靠有没有 `dest=` 区分：

```xml
<!-- 1) 要跑的脚本 / playbook（.yaml/.yml → ansible，其余 → shell） -->
<sudo-install src="provision/packages.yaml" marker="apt-base"
              when="os:ubuntu" desc="基础软件包"/>

<!-- 2) 项目里带的系统文件（可逆：备份三份 → 写 → 还原） -->
<sudo-install src="mirror.sources" dest="/etc/apt/sources.list.d/x.sources"
              mode="replace" backup="true"/>

<!-- 3) 引擎按发行版生成（换源） -->
<sudo-install kind="apt-mirror" mirror="ustc" dest="auto" when="os:ubuntu"/>
```

| 属性 | 用于 | 说明 |
|---|---|---|
| `src` | 全部 | 相对路径。有 `dest` 时是"要写的内容"，否则是"要跑的脚本" |
| `dest` | 系统文件 | 绝对路径；`auto` 只和 `kind` 一起用（由引擎算） |
| `kind` | 系统文件 | `apt-mirror` / `yum-mirror` / `distro-mirror` |
| `mirror` | 系统文件 | `auto`（**推荐**）/ `ustc`（没记录时的默认）/ `tuna` / `aliyun` / `huawei` / `netease` / `tencent`。<br>`auto` = 跟着 `install.sh` 第 0 步挑的那个镜像走（记在 `<state>/mirror.txt`）：有记录就**跳过换源**，没有才用 `ustc` —— 见 ADR-0032 |
| `mode` | 系统文件 | `replace`（备份后覆盖）/ `add`（不存在才建）/ `disable`（原文件改名禁用） |
| `backup` | 系统文件 | 默认 `replace` 时为 `true` |
| `marker` | 任务 | 幂等标记；成功后写 `$WTOOL_STATE/<id>/provisioned/<marker>` |
| `when` | 全部 | 逗号分隔的 AND：`os:ubuntu`、`!os:debian`、`arch:x86_64`、`env:WTOOL_HEAVY` |
| `desc` | 全部 | 人类可读说明 |

它由 **`wtool sudo-install`** 执行（`wtool sudo-bootstrap` 是所有项目跑一遍），
**不在 `wtool install` 里**。`/etc` 的改动备份三份（原文件旁边 / `/var/backups/wtool/` /
state），还原依据单独记在 `system.tsv`；apt 包按"跑前跑后的已装包差集"记账，
`wtool sudo-uninstall` 只卸这次装进来的。详见 `docs/spec.md` §11。

> 旧标签 `<system-file>` 和 `<provision>` 是它的前身（`runner=` 也删了，按扩展名判断）。
> 过渡期仍然认，但会警告。

---

## `<source>` —— 源码编译型项目

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `url` | ✅ | — | 上游仓库地址 |
| `ref` | ✅ | — | 固定到 tag/commit（**禁止浮动分支**） |
| `dir` | 否 | `$WTOOL_SRC/<id 末段>` | 源码树位置 |
| `branch` | 否 | `wsw` | 本地分支名 |
| `overlay` | 否 | `overlay` | 项目内要铺进源码树的目录 |
| `when` | 否 | — | 同 `<sudo-install>` |

执行：`clone/fetch` → `checkout --detach <ref>` → `checkout -B <branch>` → 铺 `overlay/*`
→ **提交到 `wsw` 分支**（这样工作区干净、`git diff` 有意义）。

---

## `<publish>` —— 怎么发布

**不写它 = `kind="source"`**：引擎打源码包 / 产物包，推到**本项目自己 remote** 的 release。
它只表达"文件表达不了的两件事"：推到**别的仓**、或者**根本不发**。
（**打几个包不由这里决定**：项目没有构建能力 —— 没有 `scripts/build.sh`、
也没有 `build/layers.tsv` —— 时只发源码包，见 `docs/adr/0039`。）

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `kind` | 否 | `source` | 只认 `source` / `none`（`none` = 不参与发布，第三方上游仓用这个） |
| `to` | 否 | 本项目 remote | 推到别的仓，写 `owner/repo` |
| `tag` | 否 | `snapshot-%Y-%m-%d` | release 的 tag（`%Y`/`%m`/`%d` 会替换成当天日期） |
| `asset` | 否 | — | 引擎只解析并透出（`publish-info` 读得到），当前发布流程不消费 |

子元素两个：

| 子元素 | 用途 |
|---|---|
| `<sub path= kind= to=/>` | 替**子树里没有 `wtool.xml` 的项目**表态（上游仓不能往里塞清单文件，只能从外面声明） |
| `<target os= version= codename= image=/>` | 目标系统矩阵；引擎只解析并透出（`publish-info` 读得到），发布流程不消费 |

**`kind="script"` 和 `script=` 已经取消**（ADR-023），现在写它们是**清单错误**，
`wtool validate` 会拒绝：

```xml
<!-- ✗ 报错：kind 只能是 source / none -->
<publish kind="script" script="scripts/publish.sh"/>
```

提示是"发布不再调项目脚本，构建逻辑放 `scripts/build.sh`" —— 发布全项目走同一条引擎的路：
`wtool pack-release`（`__output/` → `__release/`）+ `wtool publish-release`（`__release/` → GitHub）。

---

## `<include>`

| 属性 | 必填 | 说明 |
|---|---|---|
| `src` | ✅ | 相对本清单的相对路径，最多嵌套 8 层 |
| `optional` | 否 | 不存在时跳过 |

典型用途：`<include src="wtool.local.xml" optional="true"/>`，把机器本地差异放在一个**不入库**的文件里。

---

## 自定义元素

**没有这回事。** `<wtool>` 只认上面「标签总表」里列出的元素，其他一律报错
（避免拼写错误悄悄失效）—— **`x-` 前缀也不行**。

repo 的 manifest 用 `x-*` 把命名空间留给用户，`wtool.xml` **故意不跟**：
清单是引擎要逐条执行的动作表，一条没被理解的声明**静默丢掉**比报错危险得多。

报错本身就会指路（2026-09-28 起，BL-23）—— 它不再教人写 `x-*`（那正是它刚拒绝的东西，
照着改还是同一个错），而是给出真出路：

```
error: 未知元素 <x-note>（.../wtool.xml）；wtool.xml 没有自定义元素（x-* 也拒绝），
       机器本地差异请用 <include src="wtool.local.xml" optional="true"/>
```

机器本地差异就是那个 `wtool.local.xml`（不入库）。

---

## 校验清单（`wtool validate <项目>`）

| 检查 | 失败动作 |
|---|---|
| XML 可解析、根元素是 `<wtool>` | 拒绝 |
| `schema` 已知 | 拒绝 |
| `src` 相对、不含 `..`、存在、在本项目内 | 拒绝 |
| `<export_*>` 的 `src` **在项目 `__output/` 之下**（D40；① 类根本不写这类标签） | 拒绝 |
| `export_bin` 的 `src` 是**一个文件**（不是目录） | 拒绝 |
| `export_usr part=` 在 6 个白名单里（`bin lib libexec share include local`） | 拒绝 |
| `export_usr`（不带 `part`）遇到**白名单外的子目录** | 拒绝（**列出它**） |
| `<generate>` 的 `dest` 在 `__output/` 之下；`cmd` / `script` **二选一** | 拒绝 |
| `<muslbin>` 只用在 ② 类；`sha256` 是 64 位十六进制；`arch` 是 `x86_64` | 拒绝 |
| 任何标签写了 `dest=`（`<export_*>` / `<muslbin>`） | 拒绝（D6：落点由标签决定） |
| 两条声明指向**同一条 L2 落点**（同一个项目里，或跨项目撞 `registry.tsv`） | 拒绝（`--force` 降级为警告） |
| L2 落点在磁盘上不存在，或已是正确的软链 | 拒绝（`--force` 备份后接管） |
| 装过的项目里，`<export_*>` / `<generate>` 指的产物**不在磁盘上** | 拒绝（`wtool check` 报"声明与磁盘对不上"） |
| 有 `build.sh` 就必须有非空的 `__output/` | 拒绝（`--force` 降级为警告） |
| `<publish kind=…>` 只能是 `source` / `none`；不能有 `script=` | 拒绝 |
| `<build kind=…>` 只能是 `local` / `docker`；`min-cores` / `min-mem` / `min-disk` 必须是正整数 | 拒绝 |
| `<wtool kind=…>`（**根元素**）只能是 `source` / `muslbin` / `docker`；写别的值 → 报错（项目**仍然留在看板上**，但被门禁的命令一律拒，绝不悄悄当成 `source`） | 报错 |
| `<link>`（任何写法） | **报错**（D3：解析已删，文案给出照做就行的改法） |
| `<env src= shells=/>` / `<provision>` / `<system-file>` 这些老写法 | 警告（能装，但提醒改成新标签） |

⚠️ **"产物在不在"分两种场合**（`check` 的假警报比不报更坏）：

- `wtool validate <项目>`：**一律查**。它回答的就是"这份清单现在能不能装"，
  产物没产出时那句"先 `download-release` / `build`"正是你要的下一步。
- `wtool check`（扫全工作区）：**只查装过的项目**。一个刚 `repo sync` 完、
  还没 `download-release`/`build` 的项目**本来就没有 `__output/`** ——
  把那当成错误，`check` 会对着干净工作区一路报红。

---

## 完整示例

**③ 类（要按发行版编）**：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" kind="docker" priority="20">

  <zshrc  src="env.zsh"  priority="20"/>
  <bashrc src="env.bash" priority="20"/>

  <!-- 本发行版那一套产物 → $WTOOL_HOME/usr/{bin,share,lib,…}，逐条目一链 -->
  <export_usr src="__output/ubuntu_24.04/usr"/>

  <!-- 安装时生成的补全脚本（由 env.zsh 去 source） -->
  <generate dest="__output/zsh.zsh" cmd="zsh --version"/>

  <!-- 机器本地覆盖，不入库 -->
  <include src="wtool.local.xml" optional="true"/>
</wtool>
```

**① 类（源码即产物）**：只有 `<zshrc>` / `<bashrc>`，什么导出都不写 ——
运行时要读的文件直接走 L1（`$WTOOL_HOME/wtool/<项目路径>/…`）。

要编译 / 要产出的项目，再加 `scripts/`（只有 `build.sh` 和 `install.sh` 两种，
**按需，别留空壳**）和 `__output/`（产物，`.gitignore` 里）。
下载和发布**不用脚本**：那是引擎的 `download-release` / `unpack-release`（取现成的包）和
`pack-release` / `publish-release`（打包上传）。
**文件存在即能力声明**：`scripts/` 下有没有那个文件，直接决定项目表里那一列亮不亮。

⚠️ 但这只对**引擎允许这个项目类型用的**命令成立（ADR-0045 / D49）：根元素的 `kind` 是**第一层**
判据 —— `kind="source"` 的项目里放一个 `scripts/build.sh` **不会**让 `wtool build` 变得可用
（引擎回"不适用"并非 0 退出）。看板那一格也是按类型先判的。

---

## 旧标签（过渡期，会警告）

| 旧 | 新 | 备注 |
|---|---|---|
| `<env src= shells=/>` | `<zshrc src=/>` / `<bashrc src=/>` | `shells=` 靠扩展名推断的那套删了 |
| ~~`<link home= wtool= subproject=/>`~~ | **没有了** —— 编译期就报错（D3） | `$HOME` 里不再有 wtool 建的软链（D1）。改法见「删掉的旧标签」 |
| ~~`<link src= dest=/>`~~ | **没有了** —— 同上 | 它也一直没有中间那一跳 |
| `<provision src= runner=/>` | `<sudo-install src=/>` | `runner=` 按扩展名判断 |
| `<system-file …/>` | `<sudo-install … dest=/etc/…/>` | 属性名不变 |
| ~~`produced-by="install.sh"`~~ | **没有了** —— 报错 | "实体由脚本铺、链由引擎建"这套不做了（`$HOME` 里不建链） |
| `<publish kind="script" script=…/>` | **没有了** —— 报错 | 发布不再调项目脚本（ADR-023）。`<publish>` 本身**还在**，但只剩 `kind="source"`（默认）/ `kind="none"` / `to="owner/repo"`，见上文「`<publish>` —— 怎么发布」；构建逻辑归 `scripts/build.sh` |

`<link>` 的兼容分支**已经删了**（ADR-0045 / D3：不留兼容期）—— 还写着它的清单
`wtool validate` / `wtool install` 一律**报错**，并给出照做就行的改法。
