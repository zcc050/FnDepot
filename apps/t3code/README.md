# T3 Code（飞牛 fnOS 打包）

把 [pingdotgg/t3code](https://github.com/pingdotgg/t3code) 打包成飞牛原生 fpk：
把 Claude Code / Codex 等编码 Agent 跑在 NAS 上，从电脑或手机同一个界面控制。

## 安装后

- 桌面图标打开，默认端口 **3773**（安装向导里可改）。
- 首次访问会跳到 `/pair#token=...` 完成配对；配对令牌也会打印在
  `/vol1/@appdata/t3code/logs/t3code.log`。
- Agent 的登录态沿用 NAS 上的 CLI 配置（`~/.claude`、`~/.codex` 等）。

## 构建

```bash
bash apps/t3code/build.sh
```
