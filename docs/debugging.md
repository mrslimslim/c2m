# CTunnel 启动与调试指南

> 面向开发者的 Rust 运行时本地验证手册
>
> 上线前请先看：`docs/release-preflight-checklist.md`
>
> 对外产品名与默认 CLI 命令为 `CTunnel` / `ctunnel`；内部 crates 仍保留 `codepilot-*` 命名。

---

## 目录

1. [环境准备](#1-环境准备)
2. [常用命令](#2-常用命令)
3. [Bridge 调试](#3-bridge-调试)
4. [Relay 本地调试](#4-relay-本地调试)
5. [核心 Smoke Checks](#5-核心-smoke-checks)
6. [常见问题排查](#6-常见问题排查)

---

## 1. 环境准备

### 1.1 必需

| 依赖 | 版本 | 说明 |
|------|------|------|
| Rust | stable | 默认构建、测试和桥接运行时 |
| Cargo | 随 Rust 安装 | 负责 workspace 构建和测试 |
| Swift | Xcode 自带 | 构建和验证 iOS 客户端 |
| Xcode | 最新稳定版 | 运行 simulator build |

### 1.2 推荐安装

```bash
rustup toolchain install stable
rustup target add wasm32-unknown-unknown
```

### 1.3 可选依赖

| 依赖 | 安装方式 | 说明 |
|------|----------|------|
| Codex CLI | 按你的常用方式安装 | 验证 Codex adapter 时使用 |
| Claude Code CLI | 按你的常用方式安装 | 验证 Claude adapter 时使用 |
| Wrangler | 官方 CLI | 仅在部署或本地调试 relay 时使用 |

### 1.4 Codex 登录态

```bash
codex login
codex login status
```

---

## 2. 常用命令

根脚本已经切换到 Rust-first：

| 命令 | 作用 |
|------|------|
| `cargo build --workspace` | 构建整个 Cargo workspace |
| `cargo test --workspace` | 跑完整 Rust 测试套件 |
| `cargo test -p codepilot-bridge` | 只跑 Bridge crate 测试 |
| `cargo test -p codepilot-relay-worker` | 只跑 Relay Worker crate 测试 |
| `cargo test -p codepilot-agents` | 只跑 agent adapter 测试 |
| `cargo run -p codepilot-bridge -- --help` | 查看当前 Rust Bridge CLI 参数面 |
| `cargo run -p codepilot-bridge -- --agent codex --dir ~/my-project` | 以 Codex 模式启动 Rust Bridge |
| `cargo run -p codepilot-bridge -- --agent codex --tunnel --dir ~/my-project` | 以 Codex 模式启动 Rust Bridge，并附加 Cloudflare Tunnel |
| `ctunnel` | 以默认 `codex + tunnel` 配置启动 Bridge，工作目录默认为执行命令时的当前目录 |
| `ctunnel preflight` | 运行上线前自动化自检 |
| `ctunnel relay deploy` | 部署 Cloudflare Relay Worker |
| `cd crates/codepilot-relay-worker && wrangler dev` | 在 Relay crate 目录下启动本地 Worker |

如需直接使用底层命令，可参考：

```bash
cargo build --workspace
cargo build -p codepilot-relay-worker --target wasm32-unknown-unknown
cargo test --workspace
cargo run -p codepilot-bridge -- --help
cd crates/codepilot-relay-worker && wrangler dev
```

---

## 3. Bridge 调试

### 3.1 查看 CLI 参数面

```bash
cargo run -p codepilot-bridge -- --help
```

当前 Rust Bridge CLI 暴露的参数：

```text
--agent <AGENT>   默认 auto
--dir <DIR>       默认当前目录
--tunnel          启用 tunnel 模式
```

### 3.2 重点验证方式

当前 cutover 阶段，Bridge 的核心行为以 crate tests 为主验证手段：

```bash
# Bridge 路由、diff、slash、session replay、CLI 解析
cargo test -p codepilot-bridge

# 路径安全、pairing、event log、slash catalog
cargo test -p codepilot-core

# Codex / Claude 事件映射
cargo test -p codepilot-agents
```

这比依赖旧的 Node 启动链更直接，也更适合在 Rust 重写过程中做回归验证。

### 3.3 手动运行 Bridge 二进制

```bash
cargo run -p codepilot-bridge -- --agent codex --dir .
```

如果你需要公网可达的 pairing payload，可直接运行：

```bash
cargo run -p codepilot-bridge -- --agent codex --tunnel --dir .
```

如果你只是想确认当前 Rust CLI 是否可运行，优先用 `cargo run -p codepilot-bridge -- --help`。如果你要验证更深的 Bridge 行为，优先跑 `codepilot-bridge` 与 `codepilot-core` 的测试。

---

## 4. Relay 本地调试

### 4.1 本地启动

```bash
cd crates/codepilot-relay-worker
wrangler dev
```

默认配置文件位于：

```text
crates/codepilot-relay-worker/wrangler.toml
```

### 4.2 单独构建 Worker

```bash
cargo build -p codepilot-relay-worker --target wasm32-unknown-unknown
```

### 4.3 核对 Relay 路由

Rust Relay 目前有两个关键入口：

- `GET /health` 返回 `{ "status": "ok", "service": "codepilot-relay" }`
- `GET /ws?device=bridge|phone&channel=<id>` 升级到 Durable Object channel

建议先跑：

```bash
cargo test -p codepilot-relay-worker
```

然后再用 `wrangler dev` 做本地 Worker smoke check。

### 4.4 部署到 Cloudflare

```bash
ctunnel relay deploy
```

或手动执行：

```bash
cd crates/codepilot-relay-worker
wrangler deploy
```

---

## 5. 核心 Smoke Checks

Task 9 cutover 完成后，最有价值的回归检查是下面这组命令：

```bash
cargo build -p codepilot-bridge
cargo build -p codepilot-relay-worker --target wasm32-unknown-unknown
cargo test -p codepilot-core
cargo test -p codepilot-agents
cargo test -p codepilot-bridge
cargo test -p codepilot-relay-worker
```

如果你只想做一次根级自检：

```bash
cargo test --workspace
```

---

## 6. 常见问题排查

### Q: `cargo: command not found`

**原因**：Rust toolchain 未安装，或 `cargo` 不在 PATH 中。
**解决**：

```bash
rustup toolchain install stable
rustup default stable
```

### Q: `can't find crate for core` 或 wasm32 目标报错

**原因**：没有安装 `wasm32-unknown-unknown` target。
**解决**：

```bash
rustup target add wasm32-unknown-unknown
```

### Q: `wrangler dev` 失败

**原因**：当前环境没有可用的 Wrangler CLI，或 Cloudflare 登录态失效。
**解决**：

```bash
wrangler --version
wrangler whoami
```

### Q: `codex` 或 `claude` 不在 PATH 中

**原因**：对应 CLI 未安装。
**解决**：

```bash
which codex
which claude
```

按需安装后重新运行相关 adapter 测试。

### Q: Cargo 命令一直卡在 `Blocking waiting for file lock`

**原因**：另一个 Cargo 进程正在使用同一个 artifact 或 package cache。
**解决**：等待现有任务结束，或终止重复的 Cargo 命令后重试。
