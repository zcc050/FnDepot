# Ekko Studio（飞牛 fnOS 打包）

把 [EKKOLearnAI/ekko-studio](https://github.com/EKKOLearnAI/ekko-studio) 打包成飞牛
原生 fpk：本地优先的 AI 工作区，多 Agent 聊天、编码与可视化工作流。

## 安装后

- 桌面图标打开，默认端口 **6060**（安装向导里可改）。
- 首次登录：用户名 `admin`，密码 `123456`（登录页有提示），登录后请立刻改密码。
- 数据在 `/vol1/@appdata/hermes-studio/`（会话库、技能、日志）。
- 首次启动会后台安装 Python 侧 Agent 运行时，可能需要几分钟；期间页面能打开，
  Agent 功能就绪后自动可用。日志：`/vol1/@appdata/hermes-studio/info.log`。

## 说明

- 包内含 Node 运行时与 hermes-web-ui 0.8.24，无需额外装 Node。
- 升级会覆盖应用目录，`/vol1/@appdata` 下的数据保留。

## 构建

```bash
bash apps/ekko-studio/build.sh
```
