import { timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import http from "node:http";
import process from "node:process";
import { fileURLToPath } from "node:url";
import httpProxy from "http-proxy";

const authToken = process.env.MCP_AUTH_TOKEN;
if (!authToken) {
  throw new Error("MCP_AUTH_TOKEN must be configured.");
}

const listenPort = Number.parseInt(
  process.env.MCP_PORT ?? process.env.PORT ?? "8080",
  10,
);
const upstreamPort = Number.parseInt(
  process.env.PLAYWRIGHT_MCP_PORT ?? "8931",
  10,
);
const upstreamUrl = `http://127.0.0.1:${upstreamPort}`;

const playwrightCli = fileURLToPath(
  new URL("./node_modules/@playwright/mcp/cli.js", import.meta.url),
);
const playwright = spawn(
  process.execPath,
  [
    playwrightCli,
    "--headless",
    "--isolated",
    "--block-service-workers",
    "--ignore-https-errors",
    "--browser",
    "chromium",
    "--host",
    "127.0.0.1",
    "--port",
    String(upstreamPort),
    "--allowed-hosts",
    "*",
    "--allowed-origins",
    "https://example.com;https://*.craigslist.org;https://craigslist.org;https://learn.microsoft.com;https://playwright.dev",
    "--image-responses",
    "omit",
    "--codegen",
    "none",
  ],
  { stdio: "inherit" },
);

playwright.on("error", (error) => {
  console.error("Failed to start Playwright MCP:", error);
  process.exit(1);
});

playwright.on("exit", (code, signal) => {
  console.error(`Playwright MCP exited: code=${code} signal=${signal}`);
  process.exit(code ?? 1);
});

const proxy = httpProxy.createProxyServer({
  target: upstreamUrl,
  changeOrigin: false,
  xfwd: false,
});

proxy.on("error", (error, _request, response) => {
  console.error("Playwright MCP proxy error:", error);
  if (!response.headersSent) {
    response.writeHead(502, { "content-type": "application/json" });
  }
  response.end(JSON.stringify({ error: "browser_mcp_unavailable" }));
});

function isAuthorized(request) {
  const supplied = request.headers.authorization ?? "";
  const expected = `Bearer ${authToken}`;
  const suppliedBuffer = Buffer.from(supplied);
  const expectedBuffer = Buffer.from(expected);
  return (
    suppliedBuffer.length === expectedBuffer.length &&
    timingSafeEqual(suppliedBuffer, expectedBuffer)
  );
}

const server = http.createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ status: "ok" }));
    return;
  }

  if (!isAuthorized(request)) {
    response.writeHead(401, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }

  proxy.web(request, response);
});

server.listen(listenPort, "0.0.0.0", () => {
  console.log(`Authenticated Playwright MCP proxy listening on ${listenPort}`);
});

function shutdown(signal) {
  console.log(`Received ${signal}; shutting down.`);
  server.close(() => process.exit(0));
  playwright.kill("SIGTERM");
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
