#!/bin/sh
# 跑全部测试
#
# ⚠️ 下面括号里的条数**以跑出来的 PASS 行为准** —— 这行注释是手写的，会过期；
#    数字对不上时先数 PASS 行，再回来改这里（括号里就是 2026-10-13 的实测真值）。
#   tests/pairing_test.sh     install/uninstall 的完全配对；rc 里那两行**不由 install 写**
#                             （默认只打印）、最后一卸两行跟着剥、source $WTOOL_HOME/env.zsh
#                             之后项目变量真的在；本机日志：每次装一个新目录、编号递增、
#                             删了 check 照样干净（54 条 —— ADR-0045 第 5a 块：35→54）
#   tests/provision_test.sh   sudo-install 层：系统文件 / source / task（40 条）
#   tests/publish_test.sh     publish-release：打包 / 只上传 / release.json / 拒收下载包，
#                             含"资产名必须 ASCII"（H27）、"建 release 带 --target"
#                             与"刷新认发布声明里的 tag"（缺陷 A/B）；
#                             场景 19 = publish-offline-release（离线族另一个 release 页）
#                             （192 条 —— 2026-10-13 164→192：+28 条离线族，ADR-0045 / D54 / D56）
#   tests/table_test.sh       能力表格的格子语义与列对齐（106 条 —— 2026-10-13 94→106：
#                             +12 条"项目类型 kind 是能力列的第一层判据"，ADR-0045 / D49）
#   tests/release_copy_test.sh 从发布包解压出来的工作区（没有 .git 也没有 repo 客户端）（17 条）
#   tests/release_test.sh     pack-release / unpack-release / download-release，
#                             含"没有构建能力的项目只发源码包"（ADR-0039）与
#                             "资产名必须 ASCII + 旧中文名要清掉"（ADR-0040）
#                             含下载块生成器按资产形状生成；场景 10 = pack-offline-release
#                             （自足包 / 资产名按 kind / check-hash.sh 不依赖 wtool / 安装器包）
#                             （158 条 —— 2026-10-13 109→158：+49 条离线族 + 声明式解包断言）
#   tests/contract_test.sh    新契约：新标签、L1/L2 两类链、执行顺序、check/repair、kill、
#                             --dry-run 不跑项目脚本、uninstall 认 id 也跑项目脚本、
#                             补全表与参数解析对得上、--id 老写法指路、wtool move、
#                             改名残渣 check 报得出来；rc 那两行：缺→报、旧标记块→
#                             替换、替换完→幂等；~/usr 在**被管理的家目录**里（313 条 ——
#                             2026-10-13 实测；注释里原来写的 311 是过期值，
#                             ADR-0045 第 3 块 + 第 5a 块：302→313）
#   tests/export_test.sh      新标签 + L1/L2 两类链（ADR-0045 第 3 块）：15 条坏输入
#                             各报错非 0、L1 绝对且**进账本**（悬空 check 必须报出来）、
#                             L2 相对且 usr/<part> 是实体目录、冲突文案含"找助手"
#                             （78 条 —— 2026-10-13 第 ⑦.2 块：+1 条"validate 不执行
#                             <generate>"；原来那两条"第二次 install 报无变更"改成
#                             "generate 每次都重跑、但产物逐字节一样"）
#   tests/muslbin_test.sh     ② 类（kind="muslbin"）的下载→解包→安装 + <generate>
#                             （ADR-0045 第 ⑦.2 块）：download-release 读 <muslbin>
#                             （sha256 不匹配非 0 且不留半成品 / --dry-run 不下 /
#                             幂等跳过）、unpack-release 认 member=/dest=（.tar.gz /
#                             .zip / .tar.xz / 裸文件四种资产、member 写错列出归档成员）、
#                             <generate>（cmd+script、进 journal、uninstall 删、
#                             重复 install 幂等、失败/空产物/--dry-run 零副作用非 0、
#                             cmd 里的制表符两种写法两种结果）（114 条 —— 2026-10-13
#                             第 ⑦.3 块 104→114：+10 条 `.tar.xz`（下载 / 解包 / 全链 /
#                             check），原来那条"不支持的压缩"从 `.tar.xz` 换成 `.tar.zst`）
#   tests/layer_test.sh       __layer/<target>/ 那棵 OCI 镜像目录（打桩 docker/skopeo，不联网）（50 条）
#   tests/docker_build_test.sh kind=docker 的引擎驱动构建（打桩 docker，不联网）；构建日志落在
#                             **本机日志** $WTOOL_LOG_DIR/<项目>/build-logs/，账本里不再有它（102 条）
#   tests/install_env_test.sh install.sh 第 0 步：镜像测速 / 挑源 / 换源与退路（打桩，不联网）（67 条）
#   tests/installer_test.sh   install.sh **六项职责** + manifest 三件套（ADR-0045 第 5b 块 /
#                             D42）：两条入口链的形状（相对链、项目名不写死）、
#                             var/ 账本（删掉它 check 必须非 0）、三件套的两种形态
#                             （满血=绝对链+现场算 / bundle=只校验不覆盖）、
#                             六步**各自的**失败路径都非 0、rc"非交互一个字节都不写 /
#                             pty 答 y 才写 / 写了也只有两行"、--dry-run 零副作用
#                             含 uninstall.sh 对称收尾那两场
#                             （89 条 —— 2026-10-13，第 5b 块新加）
#                             —— 十三组共 **1382** 条（2026-10-13 第 ⑦.3 块之后的账；
#                             本机跑出来的是 **1384 行 PASS** —— 差 2 是头里那两个
#                             手写数（pairing 写 56 实为 57、sudo-install 写 40 实为 41，
#                             这一行自己就写着"以跑出来的 PASS 行为准"）：
#                             1372→1382 = muslbin 104→114（+10 条 `.tar.xz`：下载 / 解包 /
#                             全链 / check），其余 12 组逐条不变。ADR-0045 第 ⑦.2 块：
#                             1267→1372 = 新增 muslbin 104 条 + export 场景 1 拆出
#                             一条"validate 不执行 <generate>"（77→78）。其余 11 组
#                             逐条不变（pairing 56 / sudo-install 40 / publish 192 /
#                             table 106 / release-copy 17 / release 158 / contract 313 /
#                             layer 50 / docker-build 102 / install-env 67 / installer 89）。
#                             上一轮（第 5b 块）：
#                             1177→1267 = 新增 installer 89 条 + pairing 场景 9 多一条
#                             "D23 老位置不该存在"（55→56）；同时把 pairing 那两条断言
#                             改到新位置（$WTOOL_HOME/wtool-base-tools → wtool/wtool-base-tools））。
#                             要数字请以**跑出来的 PASS 行**为准。
#   tests/muslbin_acceptance.sh ② 类**真联网**下载→解包→install→敲那个工具的容器验收
#                             （人工跑，见文件头：docker run --network=host + 宿主工具挂载）
#   tests/docker_build_real.sh 同一件事的**真 docker** 冒烟测试（人工跑，见文件头）
#   tests/container_test.sh   容器里从零装一遍（需要 docker，见文件头注释）
#   tests/container_acceptance.sh  人工总验收：把它喂给容器里的 container-raw.sh（见文件头）
#   tests/e2e_repo_sync_test.sh  repo sync 全流程（用本地裸仓，较慢）
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)

