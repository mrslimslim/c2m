# CodePilot 启动与调试指南

> 面向开发者的本地运行、调试、验证手册

---

## 目录

1. [环境准备](#1-环境准备)
2. [构建项目](#2-构建项目)
3. [启动 Bridge](#3-启动-bridge)
4. [测试客户端调试](#4-测试客户端调试)
5. [开发模式（热编译）](#5-开发模式热编译)
6. [Relay 本地调试](#6-relay-本地调试)
7. [功能验证清单](#7-功能验证清单)
8. [常见问题排查](#8-常见问题排查)

---

## 1. 环境准备

### 1.1 必需

| 依赖 | 版本 | 说明 |
|------|------|------|
| Node.js | >= 18 | 需要内置 `crypto` 模块的 X25519 支持 |
| pnpm | >= 8 | Workspace monorepo 管理 |

### 1.2 可选（按使用的代理选装）

| 依赖 | 安装方式 | 说明 |
|------|----------|------|
| Codex CLI | `npm i -g @openai/codex` | 使用 Codex 代理时需要 |
| Claude Code CLI | `npm i -g @anthropic-ai/claude-code` | 使用 Claude 代理时需要 |
| Wrangler | `npm i -g wrangler` | 本地调试 Relay 服务器时需要 |

### 1.3 环境变量

```bash
# 使用 Codex 代理时
export OPENAI_API_KEY="sk-..."

# 使用 Claude 代理时（Claude Code CLI 自行管理认证，通常不需要额外设置）
```

---

## 2. 构建项目

```bash
# 安装依赖
pnpm install

# 全量构建（protocol → relay → bridge）
pnpm run build
```

构建产物输出到各包的 `dist/` 目录。三个包的构建顺序由依赖关系自动决定：

```
@codepilot/protocol  →  @codepilot/bridge
                     →  @codepilot/relay (独立)
```

---

## 3. 启动 Bridge

### 3.1 基本启动

```bash
# 自动检测代理，局域网模式，默认自动选择可用端口
node packages/bridge/dist/bin/codepilot.js
```

### 3.2 全部参数

```bash
node packages/bridge/dist/bin/codepilot.js [options]

Options:
  -a, --agent <type>      代理类型: codex | claude | auto (默认: auto)
  -p, --port <value>      WebSocket 端口 (默认: auto)
  --advertised-host <address>  覆盖 QR / pairing 输出中的主机地址
  -d, --dir <path>        工作目录 (默认: 当前目录)
  --relay                 启用 Relay 跨网络模式
  --relay-url <url>       自定义 Relay 服务器地址
  -V, --version           版本号
  -h, --help              帮助信息
```

### 3.3 典型场景

```bash
# 指定 Claude 代理 + 项目目录
node packages/bridge/dist/bin/codepilot.js --agent claude --dir ~/my-project

# 自定义端口
node packages/bridge/dist/bin/codepilot.js --port 8080

# 自动分配可用端口
node packages/bridge/dist/bin/codepilot.js --port auto

# 使用固定可达主机名生成 QR / pairing 信息
node packages/bridge/dist/bin/codepilot.js --advertised-host codepilot.tailnet.ts.net

# 通过 Relay 跨网络
node packages/bridge/dist/bin/codepilot.js --relay

# 使用本地 Relay 调试
node packages/bridge/dist/bin/codepilot.js --relay-url ws://localhost:8787
```

### 3.4 启动输出解读

启动成功后终端输出：

```
  +======================================+
  |   CodePilot Bridge v0.1.0             |
  |   Mobile AI Coding Command Center     |
  +======================================+

[codepilot] Working directory: /Users/you/project
[codepilot] Agent: claude
[codepilot] Mode: LAN (port auto)
[codepilot] Pairing state: /Users/you/.codepilot/pairing/abcd1234ef567890.json

✓ Agent: claude
✓ WebSocket server listening on ws://192.168.1.100:19260

[codepilot] Scan this QR code with your phone to connect:
  ▄▄▄▄▄▄▄ ▄▄▄ ▄▄▄▄▄▄▄     ← QR 码 (包含连接信息)
  ...

[codepilot] Or connect manually: ws://192.168.1.100:19260
[codepilot] Token: 4Ef5BA0805aE0Ea5...     ← Legacy 认证 Token
[codepilot] Open test client: http://192.168.1.100:19260?host=...&bridge_pubkey=...&otp=...
                                                         ↑ 浏览器测试 URL (直接点击/复制)
[codepilot] Waiting for phone connection...
```

关键信息：
- **QR 码**：手机扫码连接，内含 host、port、pubkey、otp
- **Token**：Legacy 模式的认证令牌
- **Pairing state**：bridge 会按工作目录持久化 pairing material，重启同一项目时默认复用
- **测试客户端 URL**：浏览器打开即可调试，所有参数已自动拼接

---

## 4. 测试客户端调试

### 4.1 打开

复制终端输出的 `Open test client:` URL 到浏览器打开。URL 包含全部连接参数，打开后 **自动连接 + E2E 握手**。

### 4.2 界面说明

```
┌─────────────────────────────────────┐
│ ● CodePilot  [E2E]    Connected     │  ← 状态栏：绿点=已连接, E2E徽章=加密
├─────────────────────────────────────┤
│                                     │
│  [STATUS] thinking                  │  ← 事件流：不同颜色区分事件类型
│  [AGENT] Hello, I can help...       │     蓝=status 紫=thinking 绿=agent
│  [CODE CHANGE] 2 files              │     黄=code_change 红=command/error
│  [TURN COMPLETED] Done. Files: ...  │     绿=turn_completed
│                                     │
├─────────────────────────────────────┤
│  [输入框]                    [发送]  │  ← 命令输入 (Enter 发送)
│  [List files] [Run tests] [Git...] │  ← 快捷按钮
└─────────────────────────────────────┘
```

### 4.3 手动连接（不通过 URL 参数）

如果未使用自动填充 URL，可在连接面板手动输入：
- **Host IP**: Bridge 所在机器的局域网 IP
- **Port**: 终端输出里的实际监听端口
- **Token**: 终端输出的 Token 值

点击 Connect 即可。此方式使用 Legacy Token 认证，不启用 E2E 加密。

---

## 5. 开发模式（热编译）

```bash
# 终端 1：监听所有包的文件变更，自动重新编译
pnpm run dev

# 终端 2：启动 Bridge（代码变更后需手动重启）
node packages/bridge/dist/bin/codepilot.js --agent claude
```

`pnpm run dev` 等同于在所有包中并行运行 `tsc --watch`。

**提示**：修改 `packages/protocol/src/` 下的类型定义后，`bridge` 包会自动重新编译（因为 `tsc --watch` 会检测到依赖变化）。

---

## 6. Relay 本地调试

### 6.1 启动本地 Relay

```bash
cd packages/relay

# 使用 Wrangler 本地模拟 Cloudflare Workers
npx wrangler dev
# 默认监听 http://localhost:8787
```

### 6.2 Bridge 连接本地 Relay

```bash
# 另一个终端
node packages/bridge/dist/bin/codepilot.js --relay-url ws://localhost:8787
```

### 6.3 验证 Relay 连通

1. Bridge 启动后输出 `Connected to relay channel: xxxxxxxxxxxx`
2. 打开测试客户端（需要手动连接到 Relay 的 WebSocket 地址）
3. 在测试客户端发送指令，观察 Bridge 终端是否收到

### 6.4 部署到 Cloudflare

```bash
cd packages/relay

# 登录 Cloudflare
npx wrangler login

# 部署
npx wrangler deploy

# 输出类似: https://codepilot-relay.your-account.workers.dev
```

部署后使用：
```bash
node packages/bridge/dist/bin/codepilot.js --relay-url wss://codepilot-relay.your-account.workers.dev
```

---

## 7. 功能验证清单

### 7.1 路径安全（文件沙箱）

在测试客户端的输入框中直接通过 WebSocket 发送（或写代码发送）：

```json
{"type": "file_req", "path": "../../../etc/passwd", "sessionId": "test"}
```

**预期**：返回 `{"type": "error", "message": "Access denied: ..."}`

**也可使用 wscat 验证**：
```bash
# 安装
npm i -g wscat

# 连接
wscat -c ws://192.168.1.x:<port>

# 发送认证
> {"type": "auth", "token": "终端输出的token"}

# 尝试路径穿越
> {"type": "file_req", "path": "../../../etc/passwd", "sessionId": "test"}
# 应返回 Access denied

# 尝试敏感文件
> {"type": "file_req", "path": ".env", "sessionId": "test"}
# 应返回 Access denied: .env is a sensitive file
```

### 7.2 E2E 加密

1. 启动 Bridge
2. 用带完整参数（含 `bridge_pubkey` 和 `otp`）的 URL 打开测试客户端
3. **验证**：
   - 头部出现绿色 **E2E** 徽章
   - 事件流显示 `E2E Encrypted - Handshake complete`
4. 发送任意指令，在 Bridge 侧用 Wireshark 或日志确认传输的是密文

### 7.3 消息校验

```bash
wscat -c ws://192.168.1.x:<port>
> {"type": "auth", "token": "xxx"}
# 认证后发送畸形消息
> {"type": "command"}
# 缺少 text 字段，应返回 Invalid message format

> {"type": "unknown_type"}
# 未知类型，应返回 Invalid message format

> not json at all
# 应返回 Invalid message format
```

### 7.4 Claude 可用性检查

```bash
# 确保 claude 未安装（或临时 rename）
node packages/bridge/dist/bin/codepilot.js --agent claude
# 应报错: Claude Code CLI is not installed. Install it with: ...
```

### 7.5 Session ID 竞态（Codex）

1. 启动 Bridge 使用 Codex 代理
2. 发送一条指令，记录返回事件中的 `sessionId`
3. 立即用该 sessionId 发送第二条指令
4. **验证**：即使 Codex 已将 session ID 替换为真实 thread ID，旧 ID 仍能路由到正确的 session

---

## 8. 常见问题排查

### Q: 启动报 `Cannot find module` 错误

```
Error: Cannot find module '.../dist/bin/codepilot.js'
```

**原因**：未构建。
**解决**：`pnpm run build`

---

### Q: `Error: listen EADDRINUSE :::<port>`

**原因**：你显式指定的端口已被占用，或另一条 bridge 还在使用同一个固定端口。
**解决**：

```bash
# 查看占用进程
lsof -i :<port>

# 杀死进程
kill -9 <PID>

# 或换成自动端口 / 其他固定端口
node packages/bridge/dist/bin/codepilot.js --port auto
node packages/bridge/dist/bin/codepilot.js --port 19261
```

---

### Q: QR 码显示的 IP 不对（显示公网 IP 或 VPN IP）

**原因**：`getLocalIp()` 取了非预期的网络接口。
**解决**：优先使用 `--advertised-host <address>` 指定手机实际应连接的稳定地址；临时调试时也可以在测试客户端里手动改成正确的局域网 IP。

---

### Q: 测试客户端连接后没有 E2E 徽章

**原因**：URL 中缺少 `bridge_pubkey` 或 `otp` 参数。
**解决**：使用终端输出的完整 `Open test client:` URL，不要手动截断。

---

### Q: Claude 代理报 `spawn claude ENOENT`

**原因**：Claude Code CLI 未安装或不在 PATH 中。
**解决**：

```bash
npm install -g @anthropic-ai/claude-code
which claude  # 确认可找到
```

---

### Q: Codex 代理报 API key 错误

**原因**：缺少 `OPENAI_API_KEY` 环境变量。
**解决**：

```bash
export OPENAI_API_KEY="sk-..."
```

---

### Q: Relay 本地调试 `wrangler dev` 报错

**原因**：Wrangler 未安装或版本过低。
**解决**：

```bash
npm install -g wrangler@latest
cd packages/relay
npx wrangler dev
```

---

### Q: 构建时 `packages/relay` 报 `tsc: command not found`

**原因**：relay 包的 `node_modules` 未正确安装。
**解决**：在项目根目录重新 `pnpm install`。
