# CodePilot 技术文档

> Mobile Command Center for AI Coding Agents
>
> Version 0.1.0 | Phase 1

---

## 目录

1. [项目概览](#1-项目概览)
2. [系统架构](#2-系统架构)
3. [包结构](#3-包结构)
4. [协议层 — @codepilot/protocol](#4-协议层)
5. [桥接层 — @codepilot/bridge](#5-桥接层)
6. [中继层 — @codepilot/relay](#6-中继层)
7. [E2E 加密](#7-e2e-加密)
8. [安全机制](#8-安全机制)
9. [CLI 使用指南](#9-cli-使用指南)
10. [测试客户端](#10-测试客户端)
11. [部署指南](#11-部署指南)
12. [开发参考](#12-开发参考)

---

## 1. 项目概览

### 1.1 定位

CodePilot 是一个**手机远程控制 AI 编程代理**的系统。用户在手机上发送自然语言指令，Bridge 进程将指令转发给本地运行的 AI 编程代理（Codex 或 Claude Code），并将代理产生的事件实时流式回传到手机。

### 1.2 核心能力

| 能力 | 说明 |
|------|------|
| 多代理支持 | Codex SDK（`@openai/codex-sdk`）和 Claude Code CLI |
| 局域网直连 | WebSocket 服务器，QR 码扫码配对 |
| 跨网络中继 | Cloudflare Workers Durable Objects 中继 |
| E2E 加密 | X25519 + HKDF + AES-256-GCM，中继服务器无法解密 |
| 路径安全 | 文件请求沙箱化，阻止路径穿越和敏感文件泄露 |

### 1.3 技术栈

- **Runtime**: Node.js >= 18, TypeScript 5.7, ES2022 Modules
- **构建**: `tsc` 直接编译，pnpm workspace monorepo
- **传输**: WebSocket (`ws` 库)
- **加密**: Node.js `crypto` (服务端) / Web Crypto API (浏览器端)
- **中继**: Cloudflare Workers + Durable Objects + WebSocket Hibernation API

---

## 2. 系统架构

### 2.1 整体拓扑

```
┌──────────┐                    ┌──────────────┐                 ┌───────────┐
│          │   WebSocket/E2E    │              │   SDK / CLI     │           │
│  Phone   │◄──────────────────►│    Bridge    │◄───────────────►│  AI Agent │
│  (App)   │   JSON encrypted   │  (Node.js)  │   JSONL stream  │ Codex/    │
│          │                    │              │                 │ Claude    │
└──────────┘                    └──────────────┘                 └───────────┘
      │                               │
      │  Cross-network (optional)     │
      │         ┌──────────┐          │
      └────────►│  Relay   │◄─────────┘
                │  (CF DO) │
                └──────────┘
```

### 2.2 数据流

```
Phone                        Bridge                       Agent
  │                            │                            │
  │─── handshake (pubkey) ────►│                            │
  │◄── handshake_ok ──────────│                            │
  │                            │                            │
  │─── command (encrypted) ───►│                            │
  │                            │─── execute(text) ─────────►│
  │                            │◄── event stream ──────────│
  │◄── events (encrypted) ────│                            │
  │                            │◄── turn_completed ────────│
  │◄── turn_completed ────────│                            │
```

### 2.3 模块依赖关系

```
@codepilot/protocol   ← 零依赖，纯 TypeScript 类型定义
       ▲
       │
@codepilot/bridge     ← 依赖 protocol, ws, commander, codex-sdk, qrcode-terminal
       │
       ├── adapters/    (Codex, Claude)
       ├── transport/   (Local, Relay)
       ├── pairing/     (QR code, Crypto)
       └── bin/         (CLI 入口)

@codepilot/relay      ← 独立包，Cloudflare Workers，无运行时依赖
```

---

## 3. 包结构

```
packages/
├── protocol/                    # 协议定义
│   └── src/
│       ├── state.ts             # AgentState, SessionInfo, FileChange, TokenUsage
│       ├── events.ts            # AgentEvent 联合类型 (7 种事件)
│       ├── messages.ts          # PhoneMessage / BridgeMessage / Handshake / Encrypted
│       └── index.ts             # Re-export
│
├── bridge/                      # Bridge 主包
│   ├── src/
│   │   ├── bridge.ts            # Bridge 主编排器
│   │   ├── index.ts             # Public API
│   │   ├── adapters/
│   │   │   ├── types.ts         # AgentAdapter 接口
│   │   │   ├── codex.ts         # CodexAdapter (Codex SDK)
│   │   │   ├── claude.ts        # ClaudeAdapter (Claude CLI)
│   │   │   └── index.ts
│   │   ├── transport/
│   │   │   ├── types.ts         # TransportServer / TransportClient 接口
│   │   │   ├── local.ts         # LocalTransport (LAN WebSocket + E2E)
│   │   │   ├── relay.ts         # RelayTransport (Relay WebSocket 客户端)
│   │   │   └── index.ts
│   │   ├── pairing/
│   │   │   ├── crypto.ts        # E2E 加密模块 (X25519 + AES-256-GCM)
│   │   │   └── qrcode.ts        # QR 码生成
│   │   ├── utils/
│   │   │   └── logger.ts        # 彩色日志
│   │   └── bin/
│   │       └── codepilot.ts     # CLI 入口
│   └── test-client.html         # 浏览器测试客户端
│
└── relay/                       # Relay 中继服务器
    ├── src/
    │   ├── index.ts             # Worker 入口 + 路由
    │   └── channel.ts           # Channel Durable Object
    └── wrangler.toml            # Cloudflare 部署配置
```

**源文件统计**: 21 个 `.ts` 源文件 + 1 个 `.html` 测试客户端，共约 2600 行代码。

---

## 4. 协议层

### 4.1 Agent 状态机

```typescript
type AgentState = "idle" | "thinking" | "coding" | "running_command" | "waiting_approval" | "error";
```

状态转移由 Agent 事件驱动，Bridge 负责同步到 `SessionInfo` 并转发给手机。

### 4.2 Agent 事件 (`AgentEvent`)

| 事件类型 | 字段 | 触发时机 |
|----------|------|----------|
| `status` | `state`, `message` | 代理状态变更 |
| `thinking` | `text` | 推理/思考过程 |
| `code_change` | `changes: FileChange[]` | 代码文件修改 |
| `command_exec` | `command`, `output?`, `exitCode?`, `status` | 命令执行 |
| `agent_message` | `text` | 代理文本回复 |
| `error` | `message` | 错误 |
| `turn_completed` | `summary`, `filesChanged`, `usage` | 一轮交互结束 |

### 4.3 手机 → Bridge 消息 (`PhoneMessage`)

| 类型 | 字段 | 说明 |
|------|------|------|
| `command` | `text`, `sessionId?` | 发送指令 |
| `slash_action` | `commandId`, `sessionId?`, `arguments?` | 执行由 bridge 处理的 slash 动作 |
| `cancel` | `sessionId` | 取消执行 |
| `file_req` | `path`, `sessionId` | 请求文件内容 |
| `list_sessions` | — | 获取会话列表 |
| `ping` | `ts` | 延迟测量 |
| `sync_session` | `sessionId`, `afterEventId` | 按事件游标请求会话增量回放 |

### 4.4 Bridge → 手机消息 (`BridgeMessage`)

| 类型 | 字段 | 说明 |
|------|------|------|
| `event` | `sessionId`, `event`, `timestamp` | 代理事件 |
| `session_list` | `sessions: SessionInfo[]` | 会话列表 |
| `session_sync_complete` | `sessionId`, `latestEventId`, `resolvedSessionId?` | 会话增量回放完成 |
| `file_content` | `path`, `content`, `language` | 文件内容 |
| `slash_catalog` | `adapter`, `adapterVersion?`, `catalogVersion`, `defaults`, `commands` | 当前适配器版本下的 slash 元数据 |
| `slash_action_result` | `commandId`, `ok`, `message?` | slash 动作执行结果 |
| `pong` | `latencyMs` | Pong 响应 |
| `error` | `message` | 错误 |

### 4.5 扩展能力：会话回放与 Slash Catalog

`handshake_ok.capabilities` 用来声明 bridge 当前支持的扩展能力。当前已使用两个能力位：

- `session_replay_v1`: iOS 端可以在重连或发现事件 gap 时发送 `sync_session`
- `slash_catalog_v1`: bridge 会在连接建立后主动下发 `slash_catalog`

`SessionConfig` 也已经扩展为可携带以下字段：

```typescript
interface SessionConfig {
  model?: string;
  modelReasoningEffort?: string;
  approvalPolicy?: string;
  sandboxMode?: string;
}
```

其中 `modelReasoningEffort` 允许 iOS 客户端把 `/model -> reasoning` 这种两级 slash 流程映射成真实的 Codex 会话配置，而不是本地伪配置。

`slash_catalog` 采用“bridge 按 adapter + version 生成元数据，客户端纯渲染”的模式：

- bridge 在启动时探测适配器版本，例如当前 Codex 通过 `codex --version` 探测到 `codex-cli 0.116.0`
- 根据 `adapter + adapterVersion` 选择 slash catalog
- iOS 端只存储 catalog，并基于 catalog 渲染嵌套菜单、默认值、当前值、禁用原因

Slash 元数据中的关键结构：

- `SlashCommandMeta`: 根命令定义，区分 `workflow` / `bridge_action` / `client_action` / `insert_text`
- `SlashMenuNode`: 递归菜单节点，支持多层嵌套
- `SlashEffect`: 本地效果，目前支持 `set_session_config`、`set_input_text`、`clear_input_text`

这使得 `/model`、`/permissions` 这类多层配置命令可以完全由协议驱动，而不是写死在 iOS 客户端。

### 4.6 E2E 握手消息

| 类型 | 方向 | 字段 | 说明 |
|------|------|------|------|
| `handshake` | Phone → Bridge | `phone_pubkey`, `otp` | E2E 密钥交换发起 |
| `handshake_ok` | Bridge → Phone | `encrypted`, `clientId?` | 握手成功确认 |

### 4.7 加密消息线格式

```typescript
interface EncryptedWireMessage {
  v: 1;                  // 协议版本
  nonce: string;         // 12 bytes, base64
  ciphertext: string;    // base64
  tag: string;           // 16 bytes, base64 (GCM auth tag)
}
```

握手完成后，所有 `PhoneMessage` 和 `BridgeMessage` 均被序列化为 JSON → 加密 → 包装为 `EncryptedWireMessage` 再发送。

---

## 5. 桥接层

### 5.1 Bridge 主编排器

**文件**: `packages/bridge/src/bridge.ts`

`Bridge` 类是核心，连接三个子系统：

```
Bridge
├── adapter: AgentAdapter       # 当前 AI 代理
├── transport: TransportServer  # 当前传输层
└── sessions: Map<string, SessionInfo>
```

**启动流程**:
1. 解析代理类型（auto-detect 优先尝试 Codex，回退 Claude）
2. 探测适配器版本，并缓存对应的 slash catalog
3. 如果 `--relay` 模式，动态 import `RelayTransport`
4. 启动传输层，获取 `url`、`httpUrl`、`pairingData`
5. 生成并显示 QR 码
6. 注册 `onConnect` / `onDisconnect` / `onMessage` 处理器
7. 注册 SIGINT / SIGTERM 优雅关闭

**消息路由**:

```typescript
handleMessage(client, message) {
  switch (message.type) {
    case "command"       → handleCommand() → adapter.execute()
    case "slash_action"  → dispatchSlashAction()
    case "cancel"        → adapter.cancel()
    case "list_sessions" → 返回 sessions 列表
    case "ping"          → 返回 pong + latency
    case "file_req"      → handleFileRequest() (带安全校验)
    case "sync_session"  → 返回指定会话的增量事件并以 session_sync_complete 收尾
  }
}
```

### 5.2 Slash Catalog 生成

Bridge 侧新增 `src/slash/` 目录，负责：

- 通过 `detectAdapterVersion()` 探测适配器版本
- 按 `adapter + version` 生成 `slash_catalog`
- 在客户端连接成功后主动发送 catalog
- 处理来自手机的 `slash_action`

当前 Codex `0.116.0` catalog 已覆盖：

- `/model`
- `/fast`
- `/permissions`
- `/experimental`
- `/skills`
- `/review`
- `/rename`
- `/new`

其中：

- `/model` 和 `/permissions` 是 `workflow`
- `/new` 是 `client_action`
- 尚未真实打通的桥接命令会以 `disabled + reason` 下发，而不是客户端假装可用

### 5.3 Agent Adapter 接口

```typescript
interface AgentAdapter {
  readonly name: "codex" | "claude";
  startSession(opts: SessionOptions): Promise<SessionInfo>;
  execute(sessionId: string, input: string, onEvent: (event: AgentEvent) => void): Promise<void>;
  resumeSession(sessionId: string): Promise<SessionInfo>;
  cancel(sessionId: string): void;
  dispose(): void;
}
```

#### 5.3.1 CodexAdapter

**文件**: `packages/bridge/src/adapters/codex.ts`

- 使用 `@openai/codex-sdk` 的 `Codex` 类
- `startSession()` → `codex.startThread()` 配置模型/沙箱/审批策略
- `execute()` → `thread.runStreamed(input)` 获取事件流
- 事件映射：`thread.started` → 更新 session ID（保留旧 ID 作为别名）；`item.*` → 映射为统一 AgentEvent；`turn.completed` → 汇总 filesChanged 和 usage

**Session ID 别名机制**: Codex 的 thread ID 在 `thread.started` 事件后才可用。创建时先分配临时 ID `codex-{ts}-{rand}`，真实 ID 到达后**同时保留**新旧两个 key 指向同一 session 对象，避免手机端在此窗口期发送命令时找不到 session。

#### 5.3.2 ClaudeAdapter

**文件**: `packages/bridge/src/adapters/claude.ts`

- 通过 `spawn("claude", args)` 启动 CLI 进程
- 参数：`-p --output-format stream-json --permission-mode acceptEdits`
- 会话续接：`-r {lastSessionId}`
- 逐行解析 JSONL stdout，映射 Claude stream-json 事件到统一 AgentEvent

**可用性检查**: `startSession()` 执行 `which claude` 确认 CLI 已安装，否则抛出带安装说明的错误。

**filesChanged 收集**: execute 过程中维护 `changedFiles: Set<string>`，每次遇到 Write/Edit tool_use 事件时将文件路径加入集合，进程退出时在 `turn_completed` 中汇总返回。

### 5.4 Transport 接口

```typescript
interface TransportServer {
  start(): Promise<{ url: string; httpUrl: string; pairingData: Record<string, unknown> }>;
  onMessage(handler: (client: TransportClient, message: PhoneMessage) => void): void;
  onConnect(handler: (client: TransportClient) => void): void;
  onDisconnect(handler: (client: TransportClient) => void): void;
  broadcast(message: BridgeMessage): void;
  stop(): Promise<void>;
}

interface TransportClient {
  id: string;
  send(message: BridgeMessage): void;
}
```

`Bridge` 仅依赖此接口，不做类型转换。`LocalTransport` 和 `RelayTransport` 均实现此接口。

#### 5.4.1 LocalTransport

**文件**: `packages/bridge/src/transport/local.ts`

- 在 `0.0.0.0:{port}` 启动 HTTP + WebSocket 服务器
- HTTP 服务提供 `test-client.html` 测试页面
- 支持两种认证流程：
  - **E2E 握手**：`handshake` → 验证 OTP → ECDH 密钥派生 → `handshake_ok`
  - **Legacy Token**：`auth` + token → `auth_ok`
- E2E 客户端的后续消息自动解密/加密
- `broadcast()` 自动为每个客户端选择加密或明文发送

**消息校验**: `validatePhoneMessage(data)` 函数在运行时检查每种消息类型的必需字段和类型，拒绝畸形消息。

**错误处理**: WebSocket `error` 事件记录日志并触发 disconnect handler，确保 Bridge 能正确清理状态。

**QR 码配对数据**:
```json
{
  "host": "192.168.1.x",
  "port": 19412,
  "token": "hex32",
  "bridge_pubkey": "base64(32 bytes)",
  "otp": "hex6",
  "protocol": "codepilot-v1-e2e"
}
```

#### 5.4.2 RelayTransport

**文件**: `packages/bridge/src/transport/relay.ts`

- Bridge 端的 Relay WebSocket 客户端
- 连接地址：`wss://{relayUrl}/ws?device=bridge&channel={channelId}`
- `channelId` = `sha256(bridge_pubkey).hex().slice(0, 12)`
- 自动重连：指数退避，最多 10 次
- 处理 Relay 控制消息：`relay_peer_connected` / `relay_peer_disconnected`
- 对 Bridge 而言完全透明——同样的 `TransportServer` 接口

---

## 6. 中继层

### 6.1 架构

```
Phone ──WSS──► Cloudflare Edge ──► Durable Object (Channel) ◄── WSS ──── Bridge
```

- 每个 channel 由一个 **Durable Object** 实例管理
- 使用 **WebSocket Hibernation API** 降低资源消耗
- 无用户注册/账号系统
- Relay 只做消息转发，**不解密**（零知识设计）

### 6.2 Worker 入口

**文件**: `packages/relay/src/index.ts`

| 路由 | 说明 |
|------|------|
| `GET /health` | 健康检查 |
| `GET /ws?device={bridge\|phone}&channel={id}` | WebSocket 升级，路由到 Channel DO |
| `OPTIONS *` | CORS preflight |

channel 参数用作 Durable Object 的命名 ID (`idFromName(channel)`)，确保 bridge 和 phone 连接到同一实例。

### 6.3 Channel Durable Object

**文件**: `packages/relay/src/channel.ts`

**状态**:
- `sockets: Map<"bridge"|"phone", WebSocket>` — 最多两个连接
- `messageCache: Map<DeviceRole, CachedMessage[]>` — 离线消息缓存

**核心逻辑**:

| 操作 | 行为 |
|------|------|
| 设备连接 | 替换已有同角色连接；发送缓存的离线消息；通知对端 `relay_peer_connected` |
| 收到消息 | 直接转发给对端；对端不在线则缓存 |
| 设备断开 | 通知对端 `relay_peer_disconnected` |

**离线缓存策略**:
- 最多 100 条消息
- 24 小时过期
- FIFO 淘汰
- 持久化到 Durable Object Storage

---

## 7. E2E 加密

### 7.1 密码学原语

| 功能 | 算法 | 参数 |
|------|------|------|
| 密钥交换 | X25519 (Curve25519 ECDH) | 32 byte 密钥 |
| 密钥派生 | HKDF-SHA256 | salt = OTP, info = `"codepilot-e2e-v1"`, 输出 32 bytes |
| 消息加密 | AES-256-GCM | 12 byte nonce, 16 byte auth tag |

全部使用 Node.js 内置 `crypto` 模块，**零外部加密依赖**。

### 7.2 密钥交换流程

```
Bridge                                      Phone
  │                                           │
  │  1. generateKeyPairSync("x25519")         │
  │     bridge_pubkey → QR code               │
  │                                           │  2. crypto.subtle.generateKey("X25519")
  │                                           │
  │◄─── { handshake, phone_pubkey, otp } ────│  3. 首条消息 (明文)
  │                                           │
  │  4. diffieHellman(bridge_priv, phone_pub) │  4. deriveBits(phone_priv, bridge_pub)
  │     shared_secret (32 bytes)              │     shared_secret (32 bytes)
  │                                           │
  │  5. hkdfSync(sha256, shared, otp,         │  5. deriveKey(HKDF, sha256, shared, otp,
  │     "codepilot-e2e-v1", 32)               │     "codepilot-e2e-v1", AES-GCM-256)
  │     session_key (32 bytes)                │     session_key (CryptoKey)
  │                                           │
  │──── { handshake_ok, encrypted: true } ───►│  6. 最后一条明文
  │                                           │
  │◄═══ AES-256-GCM encrypted JSON ══════════►│  7. 后续全部加密
```

### 7.3 加密模块 API

**文件**: `packages/bridge/src/pairing/crypto.ts`

```typescript
// 生成 X25519 密钥对
function generateKeyPair(): E2EKeyPair;

// 从私钥 + 对方公钥 + OTP 派生会话密钥
function deriveSessionKey(myPrivateKey: KeyObject, theirPublicKeyBase64: string, otp: string): E2ESession;

// AES-256-GCM 加密
function encrypt(session: E2ESession, plaintext: string): EncryptedMessage;

// AES-256-GCM 解密
function decrypt(session: E2ESession, msg: EncryptedMessage): string;
```

### 7.4 浏览器端实现

测试客户端 (`test-client.html`) 使用 **Web Crypto API**：

| Node.js | Web Crypto |
|---------|------------|
| `generateKeyPairSync("x25519")` | `crypto.subtle.generateKey("X25519")` |
| `diffieHellman()` | `crypto.subtle.deriveBits({ name: "X25519" })` |
| `hkdfSync()` | `crypto.subtle.deriveKey({ name: "HKDF" })` |
| `createCipheriv("aes-256-gcm")` | `crypto.subtle.encrypt({ name: "AES-GCM" })` |

两端生成完全相同的 session key，可互相解密。

### 7.5 安全属性

- **前向保密**：每次 Bridge 启动生成新的 X25519 密钥对
- **中继零知识**：Relay 只转发密文，无法获取 session key
- **OTP 绑定**：共享密钥派生绑定 OTP，防止中间人替换公钥
- **认证加密**：AES-GCM 提供机密性 + 完整性 + 认证
- **Nonce 唯一性**：每次加密使用 `crypto.randomBytes(12)` 生成随机 nonce

---

## 8. 安全机制

### 8.1 文件路径沙箱

`Bridge.handleFileRequest()` 实施三层防护：

```
1. 路径解析:  resolve(workDir, filePath) → absolutePath
2. 沙箱检查:  absolutePath.startsWith(workDir + "/")
3. 穿越拒绝:  filePath.includes("..") → 拒绝
4. 敏感文件:  正则匹配黑名单 → 拒绝
```

**敏感文件黑名单**:

| 模式 | 示例 |
|------|------|
| `^\.env($\|\.)` | `.env`, `.env.local`, `.env.production` |
| `^\.git/config$` | `.git/config` |
| `^\.git/credentials$` | `.git/credentials` |
| `^\.ssh/` | `.ssh/id_rsa` |
| `^\.npmrc$` | `.npmrc` (可能含 token) |
| `credentials\.json$` | `service-credentials.json` |
| `secrets?\.(json\|ya?ml\|toml)$` | `secrets.json`, `secret.yaml` |
| `\.pem$` | `server.pem` |
| `\.key$` | `private.key` |

### 8.2 消息校验

`validatePhoneMessage()` 函数对每种消息类型进行运行时类型检查：

```typescript
// 检查项:
// - msg 是 object 且非 null
// - msg.type 是有效枚举值
// - 各类型的必需字段存在且类型正确:
//   command  → text: string (非空), sessionId?: string
//   cancel   → sessionId: string
//   file_req → path: string, sessionId: string
//   ping     → ts: number
```

拒绝的消息返回 `{ type: "error", message: "Invalid message format" }`。

### 8.3 认证机制

| 模式 | 认证方式 | 安全性 |
|------|----------|--------|
| Legacy Token | 32 byte 随机 hex token | 仅局域网适用 |
| E2E Handshake | X25519 公钥 + 6 字符 OTP | 端到端加密，中继安全 |

两种模式在同一 `LocalTransport` 中并存，向后兼容。

---

## 9. CLI 使用指南

### 9.1 安装

```bash
# 全局安装 (未发布到 npm 前使用本地构建)
pnpm install
pnpm run build
```

### 9.2 命令行参数

```
codepilot [options]

Options:
  -a, --agent <type>      Agent type: codex | claude | auto (default: "auto")
  -p, --port <value>      WebSocket port (default: "auto")
  --advertised-host <address>  Override the host embedded in QR/pairing output
  -d, --dir <path>        Working directory (default: ".")
  --relay                 Use Relay server for cross-network connections
  --relay-url <url>       Custom Relay server URL
  -V, --version           Output version number
  -h, --help              Display help
```

### 9.3 使用场景

```bash
# 基本使用：局域网直连，自动检测代理
npx codepilot

# 指定代理和端口
npx codepilot --agent claude --port 8080

# 指定工作目录
npx codepilot --dir /path/to/my-project

# 跨网络模式（通过中继服务器）
npx codepilot --relay

# 自定义中继服务器
npx codepilot --relay-url wss://my-relay.example.com
```

### 9.4 代理自动检测

```
auto 模式:
  1. which codex → 成功 → 使用 CodexAdapter
  2. 失败 → 使用 ClaudeAdapter (需 claude CLI)
```

---

## 10. 测试客户端

**文件**: `packages/bridge/test-client.html`

Bridge 启动后自动在 `http://{ip}:{port}/` 提供测试客户端页面。

### 10.1 功能

- 连接面板：Host、Port、Token 输入
- 事件流：按类型着色显示所有代理事件
- 命令输入：文本框 + 快捷按钮（List files / Run tests / Git status / Explain）
- E2E 加密指示：连接时显示 "E2E" 徽章
- URL 参数自动填充：`?host=x&port=y&token=z&bridge_pubkey=pk&otp=otp`

### 10.2 E2E 加密流程

浏览器端使用 `E2ECrypto` 类封装 Web Crypto API：

1. URL 中包含 `bridge_pubkey` 和 `otp` 参数时自动启用 E2E
2. `generateKeyPair()` → X25519 密钥对
3. 发送 `handshake` 消息（明文）
4. 收到 `handshake_ok` → `deriveSessionKey()` 派生 AES-GCM 密钥
5. 后续所有消息通过 `encrypt()` / `decrypt()` 处理

---

## 11. 部署指南

### 11.1 Relay 部署 (Cloudflare Workers)

```bash
cd packages/relay

# 开发模式
pnpm dev

# 生产部署
pnpm deploy
```

**wrangler.toml 配置**:

```toml
name = "codepilot-relay"
main = "src/index.ts"
compatibility_date = "2025-01-01"

[durable_objects]
bindings = [{ name = "CHANNEL", class_name = "Channel" }]

[[migrations]]
tag = "v1"
new_classes = ["Channel"]
```

### 11.2 自定义 Relay URL

部署后获取 Workers URL (如 `https://codepilot-relay.username.workers.dev`)，使用方式：

```bash
npx codepilot --relay-url wss://codepilot-relay.username.workers.dev
```

---

## 12. 开发参考

### 12.1 构建

```bash
# 全部构建
pnpm run build

# 单包构建
cd packages/protocol && pnpm run build
cd packages/bridge && pnpm run build

# 监听模式
pnpm run dev
```

### 12.2 添加新的 Agent Adapter

1. 创建 `packages/bridge/src/adapters/my-agent.ts`
2. 实现 `AgentAdapter` 接口
3. 在 `Bridge.resolveAdapter()` 中添加检测逻辑
4. 在 `BridgeOptions.agent` 类型联合中添加新类型

### 12.3 添加新的消息类型

1. 在 `packages/protocol/src/messages.ts` 中定义接口
2. 添加到 `PhoneMessage` 或 `BridgeMessage` 联合类型
3. 在 `packages/bridge/src/transport/local.ts` 的 `validatePhoneMessage()` 中添加校验
4. 在 `Bridge.handleMessage()` 中添加 case 分支
5. 在 `test-client.html` 中添加消息处理

### 12.4 添加新的 Transport

1. 创建 `packages/bridge/src/transport/my-transport.ts`
2. 实现 `TransportServer` 接口
3. `start()` 返回 `{ url, httpUrl, pairingData }`
4. 在 `Bridge` 构造函数或 `start()` 中按条件初始化

### 12.5 关键类型速查

```typescript
// 状态
type AgentState = "idle" | "thinking" | "coding" | "running_command" | "waiting_approval" | "error";

// 会话
interface SessionInfo {
  id: string; agentType: "codex" | "claude"; workDir: string;
  state: AgentState; createdAt: number; lastActiveAt: number;
}

// 文件变更
interface FileChange { path: string; kind: "add" | "delete" | "update"; }

// Token 用量
interface TokenUsage { inputTokens: number; outputTokens: number; cachedInputTokens?: number; }

// 加密会话
interface E2ESession { sessionKey: Buffer; }

// 加密消息
interface EncryptedMessage { v: 1; nonce: string; ciphertext: string; tag: string; }
```

### 12.6 端口与常量

| 常量 | 值 | 位置 |
|------|-----|------|
| 默认 WebSocket 端口请求 | `0` (`auto`) | `local.ts` |
| Token 长度 | 32 hex chars (16 bytes) | `local.ts` |
| OTP 长度 | 6 hex chars (3 bytes) | `local.ts` |
| Relay 离线缓存上限 | 100 条 | `channel.ts` |
| Relay 消息过期时间 | 24 小时 | `channel.ts` |
| Relay 重连最大次数 | 10 次 | `relay.ts` |
| Relay 重连基础延迟 | 3000 ms | `relay.ts` |
| HKDF info 字符串 | `"codepilot-e2e-v1"` | `crypto.ts` |