printf '########## 1/13 pairing（install/uninstall）##########\n'
sh "$here/pairing_test.sh"
printf '\n########## 2/13 sudo-install（系统文件/source/task）##########\n'
sh "$here/provision_test.sh"
printf '\n########## 3/13 publish-release（只上传 + release.json）##########\n'
sh "$here/publish_test.sh"
printf '\n########## 4/13 table（能力表格）##########\n'
sh "$here/table_test.sh"
printf '\n########## 5/13 release-copy（解压出来的工作区）##########\n'
sh "$here/release_copy_test.sh"
printf '\n########## 6/13 pack-release / unpack-release / download-release ##########\n'
sh "$here/release_test.sh"
printf '\n########## 7/13 新契约（标签/两跳/顺序/check/repair/kill）##########\n'
sh "$here/contract_test.sh"
printf '\n########## 8/13 __layer/（OCI 镜像目录）##########\n'
sh "$here/layer_test.sh"
printf '\n########## 9/13 引擎驱动容器构建（kind=docker）##########\n'
sh "$here/docker_build_test.sh"
printf '\n########## 10/13 install.sh 第 0 步（镜像测速 / 挑源 / 换源与退路）##########\n'
sh "$here/install_env_test.sh"
printf '\n########## 11/13 install.sh 六项职责 + manifest 三件套（第 5b 块）##########\n'
sh "$here/installer_test.sh"
printf '\n########## 12/13 新标签 + L1/L2（ADR-0045 第 3 块）##########\n'
sh "$here/export_test.sh"
printf '\n########## 13/13 ② 类下载/解包 + <generate>（ADR-0045 第 ⑦.2 块）##########\n'
sh "$here/muslbin_test.sh"
printf '\n全部通过。\n'
