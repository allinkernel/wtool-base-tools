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
#                             替换、替换完→幂等；~/usr 在**被管理的家目录**里（311 条 ——
#                             ADR-0045 第 3 块 + 第 5a 块：302→311）
#   tests/export_test.sh      新标签 + L1/L2 两类链（ADR-0045 第 3 块）：15 条坏输入
#                             各报错非 0、L1 绝对且**进账本**（悬空 check 必须报出来）、
#                             L2 相对且 usr/<part> 是实体目录、冲突文案含"找助手"
#                             （77 条）
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
#                             —— 十二组共 1267 条（2026-10-13 实测；ADR-0045 第 5b 块：
#                             1177→1267 = 新增 installer 89 条 + pairing 场景 9 多一条
#                             "D23 老位置不该存在"（55→56）；同时把 pairing 那两条断言
#                             改到新位置（$WTOOL_HOME/bootstrap → wtool/bootstrap））。
#                             要数字请以**跑出来的 PASS 行**为准。
#   tests/docker_build_real.sh 同一件事的**真 docker** 冒烟测试（人工跑，见文件头）
#   tests/container_test.sh   容器里从零装一遍（需要 docker，见文件头注释）
#   tests/container_acceptance.sh  人工总验收：把它喂给容器里的 container-raw.sh（见文件头）
#   tests/e2e_repo_sync_test.sh  repo sync 全流程（用本地裸仓，较慢）
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)

printf '########## 1/12 pairing（install/uninstall）##########\n'
sh "$here/pairing_test.sh"
printf '\n########## 2/12 sudo-install（系统文件/source/task）##########\n'
sh "$here/provision_test.sh"
printf '\n########## 3/12 publish-release（只上传 + release.json）##########\n'
sh "$here/publish_test.sh"
printf '\n########## 4/12 table（能力表格）##########\n'
sh "$here/table_test.sh"
printf '\n########## 5/12 release-copy（解压出来的工作区）##########\n'
sh "$here/release_copy_test.sh"
printf '\n########## 6/12 pack-release / unpack-release / download-release ##########\n'
sh "$here/release_test.sh"
printf '\n########## 7/12 新契约（标签/两跳/顺序/check/repair/kill）##########\n'
sh "$here/contract_test.sh"
printf '\n########## 8/12 __layer/（OCI 镜像目录）##########\n'
sh "$here/layer_test.sh"
printf '\n########## 9/12 引擎驱动容器构建（kind=docker）##########\n'
sh "$here/docker_build_test.sh"
printf '\n########## 10/12 install.sh 第 0 步（镜像测速 / 挑源 / 换源与退路）##########\n'
sh "$here/install_env_test.sh"
printf '\n########## 11/12 install.sh 六项职责 + manifest 三件套（第 5b 块）##########\n'
sh "$here/installer_test.sh"
printf '\n########## 12/12 新标签 + L1/L2（ADR-0045 第 3 块）##########\n'
sh "$here/export_test.sh"
printf '\n全部通过。\n'
