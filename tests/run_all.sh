#!/bin/sh
# 跑全部测试
#
# ⚠️ 下面括号里的条数**以跑出来的 PASS 行为准** —— 这行注释是手写的，会过期；
#    数字对不上时先数 PASS 行，再回来改这里（括号里就是 2026-10-13 的实测真值）。
#   tests/pairing_test.sh     install/uninstall 的完全配对（35 条）
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
#                             改名残渣 check 报得出来（302 条 —— ADR-0045 第 3 块：
#                             <link> 换成 <export_bin>/<export_usr>，两跳变 L1+L2）
#   tests/export_test.sh      新标签 + L1/L2 两类链（ADR-0045 第 3 块）：15 条坏输入
#                             各报错非 0、L1 绝对且**进账本**（悬空 check 必须报出来）、
#                             L2 相对且 usr/<part> 是实体目录、冲突文案含"找助手"
#                             （77 条）
#   tests/layer_test.sh       __layer/<target>/ 那棵 OCI 镜像目录（打桩 docker/skopeo，不联网）（50 条）
#   tests/docker_build_test.sh kind=docker 的引擎驱动构建（打桩 docker，不联网）（101 条）
#   tests/install_env_test.sh install.sh 第 0 步：镜像测速 / 挑源 / 换源与退路（打桩，不联网）（67 条）
#                             —— 十一组共 1148 条（2026-10-13 实测；1051→1148 = ADR-0045
#                             第 3 块：新标签 + L1/L2。contract 286→302、pairing 35→38、
#                             export 新增 77；table 106→106（"中转链接"那条换成 L1））
#   tests/docker_build_real.sh 同一件事的**真 docker** 冒烟测试（人工跑，见文件头）
#   tests/container_test.sh   容器里从零装一遍（需要 docker，见文件头注释）
#   tests/container_acceptance.sh  人工总验收：把它喂给容器里的 container-raw.sh（见文件头）
#   tests/e2e_repo_sync_test.sh  repo sync 全流程（用本地裸仓，较慢）
set -eu
here=$(cd -- "$(dirname -- "$0")" && pwd)

printf '########## 1/11 pairing（install/uninstall）##########\n'
sh "$here/pairing_test.sh"
printf '\n########## 2/11 sudo-install（系统文件/source/task）##########\n'
sh "$here/provision_test.sh"
printf '\n########## 3/11 publish-release（只上传 + release.json）##########\n'
sh "$here/publish_test.sh"
printf '\n########## 4/11 table（能力表格）##########\n'
sh "$here/table_test.sh"
printf '\n########## 5/11 release-copy（解压出来的工作区）##########\n'
sh "$here/release_copy_test.sh"
printf '\n########## 6/11 pack-release / unpack-release / download-release ##########\n'
sh "$here/release_test.sh"
printf '\n########## 7/11 新契约（标签/两跳/顺序/check/repair/kill）##########\n'
sh "$here/contract_test.sh"
printf '\n########## 8/11 __layer/（OCI 镜像目录）##########\n'
sh "$here/layer_test.sh"
printf '\n########## 9/11 引擎驱动容器构建（kind=docker）##########\n'
sh "$here/docker_build_test.sh"
printf '\n########## 10/11 install.sh 第 0 步（镜像测速 / 挑源 / 换源与退路）##########\n'
sh "$here/install_env_test.sh"
printf '\n########## 11/11 新标签 + L1/L2（ADR-0045 第 3 块）##########\n'
sh "$here/export_test.sh"
printf '\n全部通过。\n'
