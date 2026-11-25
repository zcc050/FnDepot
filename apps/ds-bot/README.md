# DS Bot

[DS Bot](https://github.com/Fei-Craft/DS-Bot) 是基于 [DeepSeekRuntime](https://github.com/deepseek-ai/deepseek-harness)（dsh）的开源 Bot 框架。它把 dsh 改造成 bot 形态：你可以创建长期在线的 bot、和它们对话、让它们互相发消息或拉群协作。

上游提供桌面应用和 dsh 插件两种形态，NAS 上官方只给了 Docker 路径。这个包改成**原生安装**：装完即用，不需要在 NAS 上编镜像。

## 安装后怎么用

1. 打开应用，进入 **设置**，填入模型 API Key（DeepSeek，或任何 Anthropic-Messages 兼容端点）。
2. 和默认的 **Chief** 说一句话，它会帮你把其他 bot 和群聊建起来。

首次打开如果没有直接看到界面，看 `应用目录/startup.log`，里面每次启动会打印一个带 `?token=` 的链接，用那个链接打开一次就会种下登录 cookie（有效期 30 天）。这是 dsh 自身的安全机制：端口开着不等于能进。

## 端口与数据

| 项目 | 位置 |
|---|---|
| Web 端口 | 默认 `13080`，安装时可选，之后可在应用设置里改 |
| 数据 | `/vol1/@appdata/ds-bot/data`（dsh 主目录：模型配置、bot、群聊） |
| 工作区 | `/vol1/@appdata/ds-bot/workspace`（bot 读写文件的地方） |
| 日志 | `/vol1/@appdata/ds-bot/logs/ds-bot.log` |
| HOME | `/vol1/@apphome/ds-bot` |

卸载时可以选择是否连数据一起删，默认保留。

## 打包方式

包内自带 **Node 24.22.3 + dsh 0.2.2-rc.1 + 已装好 ds-bot 插件的 DSH_HOME 模板**，`apps/ds-bot/src/app/server/` 就是这个运行时。首次启动只是把模板拷进数据目录，所以**不需要联网**——只有调模型 API 才需要。

这一点和上游 `docker/Dockerfile` 完全一致：它在构建阶段也是 `dsh plugin --profile web add` 出一个 `/opt/dsh-template`，容器启动时再拷进 `/data`。这里只是把同样的事挪到打包阶段。

```bash
bash apps/ds-bot/build.sh          # 出包到 apps/ds-bot/dist/
```

可覆盖的变量：`DSH_VERSION`、`NODE_VERSION`、`PNPM_VERSION`、`NPM_REGISTRY`（默认走 npmmirror）。

## 升级注意

DS Bot 对 dsh 内部包（`cordis` / `dsh-llm` / `dsh-web` / `dsh-tools` / `dsh-scope` / `dsh-typert-protocol`）声明了 peer 依赖，**两个版本必须成对升**，只动其中一个大概率启动即崩。

升级包不会覆盖已有数据目录，这是有意的（保护你的 bot 和会话）。但如果某次升级换了 dsh 大版本，旧 profile 里的 `node_modules` 仍指向上一版 dsh，可能出现启动失败。处置办法：把 `/vol1/@appdata/ds-bot/data/profiles` 备份后重命名，让应用重新播种一份模板，再把 bot 配置拷回去。

## 已知限制

- **只出 x86 包**。arm 走 `--arch arm`，未实测。
- dsh 拒绝绑定 `0.0.0.0`（会报 "wildcard address ... not supported"，防止把 RCE 暴露到全网）。所以启动时绑定的是 NAS 的主网卡地址，用 `ip route get 1.1.1.1` 取。多网卡/多网段环境如果发现绑错地址，可以在 `cmd/launcher` 里用 `DSBOT_BIND` 环境变量覆盖。
- 应用中心里点开是用**新标签页**打开（`type: url`），没有塞进 iframe——dsh 的响应头对 iframe 不友好。
- 启动日志里会有 dsh 打印的 `?token=` 链接，属于正常行为，但意味着**日志文件等同于临时凭据**，别随手发出去。
