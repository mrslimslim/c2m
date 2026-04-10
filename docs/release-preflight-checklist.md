# CTunnel 上线前自检清单

> 面向 `Bridge + Codex + Cloudflare Tunnel + iOS` 的发布门禁清单

---

## 适用范围

- 默认命令执行目录：`/Users/mrslimslim/dev/c2m`
- 本次核心上线路径：`cargo run -p codepilot-bridge -- --agent codex --tunnel --dir /Users/mrslimslim/.openclaw`
- 本清单默认只把 `codex` 路径视为阻断项，不把 `claude` 作为本轮上线门禁
- 本清单默认把 `Relay Worker` 视为可选附录；只有本轮也要发布 relay 时才执行附录中的步骤
- 完整 iOS 人工回归矩阵见 `docs/ios-testing.md`；本清单只保留上线前必须逐项通过的门禁
- 已封装命令：
  - `ctunnel`
  - `ctunnel preflight`
  - `ctunnel relay deploy`
  - `ctunnel --help`

---

## 1. 发布目标与阻断条件

以下项目全部通过，才能判定本轮可以上线：

- [ ] 环境前置检查通过，关键工具、Codex 登录态和 tunnel 依赖可用
- [ ] Rust 核心构建与测试通过
- [ ] iOS Swift package tests 通过
- [ ] iOS app simulator build 通过
- [ ] `cargo run -p codepilot-bridge -- --agent codex --tunnel --dir /Users/mrslimslim/.openclaw` 可以稳定启动
- [ ] Bridge 终端能输出二维码、pairing payload 和有效的 tunnel URL
- [ ] iPhone 真机能通过 tunnel 路径完成配对、建会话、继续会话、取消 busy turn、请求文件、查看 diff、重启后恢复连接
- [ ] Diagnostics 中不泄露 `token`、`otp`、ciphertext 等敏感值

以下项目默认不是阻断项：

- [ ] `claude` CLI 可用性
- [ ] `Relay Worker` 部署与公网健康检查
- [ ] App Store 提审、隐私问卷、归档上传等商店流程

只要任一阻断项失败，本轮停止上线。

---

## 2. 环境前置

先确认当前终端就在仓库根目录：

```bash
pwd
```

预期结果：

- 输出 `/Users/mrslimslim/dev/c2m`

逐项检查本轮上线所需依赖：

```bash
cargo --version
swift --version
xcodebuild -version
codex --version
codex login status
cloudflared --version
rustup target list --installed | grep wasm32-unknown-unknown
```

预期结果：

- `cargo`、`swift`、`xcodebuild`、`codex`、`cloudflared` 都能正常返回版本
- `codex login status` 成功返回已登录状态

失败时先看：

- `cloudflared` 不存在：安装后再执行 tunnel 路径
  - `brew install cloudflared`
- `codex` 不存在或版本异常：修复 CLI 安装与登录态
- `codex login status` 失败：先执行 `codex login`
- `wasm32-unknown-unknown` 缺失：执行 `rustup target add wasm32-unknown-unknown`

如果这轮也要发布 `Relay Worker`，再补一项 Cloudflare 登录态检查：

```bash
wrangler whoami
rustup target list --installed | grep wasm32-unknown-unknown
```

预期结果：

- 能返回当前 Cloudflare 账号信息，而不是要求重新登录
- 已安装 `wasm32-unknown-unknown`

也可以直接执行封装命令：

```bash
ctunnel preflight
```

如果这轮也要附带 relay 验证：

```bash
ctunnel preflight --with-relay
```

---

## 3. 静态自检

先跑一遍根级快速检查：

```bash
cargo test --workspace
```

说明：

- 这一步适合快速发现 Rust 侧的大面问题
- 它不能替代下面的 iOS build 门禁

然后按阻断项逐条执行：

```bash
cargo build --workspace
cargo test -p codepilot-core
cargo test -p codepilot-agents
cargo test -p codepilot-bridge
swift test --package-path packages/ios/CodePilotKit
xcodebuild -project packages/ios/CodePilotApp/CodePilot.xcodeproj -scheme CTunnel -destination 'generic/platform=iOS Simulator' build
```

预期结果：

- 所有命令退出码为 `0`
- `cargo test -p codepilot-agents` 覆盖 Codex adapter 映射链路
- `cargo test -p codepilot-bridge` 覆盖 bridge 路由、diff、session replay 和 CLI 行为
- `swift test --package-path packages/ios/CodePilotKit` 通过
- `xcodebuild ... build` 成功产出 simulator build

失败时先看：

- 如果 Rust tests 失败，先按失败 crate 分类处理，不要继续做真机联调
- 如果 `swift test` 失败，优先看协议模型、连接控制和 session 相关测试
- 如果 `xcodebuild` 失败，先处理编译或签名问题，再进入手工配对

如果这轮也要发布 relay，再补充执行：

```bash
cargo test -p codepilot-relay-worker
cargo build -p codepilot-relay-worker --target wasm32-unknown-unknown
```

---

## 4. 核心冒烟

保持一个专门的终端窗口运行 bridge，不要在验证完成前关闭它：

```bash
cargo run -p codepilot-bridge -- --agent codex --tunnel --dir /Users/mrslimslim/.openclaw
```

等价封装命令：

```bash
ctunnel
```

