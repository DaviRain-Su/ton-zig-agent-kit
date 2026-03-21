# Short Pitches

## English

### 50-word pitch

`ton-zig-agent-kit` is a TON-native runtime for AI agents. It provides structured wallet context, contract intelligence, semantic activity understanding, safe preflight execution analysis, and payment-triggered workflow primitives through machine-readable JSON tool actions.

### 100-word pitch

`ton-zig-agent-kit` is a Zig-built TON agent runtime designed for the Agent Infrastructure track. Instead of acting like a human-only blockchain CLI, it exposes a machine-readable runtime surface through `capabilities`, `runtime-spec`, and structured tool actions. Agents can inspect wallet readiness, detect contract interfaces, understand recent activity semantically, analyze transfers and contract calls before execution, and turn TON payments into workflow triggers. The project emphasizes an analyze-first model with risk flags, recommended actions, and deployment-aware planning, making TON easier to use as infrastructure for autonomous systems, copilots, workflow engines, and bot backends.

### 200-word pitch

`ton-zig-agent-kit` is a TON-native runtime for AI systems, built in Zig and designed for Agent Infrastructure. The project focuses on making TON usable by autonomous agents through structured, machine-readable tool actions rather than only through developer-centric blockchain primitives.

The runtime exposes three important manifest surfaces: `capabilities` for runtime handshake and discovery, `runtime-spec` for a formal action contract, and `demo-manifest` for a compact evaluation path. On top of that, it provides operational tools for wallet-state inspection, contract intelligence, semantic recent-activity summaries, portfolio context, transfer and contract-call preflight analysis, and payment-triggered workflow monitoring.

This design gives agents the information they need before acting: whether a wallet is deployed, whether state init is needed, what interfaces a contract exposes, what activity means semantically, and what risks or recommended next actions exist. It also turns TON payments into structured workflow triggers with correlation metadata.

The result is not just a TON CLI or SDK, but a reusable runtime layer for autonomous agents, copilots, workflow engines, and bot backends that need safe planning, structured context, and event-driven hooks on TON.

## 中文

### 50字版

`ton-zig-agent-kit` 是一个面向 AI agent 的 TON 原生 runtime，提供钱包上下文、合约智能、活动语义、安全执行前分析与支付触发工作流能力。

### 100字版

`ton-zig-agent-kit` 是一个用 Zig 构建的 TON agent runtime，面向 Agent Infrastructure 赛道。它不是只给人类手工使用的区块链 CLI，而是通过 `capabilities`、`runtime-spec` 和结构化 JSON tool actions，为 AI 系统提供钱包就绪状态、合约接口识别、账户活动语义理解、转账/合约调用执行前分析，以及基于 TON 支付确认的工作流触发能力。

### 200字版

`ton-zig-agent-kit` 是一个面向 AI 系统的 TON 原生 runtime，使用 Zig 构建，目标是让 TON 更容易被 autonomous agents、copilots、workflow engines 和 bot backends 作为基础设施能力接入。项目不是单纯提供链上原语或人类使用的 CLI，而是通过结构化、机器可读的 tool actions 暴露 runtime surface。

它提供 `capabilities` 作为 runtime handshake，`runtime-spec` 作为形式化 action contract，`demo-manifest` 作为高信号评估路径；并进一步提供钱包状态检查、合约智能分析、近期活动语义摘要、资产组合上下文、转账与合约调用的执行前分析，以及基于支付确认的 workflow trigger。

通过 analyze-first 模型，这个 runtime 能帮助 agent 在真正交互链上状态之前，先理解部署状态、seqno、state init 需求、风险标记和推荐动作。最终它形成的不是普通 TON SDK，而是一层面向 AI agent 的 TON runtime infrastructure。
