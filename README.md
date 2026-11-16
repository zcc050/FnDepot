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