### 4.1 启动输出

- [ ] 终端成功打印 `CTunnel Bridge v0.1.0`
- [ ] 终端打印 `Working directory: /Users/mrslimslim/.openclaw`
- [ ] 终端打印 `Agent: codex`
- [ ] 终端打印 `Tunnel URL: https://<something>.trycloudflare.com`
- [ ] 终端渲染二维码
- [ ] 终端打印 pairing payload，且包含 `host`、`port`、`bridge_pubkey`、`otp`
- [ ] tunnel 模式下 pairing payload 包含 `tunnel: true`

失败时先看：

- `cloudflared` 是否存在且可执行
- `codex --version` 是否正常
- `codex login status` 是否成功

### 4.2 真机配对

操作：

- [ ] 用 iPhone 打开最新本地包或 TestFlight 包
- [ ] 扫描 bridge 终端二维码
- [ ] 等待项目卡片从 connecting 进入 live
- [ ] 打开项目详情页并确认已连接

预期结果：

- 自动创建或复用保存的项目
- Diagnostics 能看到 connect attempt 和 connected 状态
- 不要求本地局域网可达；此轮以 tunnel 路径为准

失败时先看：

- 对比 bridge 终端 pairing payload 与 app Diagnostics
- 如果扫码成功但连不上，优先按 tunnel 传输问题排查，而不是先怀疑会话 UI

### 4.3 新建会话

操作：

- [ ] 在已连接项目中点击 `New Session`
- [ ] 输入一个稳定提示词，例如 `Summarize this repository layout`
- [ ] 发送后观察 timeline 流式返回

预期结果：

- 新 session 被创建
- 自动进入 session 详情页
- timeline 中能看到用户输入和 agent 返回

### 4.4 继续会话

操作：

- [ ] 在同一个 session 中发送追问
- [ ] 等待本轮响应完成

预期结果：

- 追问进入同一 session
- session 状态经历 busy 再回到 idle

### 4.5 取消 busy turn

操作：

- [ ] 发起一个会持续一会儿的命令
- [ ] 在 session 仍处于 busy 时点击停止按钮

预期结果：

- App 不崩溃
- session 能离开 busy 状态
- Diagnostics 不出现不可恢复的传输错误

### 4.6 文件请求

操作：

- [ ] 在会话中请求读取 `/Users/mrslimslim/.openclaw` 内一个已知可读文件
- [ ] 在客户端中打开返回的文件内容

建议：

- 优先选择稳定存在的文本文件，例如 `README.md`、配置文件或文档文件

预期结果：

- 文件请求成功返回
- 文件内容与实际磁盘内容一致
- 没有跨目录读到 `.openclaw` 之外的文件

### 4.7 Diff Viewer

操作：

- [ ] 在单独测试分支、临时文件或可安全回滚的改动上制造一次小型代码变更
- [ ] 等待 bridge 把代码改动事件推送到手机
- [ ] 在客户端点击改动并进入 diff viewer

预期结果：

- 代码改动以专用 diff viewer 打开，而不是整段 patch 直接塞进 timeline
- 首屏能看到首段 diff
- 需要时可以继续加载后续 diff 内容

### 4.8 重连恢复

操作：

- [ ] 保持 bridge 还在运行
- [ ] 完全退出 iOS app
- [ ] 重新打开 app 并进入刚才的项目

预期结果：

- 已保存项目仍然存在
- 重新进入后会自动尝试连接
- 在 pairing 材料不变的前提下可以恢复使用

### 4.9 Diagnostics 脱敏

操作：

- [ ] 打开 Diagnostics 页面
- [ ] 检查最近的连接与会话日志

预期结果：

- 不直接显示明文 `token`
- 不直接显示明文 `otp`
- 不直接显示完整 ciphertext

如果任何一项失败：

- 立即停止上线
- 保留 bridge 终端日志、iOS Diagnostics 截图和失败操作步骤

---

## 5. 可选 Relay 发布项

只有当本轮也要发布 relay 时才执行以下步骤：

```bash
ctunnel relay deploy
```

部署完成后做健康检查：

```bash
curl https://<your-worker-domain>/health
```

预期结果：

- 部署命令成功返回
- `/health` 返回：

```json
{"status":"ok","service":"codepilot-relay"}
```

如果还要做本地 smoke check，可补充：

```bash
cd crates/codepilot-relay-worker
wrangler dev
```

---

## 6. 失败处理

任一阻断项失败时，按下面的顺序处理：

1. 停止继续上线，不要带着部分通过状态往后推进。
2. 记录失败命令、退出码和失败时间。
3. 保存 bridge 终端输出，至少覆盖失败前后各 1 分钟。
4. 保存 iOS Diagnostics 页面截图和最小复现步骤。
5. 标记问题属于哪一类：
   - 构建失败
   - Rust tests 失败
   - iOS build 失败
   - tunnel 启动失败
   - pairing 失败
   - session / file / diff 行为失败
   - Diagnostics 脱敏失败
6. 修复后从失败项往前回归，不要只补跑单个命令就直接上线。

---

## 附注

- 本清单的目标是发布门禁，不是完整功能测试手册。
- 真机完整回归、LAN 场景、手动 payload 输入、多项目切换等补充场景，请继续参考 `docs/ios-testing.md`。
