# magpie（飞牛 fnOS 打包）

把 [yetone/magpie](https://github.com/yetone/magpie) 打包成飞牛原生 fpk。magpie 给
Claude Code、Codex、OpenCode 等 Agent 统一换模型、统一走本地网关。

## 安装后

- 桌面图标打开即可，默认端口 **3430**（安装向导里可改）。
- 首次打开会带 `?k=<key>` 管理口令，链接同时打印在
  `/vol1/@appdata/magpie/logs/magpie.log`；别把带 key 的链接发给别人。
- 数据与配置在 `/vol1/@appdata/magpie/`，日志同名目录下 `logs/`。

## 已知说明

- 网关端口 3425 由上游默认值使用；如果 NAS 上已有 magpie 在跑，安装向导里换端口。
- 打包只做运行时装包，不修改上游配置；模型/供应商仍在 magpie 界面里配。

## 构建

```bash
bash apps/magpie/build.sh            # x86
bash apps/magpie/build.sh --arch arm # arm（上游有 arm64 资产时）
```
