# FnDepot（zcc050 的飞牛三方应用源）

飞牛 fnOS 第三方应用源，格式为 FnDepot 外部源 **V2**（仓库根目录 `fnpack.json` 单文件索引）。

## 在飞牛里添加源

1. 打开 **应用中心 → 设置（或右上角）→ 应用源 / 第三方源**；
2. 新增源，地址填：

   ```
   https://raw.githubusercontent.com/zcc050/FnDepot/main/fnpack.json
   ```

3. 刷新后在应用列表里搜索 `magpie`、`Ekko Studio`、`T3 Code` 安装。

## 应用

| 应用 | 上游 | 版本 | 端口 | 说明 |
|---|---|---|---|---|
| `magpie` | [yetone/magpie](https://github.com/yetone/magpie) | 0.1.4282 | 3430 | 给 Claude Code / Codex 等 Agent 统一换模型、走本地网关 |
| `ekko-studio` | [EKKOLearnAI/ekko-studio](https://github.com/EKKOLearnAI/ekko-studio) | 0.8.24 | 6060 | 本地优先 AI 工作区：多 Agent 聊天、编码、工作流 |
| `t3code` | [pingdotgg/t3code](https://github.com/pingdotgg/t3code) | 0.1.9 | 3773 | 把编码 Agent 跑在 NAS 上，电脑/手机同一界面控制 |

仅提供 `x86` 包（构建机为 x86_64 飞牛 NAS）。安装包托管在本仓库的 GitHub Releases。

## 仓库结构

```
fnpack.json              # V2 索引（应用元数据 + 版本 + 下载地址 + sha256）
apps/<app>/
  app.json               # 商店展示元数据（分类/图标/预览图/维护者）
  build.sh               # 拉上游 + 组 fpk + 写 dist/<arch>.json
  src/                   # fpk 工程根（manifest + cmd + config + app + wizard）
  ICON.PNG ICON_256.PNG  # 商店图标
  Preview/1.png          # 商店截图
  README.md              # 应用说明（索引里 readme_url 指向它）
  dist/                  # 构建产物（gitignore，仅上传到 Release）
scripts/
  lib.sh                 # 构建公共函数
  smoke.sh               # 解包后跑真实生命周期（start/status/stop/HTTP 200）
  preview.sh             # 无头 Chromium 抓商店截图
  verify_fpk.py          # fpk 契约校验（manifest/checksum/权限/JSON/图标）
  build_index.py         # 由 dist/*.json 生成 fnpack.json
docs/PACKAGING.md        # fpk 打包契约与验收标准
template/                # fpk 模板
```

## 自动化更新（每天检查上游 → 自动打包 → 自动发布）

一条命令跑完整链路：

```bash
bash scripts/auto_update.sh            # 检查上游稳定版 → 构建 → 校验 → 冒烟 → 重建索引 → 提交推送 → 发 Release
bash scripts/auto_update.sh --dry-run  # 只报告有没有更新
bash scripts/auto_update.sh --no-publish --only magpie   # 只构建到本地
```

流程与闸门：

1. `scripts/lib.sh version <app>` 取上游最新**稳定**版本（跳过 nightly/beta/rc），与 `apps/<app>/dist/<arch>.json` 比对。
2. 有新版 → `apps/<app>/build.sh --arch x86` 构建（缓存上游产物，重复跑不重复下载）。
3. `scripts/verify_fpk.py`：manifest/checksum/cmd 权限/JSON/图标契约。
4. `scripts/smoke.sh`：解包 → start → HTTP 200 → status=0 → stop → 端口释放。
5. 全部通过才 `scripts/build_index.py` 重建索引，并用 `scripts/validate_source.py` 校验
   （**分类白名单**、schema、素材存在性、与 app.json 一致）。
6. `git commit && git push`，再 `scripts/publish_release.py` 建 `<app>-v<ver>` Release 并上传，
   最后 HEAD 校验下载地址。
7. 任一步失败 → **不发布**，本地产物与日志保留；索引不会被改成指向不存在的资产。

运行态都在 `.auto-update/`（已 gitignore）：`auto-update-YYYYMMDD.log`、`lock`、`last-run.json`。

### 定时任务

```bash
# 每天 04:17 检查一次（crontab -e 或 crontab -l 里加）
17 4 * * * cd /vol1/@apphome/hermes-studio/work/FnDepot && bash scripts/auto_update.sh >> .auto-update/cron.log 2>&1
```

### 单独校验源（发布前/排错用）

```bash
python3 scripts/validate_source.py           # 本地：分类白名单/schema/素材/一致性
python3 scripts/validate_source.py --online  # 额外 HEAD 校验所有下载地址
python3 scripts/check_updates.py             # 上游是否有新版（退出码 10 = 有）
```

## 本地构建与发布

```bash
bash apps/magpie/build.sh              # 或 t3code / ekko-studio
python3 scripts/verify_fpk.py apps/magpie/dist/magpie-*-x86.fpk
bash scripts/smoke.sh magpie 18121     # 解包 → 起服务 → curl 200 → status → stop
bash scripts/preview.sh magpie 18131   # 重新抓商店截图
python3 scripts/build_index.py         # 重新生成 fnpack.json
```

发布新版本：跑 `build.sh` → `verify` → `smoke` → 建 GitHub Release
（tag `<app>-v<version>`，资产为 `dist/<app>-<version>-x86.fpk`）→ `build_index.py` → 提交推送。

## 免责声明

所有应用版权归各自上游作者；本仓库只做 fnOS 原生打包（manifest/cmd/wizard 与运行时铺设），
不修改上游业务代码。上游更新可能带来不兼容，升级前请务必备份 `/vol1/@appdata/<app>`。
