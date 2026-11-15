# fpk 打包契约（内部文档）

本仓库是飞牛 fnOS 的第三方应用源（FnDepot 格式 v2）。构建机是一台 x86_64 飞牛 NAS，
`fnpack` 1.2.4 已安装在 `/usr/local/bin/fnpack`，可用 `fnpack build` 直接出包。
无 root、无 docker、无 sudo。

## 1. 目录归属

```
apps/<app>/
  app.json        # FnDepot 元数据（分类、预览图、README 等）—— 打包方写
  build.sh        # 拉取上游 + 生成 fpk —— 打包方写
  src/            # fpk 工程根目录（manifest + cmd + config + app + wizard）—— 打包方写
  dist/           # 产物（*.fpk + <arch>.json），已 gitignore —— build.sh 写
  ICON.PNG  ICON_256.PNG  Preview/1.png  README.md   # 商店展示素材 —— 素材方写
scripts/          # 构建/校验/索引脚本
.github/workflows/
template/         # 本契约附带的 fpk 模板，复制改造，别直接改
```

只写自己负责的路径，不要删别人的目录。

## 2. fpk 结构

`fnpack build -d <dir>` 把 `<dir>` 打包成 `<appname>.fpk`，里面是：

```
manifest          # key = value，纯文本
ICON.PNG          # 111x111 或 256x256 PNG
ICON_256.PNG
cmd/              # 生命周期脚本，全部 755
  common          # 自己抽的公共函数（可选，但要有）
  main install_init install_callback config_init config_callback
  uninstall_init uninstall_callback upgrade_init upgrade_callback
config/privilege  # 运行身份 JSON
config/resource   # 资源声明 JSON，可 {}
app/              # 会被压成 app.tgz
  ui/config       # 桌面入口 JSON
  ui/images/icon_64.png  icon_256.png
  server/         # 二进制/运行时/依赖，全部放这里
wizard/           # 安装/设置/卸载向导 JSON，可缺省
  install config uninstall
```

`fnpack build` 自动在 manifest 末尾追加 `checksum`（= app.tgz 的 md5），不要手写。

### manifest 字段（本项目用到的）

| 字段 | 说明 |
|---|---|
| `appname` | 小写、唯一，等于目录名 |
| `version` | 点分数字，飞牛据此判断升级；不要带 `v` 前缀或 `-nightly` 后缀 |
| `display_name` `desc` | 商店展示 |
| `platform` | `x86` / `arm` / `loongarch` / `risc-v` / `all`（fnpack 只认这五个值） |
| `source` | 固定 `thirdparty` |
| `maintainer` `maintainer_url` | 上游作者 |
| `distributor` `distributor_url` | 打包者：`zcc050` / `https://github.com/zcc050/FnDepot` |
| `os_min_version` | 一般 `1.0.0` |
| `desktop_uidir` `desktop_applaunchname` | `ui` / `<appname>.Application` |
| `service_port` | 默认 Web 端口，供飞牛展示 |
| `checkport` | `true`，飞牛会做端口检查 |
| `ctl_stop` | `true` |

### 运行期环境变量

| 变量 | 含义 |
|---|---|
| `TRIM_APPDEST` | 安装目录 `/vol1/@appstore/<appname>`（app/server 在这里） |
| `TRIM_PKGVAR` | 数据目录 `/vol1/@appdata/<appname>`（日志、pid、数据库） |
| `TRIM_PKGHOME` | 应用 HOME `/vol1/@apphome/<appname>` |
| `TRIM_APPDIR` | 安装中的 fpk 根目录 |
| `TRIM_TEMP_LOGFILE` | 写入这个文件的内容会在安装失败时展示给用户 |
| `$<field>` | wizard 里的字段名直接成为环境变量，如 `$launcher_port` |

调用顺序：`install_init`（落盘前）→ 拷贝文件 → `install_callback` → `main start`。
改设置：`config_init` → `config_callback`。升级：`upgrade_init` → 覆盖 → `upgrade_callback`。
卸载：`uninstall_init` → 删文件 → `uninstall_callback`。
`main` 必须支持 `start|stop|restart|status`，`status` 未运行返回码 3。

### app/ui/config（桌面入口）

```json
{".url": {"<appname>.Application": {
  "title": "...", "icon": "images/icon_{0}.png", "type": "iframe",
  "protocol": "http", "port": "${launcher_port}", "url": "/", "allUsers": false,
  "control": {"fullUrlPerm": "editable", "pathPerm": "hidden", "portPerm": "readonly", "accessPerm": "readonly"}
}}}
```

`${launcher_port}` 取自 wizard 字段 `launcher_port`；应用必须真的监听该端口，并且对 `/` 返回 200。
fnpack 会校验：`.url` 下的 key 必须以 manifest 的 `appname` 开头（`<appname>.Application`），否则拒绝出包。

> 模板已用 `fnpack build` 实测通过（生命周期 start/stop/status + HTTP 200）。

### wizard 项类型

`tips`（helpText）、`text`（field/initValue/rules [{required,message},{pattern,message}]）、
`radio`（options [{label,value}]）、`checkbox`（options + 值序列化不确定，谨慎使用）。
字段名会被导出为同名环境变量，cmd 脚本里直接用 `$launcher_port`。

## 3. build.sh 契约

```bash
bash apps/<app>/build.sh            # 默认 x86，或 --arch arm
```

- 幂等：可重复执行；上游产物缓存在 `$HOME/.cache/fndepot/<app>/`，已存在就不重复下载。
- 从上游 Release API 取最新**稳定**版本号，写进 `src/manifest` 的 `version`（点分数字）。
- 把运行时铺进 `src/app/server/`，改 `src/cmd/*` 的启动命令、`src/wizard/*` 的默认端口。
- `cd apps/<app>/src && fnpack build -d .`，产物改名为 `<app>-<ver>-<arch>.fpk` 移入 `dist/`，
  并写 `dist/<arch>.json`：

```json
{"version": "1.2.3", "arch": "x86", "file": "magpie-1.2.3-x86.fpk",
 "size": 12345678, "sha256": "…", "updated_at": "2026-11-15T12:34:46Z",
 "os_min_version": "1.0.0", "changelog": "更新到上游 1.2.3"}
```

`arch` 取值必须是 `x86` 或 `arm`。`updated_at` 用上游 Release 的 `published_at`。

## 4. 验收标准（缺一不可）

1. `bash apps/<app>/build.sh` 从干净状态能跑通，`dist/` 里有 fpk 和 json。
2. `python3 scripts/verify_fpk.py apps/<app>/dist/<file>.fpk` 通过
   （manifest 字段齐全、checksum 与 app.tgz md5 一致、cmd 脚本可执行、JSON 合法、图标是 PNG）。
3. 冒烟：解出 app.tgz，设好 `TRIM_APPDEST/TRIM_PKGVAR/TRIM_PKGHOME` 指向临时目录，
   `bash cmd/main start` 后 `curl -fsS http://127.0.0.1:<测试端口>/` 返回 200，
   `cmd/main status` 退出码 0，`cmd/main stop` 能停干净。
4. 端口别用主机上已占用的：本机 3425、3430、6060、3000、8787、18088 等已被占用，
   测试用 181xx 段，并在启动命令里显式覆盖端口（magpie 还要覆盖 `MAGPIE_ADDR`）。
