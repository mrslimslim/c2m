# CTunnel 技术文档

> Mobile Command Center for AI Coding Agents
>
> Version 0.1.0 | Rust runtime default

---

## 目录

1. [项目概览](#1-项目概览)
2. [Rust 工作区结构](#2-rust-工作区结构)
3. [运行时架构](#3-运行时架构)
4. [兼容性边界](#4-兼容性边界)
5. [构建与部署](#5-构建与部署)
6. [开发参考](#6-开发参考)

---

## 1. 项目概览

### 1.1 定位

CTunnel 是一个“手机远程控制 AI 编程代理”的系统。手机端发送自然语言指令，Bridge 负责维护会话、路由命令、保存事件日志，并把代理事件流回传到手机；公网访问默认通过 Cloudflare Tunnel 暴露当前 Bridge。

### 1.2 当前默认运行时

项目现在以 **Rust Cargo workspace** 作为默认实现：

- `crates/codepilot-protocol` 负责手机协议、事件和消息线格式
- `crates/codepilot-core` 负责配对加密、事件持久化、diff、slash catalog、安全校验和通用日志
- `crates/codepilot-agents` 负责 Codex / Claude 适配器
- `crates/codepilot-bridge` 负责 Bridge 编排和 CLI 入口
- `crates/codepilot-relay-worker` 负责 Cloudflare Workers Relay

### 1.3 核心能力

| 能力 | 说明 |
|------|------|
| 多代理支持 | Codex 与 Claude 适配器统一映射到 `AgentAdapter` trait |
| 会话回放 | 事件持久化到 JSONL 日志，支持 alias 解析与增量重放 |
| 公网接入 | Bridge 可选启动 Cloudflare Tunnel，对外暴露当前本地 WebSocket 服务 |
| E2E 加密 | X25519 + HKDF + AES-256-GCM，Relay 无法解密消息 |
| 路径安全 | 文件请求经过工作目录沙箱和敏感文件黑名单校验 |
| Slash catalog | 由 Bridge 按适配器版本生成元数据，客户端只负责渲染 |

### 1.4 技术栈

- **Runtime**: Rust stable, Cargo workspace
- **序列化**: `serde`, `serde_json`
- **加密**: `x25519-dalek`, `hkdf`, `aes-gcm`, `sha2`
- **CLI**: `clap`
- **Relay**: `workers-rs`, Cloudflare Workers, Durable Objects
- **Node.js**: 仅用于 `npx wrangler` 与根级脚本包装

---

## 2. Rust 工作区结构

工作区根清单位于 `Cargo.toml`：

```text
crates/
├── codepilot-protocol
├── codepilot-core
├── codepilot-agents
├── codepilot-bridge
└── codepilot-relay-worker
```

### 2.1 Crate 边界

| Crate | 角色 | 关键文件 |
|------|------|------|
| `codepilot-protocol` | 协议模型与 JSON 线格式 | `src/messages.rs`, `src/events.rs`, `src/state.rs` |
| `codepilot-core` | 共享运行时能力 | `src/pairing/crypto.rs`, `src/session_store/event_log.rs`, `src/security.rs`, `src/slash/catalog.rs` |
| `codepilot-agents` | 代理适配层 | `src/types.rs`, `src/codex.rs`, `src/claude.rs` |
| `codepilot-bridge` | Bridge 编排与 CLI | `src/bridge.rs`, `src/lib.rs`, `src/main.rs` |
| `codepilot-relay-worker` | Cloudflare Relay Worker | `src/lib.rs`, `wrangler.toml` |

### 2.2 依赖方向

```text
codepilot-protocol
        ▲
        │
 codepilot-core
        ▲
        │
codepilot-agents      codepilot-relay-worker
        ▲
        │
 codepilot-bridge
```

这样拆分后，协议兼容层、加密/存储层、代理层、Bridge 层和 Relay 层可以分别测试，同时仍然遵循原始 TypeScript 实现的依赖顺序。

---

## 3. 运行时架构

### 3.1 整体拓扑

```text
┌──────────┐   JSON / E2E    ┌──────────────┐   SDK / CLI    ┌───────────┐
│  Phone   │◄───────────────►│    Bridge    │◄──────────────►│ AI Agent  │
│   App    │                 │   (Rust)     │                │ Codex /   │
└──────────┘                 └──────────────┘                │ Claude    │
      │                               │                      └───────────┘
      │           optional            │
      ├────────────► Cloudflare Tunnel
      │
      └────────────► Relay Worker
                     (Workers DO)
```

### 3.2 `codepilot-protocol`

协议 crate 保持手机端线格式稳定，覆盖以下核心模型：

- `PhoneMessage` 与 `BridgeMessage`
- `AgentEvent` 与 `SessionInfo`
- `EncryptedWireMessage`
- diff、slash catalog、session replay 相关负载

JSON round-trip 测试负责校验 Rust 序列化后的字段名、tag 和可选字段行为与旧协议保持一致。

### 3.3 `codepilot-core`

Core crate 承载和运行时兼容性直接相关的逻辑：

- `pairing/crypto.rs`: X25519、HKDF、AES-GCM 兼容实现
- `pairing/state.rs`: `~/.codepilot/pairing/<hash>.json` 读写兼容
- `session_store/event_log.rs`: 追加写 JSONL、event id、session alias 解析
- `diff/*`: diff 解析、截断、分页
- `slash/*`: slash catalog 构建与 bridge-side action dispatch
- `security.rs`: 文件请求路径沙箱和敏感路径过滤
- `logger.rs`, `tunnel.rs`: Bridge 侧通用支撑能力

### 3.4 `codepilot-agents`

适配层通过统一 trait 屏蔽不同代理实现差异：

- `types.rs` 定义 `AgentAdapter`、`SessionOptions` 和错误模型
- `codex.rs` 负责把 Codex CLI/流式事件映射为统一 `AgentEvent`
- `claude.rs` 负责把 Claude CLI 的 stream-json 事件映射为统一 `AgentEvent`

Bridge 只依赖 trait，不依赖具体代理实现细节。

### 3.5 `codepilot-bridge`

Bridge crate 当前负责：

- 接收手机消息并路由到 agent adapter
- 维护 `SessionInfo`、session alias 与连接客户端
- 持久化事件并支持 `sync_session`
- 处理 diff 请求、slash action 和文件读取请求
- 启动本地 WebSocket 服务，并在需要时附加 Cloudflare Tunnel
- 对外暴露 `CliArgs` 作为默认 Rust 启动入口

当前 CLI 参数面保持精简：`--agent`、`--dir`、`--tunnel`。更细的路由、回放、slash、diff 和安全行为通过 crate 集成测试验证，而不是依赖旧的 Node CLI。

### 3.6 `codepilot-relay-worker`

Relay Worker 仍然遵循原始 Cloudflare 模型，但实现迁移到了 Rust Worker crate：

- `GET /health` 返回健康检查 JSON
- `GET /ws?device=bridge|phone&channel=<id>` 升级到同一个 channel
- Durable Object `Channel` 负责 socket 管理、离线缓存和 peer 状态通知

Relay 保持“只转发密文、不解密消息”的零知识设计。当前默认 Bridge 启动路径优先使用本地 WebSocket 加 `--tunnel` 的公网暴露模式；Relay Worker crate 保留为独立构建与部署目标。

---

## 4. 兼容性边界

Rust 重写期间需要维持以下稳定边界：

- **协议兼容**：手机与 Bridge 之间的 JSON 负载保持原字段与 tag 语义
- **配对兼容**：pairing state 文件路径、OTP 绑定和共享密钥派生结果稳定
- **回放兼容**：事件日志格式、event id、resolved session alias 行为不变
- **Slash 兼容**：catalog 由 Bridge 生成，客户端只消费元数据
- **Relay 兼容**：Relay 仍然是 Cloudflare Workers Durable Objects，并继续转发密文

这些边界由 `codepilot-protocol`、`codepilot-core`、`codepilot-bridge` 和 `codepilot-relay-worker` 的测试套件共同守护。

---

## 5. 构建与部署

### 5.1 根命令

项目根 `package.json` 现在默认包装 Rust 运行时命令：

```bash
# 全量构建
pnpm run build

# 全量测试
pnpm run test

# Bridge crate
pnpm run build:bridge
pnpm run bridge:help

# Relay Worker
pnpm run build:relay
pnpm run relay:dev
pnpm run relay:deploy
```

对应的底层命令分别是 Cargo 与 Wrangler：

```bash
cargo build --workspace
cargo build -p codepilot-relay-worker --target wasm32-unknown-unknown
cargo test --workspace
cd crates/codepilot-relay-worker && npx wrangler dev
```

### 5.2 Bridge 入口

Bridge 的默认 Rust 入口是：

```bash
cargo run -p codepilot-bridge -- --help
```

常见启动方式：

```bash
cargo run -p codepilot-bridge -- --agent codex --dir .
cargo run -p codepilot-bridge -- --agent codex --tunnel --dir .
```

消息路由、session replay、slash catalog、diff 加载和安全校验以集成测试作为主验证手段。

### 5.3 Relay 部署

Relay 配置位于：

```text
crates/codepilot-relay-worker/wrangler.toml
```

本地调试与部署：

```bash
cd crates/codepilot-relay-worker
npx wrangler dev
npx wrangler deploy
```

---

## 6. 开发参考

### 6.1 常用验证命令

```bash
# 协议 JSON 兼容
cargo test -p codepilot-protocol

# 核心兼容层
cargo test -p codepilot-core

# 代理映射
cargo test -p codepilot-agents

# Bridge 路由与 CLI
cargo test -p codepilot-bridge

# Relay 路由与 channel 行为
cargo test -p codepilot-relay-worker
```

### 6.2 扩展新的 Agent Adapter

1. 在 `crates/codepilot-agents/src/` 下新增实现文件
2. 在 `src/types.rs` 中补齐 trait 约束与选项结构
3. 在 `crates/codepilot-bridge/src/bridge.rs` 中接入 adapter 选择与事件路由
4. 在 `crates/codepilot-agents/tests/` 添加事件映射测试

### 6.3 扩展协议消息

1. 在 `crates/codepilot-protocol/src/messages.rs` 或相关模块中新增模型
2. 在 `crates/codepilot-protocol/tests/` 增加 JSON 兼容 fixture
3. 在 `crates/codepilot-bridge/src/bridge.rs` 中添加消费逻辑
4. 如需持久化，补充 `codepilot-core` 事件日志或 diff/service 测试

### 6.4 扩展 Relay

1. 修改 `crates/codepilot-relay-worker/src/lib.rs`
2. 为路由或 channel 逻辑补充 crate tests
3. 重新运行 `pnpm run build:relay`
4. 通过 `pnpm run relay:dev` 做本地 Worker smoke check
