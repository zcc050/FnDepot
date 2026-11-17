#!/usr/bin/env node
/**
 * Alma 网关：把只监听 127.0.0.1 的 alma-server 安全地摊到局域网上。
 *
 * 为什么需要它：
 *   alma-server 没有 --host 参数，强制绑回环；而且它自己没有登录认证，
 *   官方文档明确"能访问端口的人就能以该用户执行 shell"。直接暴露到
 *   局域网等于挂一台无密码终端上去。
 *
 * 它做什么：
 *   1. 0.0.0.0:<对外端口> -> 127.0.0.1:<内部端口> 的 HTTP / SSE / WebSocket 反代
 *   2. 一层访问口令（cookie），首次用 ?k=<token> 进来自动签发，之后靠 cookie
 *   3. 除了这一个 cookie，不改任何请求/响应内容——前端文件一个字节都不动
 *
 * 用法：
 *   node gateway.mjs <对外端口> <内部端口> <口令> [--no-auth]
 * 环境变量：
 *   ALMA_GW_NO_AUTH=1   关闭口令（仅在你完全信任所在网络时使用）
 */
import http from "node:http";
import net from "node:net";
import { URL } from "node:url";

const [webPortArg, apiPortArg, tokenArg] = process.argv.slice(2);
const WEB_PORT = Number(webPortArg);
const API_PORT = Number(apiPortArg);
const TOKEN = (tokenArg || "").trim();
const NO_AUTH = process.env.ALMA_GW_NO_AUTH === "1" || !TOKEN;
const COOKIE = "alma_gw";

if (!WEB_PORT || !API_PORT) {
  console.error("用法: gateway.mjs <对外端口> <内部端口> <口令>");
  process.exit(2);
}

const log = (msg) => console.log(`${new Date().toISOString()} ${msg}`);

function parseCookies(header = "") {
  const out = {};
  for (const part of header.split(";")) {
    const i = part.indexOf("=");
    if (i > 0) out[part.slice(0, i).trim()] = part.slice(i + 1).trim();
  }
  return out;
}

function authed(req, url) {
  if (NO_AUTH) return true;
  if (url.searchParams.get("k") === TOKEN) return true;
  return parseCookies(req.headers.cookie)[COOKIE] === TOKEN;
}

/** 极简口令页：只在没有 cookie 时出现一次，不影响 Alma 自己的界面 */
function loginPage(msg = "") {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Alma</title>
<style>html,body{height:100%;margin:0;font:14px/1.6 system-ui,sans-serif;background:#111;color:#e8e8e8}
main{height:100%;display:flex;align-items:center;justify-content:center}
form{width:300px}input{width:100%;padding:10px 12px;margin:8px 0;border-radius:8px;border:1px solid #333;background:#1b1b1b;color:#fff;box-sizing:border-box}
button{width:100%;padding:10px;border:0;border-radius:8px;background:#e8e8e8;color:#111;font-weight:600;cursor:pointer}
p{color:#999;margin:0 0 8px}</style></head><body><main><form method="get" action="">
<p>需要访问口令${msg ? ` — ${msg}` : ""}</p>
<input name="k" type="password" autofocus placeholder="访问口令">
<button type="submit">进入 Alma</button></form></main></body></html>`;
}

const server = http.createServer((req, res) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  } catch {
    res.writeHead(400).end("bad request");
    return;
  }

  if (!authed(req, url)) {
    const headers = { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" };
    res.writeHead(401, headers).end(loginPage(url.searchParams.has("k") ? "口令不对" : ""));
    return;
  }

  // 带 ?k= 进来的：签 cookie 后跳回不带 k 的地址，前端 URL 保持干净
  const k = url.searchParams.get("k");
  if (k && k === TOKEN && !NO_AUTH) {
    url.searchParams.delete("k");
    const target = url.pathname + (url.searchParams.toString() ? `?${url.searchParams}` : "");
    res.writeHead(302, {
      "Set-Cookie": `${COOKIE}=${TOKEN}; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000`,
      Location: target || "/",
      "Cache-Control": "no-store",
    }).end();
    return;
  }

  const proxyReq = http.request(
    {
      host: "127.0.0.1",
      port: API_PORT,
      method: req.method,
      path: req.url,
      headers: { ...req.headers, host: `127.0.0.1:${API_PORT}` },
    },
    (proxyRes) => {
      // 原样回传，一个头都不改（Alma 没有 CSP / X-Frame-Options，iframe 直接可用）
      res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);
      proxyRes.pipe(res);
    }
  );

  proxyReq.on("error", (err) => {
    log(`proxy error: ${err.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { "Content-Type": "text/plain; charset=utf-8" });
    }
    res.end(`alma-server 未响应（${err.code || err.message}）`);
  });

  req.pipe(proxyReq);
});

// WebSocket / 其他 upgrade：认证后直接对接字节流
server.on("upgrade", (req, socket, head) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  } catch {
    socket.destroy();
    return;
  }
  if (!authed(req, url)) {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
    socket.destroy();
    return;
  }

  const upstream = net.connect(API_PORT, "127.0.0.1", () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      const name = req.rawHeaders[i];
      let value = req.rawHeaders[i + 1];
      if (name.toLowerCase() === "host") value = `127.0.0.1:${API_PORT}`;
      lines.push(`${name}: ${value}`);
    }
    upstream.write(`${lines.join("\r\n")}\r\n\r\n`);
    if (head?.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });

  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});

server.listen(WEB_PORT, "0.0.0.0", () => {
  log(`alma gateway 0.0.0.0:${WEB_PORT} -> 127.0.0.1:${API_PORT}${NO_AUTH ? "（未启用口令）" : "（口令已启用）"}`);
});

for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000);
  });
}
