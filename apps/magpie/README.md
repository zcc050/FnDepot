# magpie（飞牛 fnOS 打包）

把 [yetone/magpie](https://github.com/yetone/magpie) 打包成飞牛原生 fpk。magpie 给
Claude Code、Codex、OpenCode 等 Agent 统一换模型、统一走本地网关。

## 安装后

- 桌面图标打开即可，默认端口 **3430**（安装向导里可改）。
- 首次打开会带 `?k=<key>` 管理口令，链接同时打印在
  `/vol1/@appdata/magpie/logs/magpie.log`；别把带 key 的链接发给别人。
- 数据与配置在 `/vol1/@appdata/magpie/`，日志同名目录下 `logs/`。

## 运行形态（与 fnOS 上的既有部署一致）

- 以 `--gateway` 启动：只提供网关 + Web 管理台，不暴露 Agents/Sessions/Library 面板。
- 双端口：Web `${launcher_port}`（默认 3430）、网关 3425；启动时**两个端口都探活**才算就绪，
  就绪结果写在 `$TRIM_PKGVAR/access-info.txt`（含免登链接与口令，权限 600）。
- Web 口令持久化在 `$TRIM_PKGVAR/web.key`，通过 `MAGPIE_WEB_KEY` 传入；不传则每次启动换新 key，
  已登录浏览器会全部失效。
- HOME / XDG_* 全部重定向到 `$TRIM_PKGHOME`：供应商、密钥、订阅登录态都在 `$HOME/.config/magpie`，
  升级/重装不会丢。

## 桌面入口方式：`type: url`，不是 `iframe`

`ui/config` 的 `type` 决定飞牛怎么给小窗选路，三种形态后果完全不同：

| 形态 | 典型应用 | 小窗地址 |
| --- | --- | --- |
| `type: iframe` + `gatewaySocket` + `gatewayPrefix` | quark、fn-seekbox、fndepot | 走飞牛自己的反代 `/app/<name>`，**不碰 fnos.net** |
| `type: url` + 固定 `port` | hermes-studio、aistream、lunatv-enhanced | 浏览器直连 `<当前主机>:端口` |
| `type: iframe` + 独立 `port`、无 gateway | 旧版本包、StirlingPDF | 飞牛分配给 `<app>-main.<nas-id>.fnos.net` |

第三种入口由 `trim-connect`（飞牛远程访问）的 DDNS 记录驱动，指向飞牛的中转节点。客户端解析不到
这个子域名时，小窗直接报「找不到服务器 IP 地址」——**跟应用本身是否启动无关**，直连 `IP:端口` 一直是好的。
magpie 不支持监听 unix socket（`web --addr` 只接受 `host:port`），走不了第一种；所以本包用第二种，
和 hermes-studio 一致。`cmd/main` 在启动时会把实际 `launcher_port` 写回 `ui/config` 的 `port`，
避免 wizard 改端口后入口对不上。

## iframe 兼容补丁（重要）

飞牛桌面是用 iframe 打开应用的，而 magpie 的响应带 CSP `frame-ancestors 'self'`，跨源祖先链会被
浏览器整帧拒绝 —— 表现为**灰屏/破图**。本包在每次启动前对二进制做**等长字节替换**：

```
frame-ancestors 'self'   (22B) -> frame-ancestors *      (22B)
Content-Security-Policy  (23B) -> X-Content-Security-Poli (23B)
```

- 只改字节内容，不改文件大小，不动 Go 段偏移；原子写入（同目录临时文件 + rename）。
- 幂等：已打过会输出 `already patched or nothing to do`。
- 必须在进程停止后执行（运行中二进制是 Text file busy），所以 `main start` 会先停残留再打补丁。
- 想保留 CSP 头、只放开 frame-ancestors：启动前设 `MAGPIE_KEEP_CSP=1`。
- 如果 magpie 自己更新了二进制（会变回原版），重启应用即可重新打上。

## 升级/卸载

- 升级会先停掉老进程与历史 watcher（按 argv 精确匹配，不误杀其他应用的 magpie），保留 `web.key`
  与数据，再重打补丁。
- 卸载默认保留 `/vol1/@appdata/magpie` 与 `/vol1/@apphome/magpie`；向导里勾选删除才会清空。

## 已知说明

- 网关默认监听 `0.0.0.0:3425`（Agent 可从局域网接入）。若不希望暴露到局域网，可用应用设置把
  端口改掉，或在飞牛防火墙里限制来源。
- 打包只做运行时装包，不修改上游配置；模型/供应商仍在 magpie 界面里配。

## 构建

```bash
bash apps/magpie/build.sh            # x86
bash apps/magpie/build.sh --arch arm # arm（上游有 arm64 资产时）
```
