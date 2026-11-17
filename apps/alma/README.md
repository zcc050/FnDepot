# Alma（fnOS 打包）

把 [Alma](https://alma.now) 的 **headless 服务端**跑在飞牛上，用浏览器或手机 App 使用。
会话、技能、MCP、定时任务全部在 NAS 上执行。

上游产物来自 [yetone/alma-releases](https://github.com/yetone/alma-releases)，本包只做生命周期与一层安全网关，
**前端文件一个字节都没有改动**。

## 为什么需要一层网关

上游 `alma-server` 有两个限制（`--help` 原文）：

- 只监听 `127.0.0.1`，没有 `--host` 参数
- **没有任何登录认证**，官方文档写明「能访问端口的人就能以该用户执行 shell 命令」

所以直接把它的端口摊到局域网，等于挂一台无密码终端。本包在它前面加 `cmd/gateway.mjs`：

```
浏览器 ──0.0.0.0:23001──▶ gateway.mjs ──127.0.0.1:23002──▶ alma-server
                          · 访问口令（cookie）
                          · HTTP / SSE / WebSocket 反代
                          · 不解析、不修改任何页面内容
```

网关只做两件事：校验 cookie、转发字节流。响应头原样回传（Alma 没有 CSP / `X-Frame-Options`，
iframe 直接可用，不需要像 magpie 那样打二进制补丁）。

## 端口与目录

| 项 | 值 |
| --- | --- |
| 对外端口（网页） | `launcher_port`，默认 **23001** |
| 内部端口（alma） | 对外端口 + 1，默认 23002 |
| 数据目录 | `/vol1/@appdata/alma/data`（会话、设置、供应商密钥） |
| 访问信息 | `/vol1/@appdata/alma/access-info.txt` |
| 访问口令 | `/vol1/@appdata/alma/access.key` |
| 日志 | `/vol1/@appdata/alma/alma.log`、`/tmp/alma-runtime.log` |

桌面图标打开时自动带上 `?k=<口令>`，不需要手输。换浏览器或清过 cookie 时，口令见
`access-info.txt`，或在应用里重新查看。

## 安全默认值

- 工具调用默认 **需要确认**（`ALMA_TOOL_APPROVAL=ask`）：网页或已配对手机上点一下才执行，
  而不是上游默认的「直接跑」。
- 访问口令自动生成，24 位。

想关掉口令（**只建议在完全可信的网络里**）：在 `$TRIM_PKGVAR/no-auth` 放一个空文件后重启应用。
关掉之后任何能访问该端口的设备都可以直接在 NAS 上执行命令。

## 手机访问

不用开端口，走 Alma 官方 relay：

```bash
# 在 NAS 上（应用用户 alma）
/vol1/@appcenter/alma/server/bin/alma-server pair --token <从 community.alma.now 取的 token>
```

也可用自托管 relay（`alma-relay`，有 Docker 镜像）配合 `--relay` 参数。

## 服务端不可用的功能

上游明确这些依赖桌面环境，headless 下不可用：computer use、屏幕/窗口捕获、活动录制、
可见浏览器面板、语音输入、本地 embedding 模型、桌面通知。
