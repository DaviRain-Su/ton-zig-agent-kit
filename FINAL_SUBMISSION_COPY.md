# Final Submission Copy

This file contains copy-ready text for hackathon submission forms and local reference.

## English

### Project Name

`ton-zig-agent-kit`

### One-line Summary

A TON-native runtime for agent context, execution planning, and payment-triggered workflows.

### Short Description

`ton-zig-agent-kit` is a Zig-built TON agent runtime that gives AI systems structured wallet context, contract intelligence, semantic activity summaries, safe preflight execution analysis, and payment-triggered workflow primitives through machine-readable JSON tool actions.

### Why It Fits Agent Infrastructure

This project is designed as infrastructure for AI agents rather than as a human-only blockchain CLI. It exposes a machine-readable runtime surface through `capabilities`, `runtime-spec`, and structured tool actions. Agents can discover available actions, inspect wallets and contracts, analyze transfers and contract calls before execution, understand recent activity semantically, and use TON payments as workflow triggers.

### Key Highlights

- Structured runtime handshake and formal action contract via `capabilities` and `runtime-spec`
- Analyze-first execution model with risk flags, recommended actions, and deployment-aware planning
- Payment-confirmed workflow triggers with trigger payloads, workflow name, and correlation metadata

### Core Tool Actions

- `capabilities`
- `runtime-spec`
- `demo-manifest`
- `wallet-state`
- `inspect-contract`
- `recent-activity`
- `portfolio`
- `analyze-transfer`
- `analyze-contract-call`
- `watch-payment`

### Validation

Validated locally with:

```bash
zig build
zig test src/root.zig
```

Result:

- build passes
- **245 passed**
- **7 skipped**
- **0 failed**

## 中文

### 项目名称

`ton-zig-agent-kit`

### 一句话简介

一个面向 AI agent 的 TON 原生 runtime，提供上下文感知、执行规划与支付触发工作流能力。

### 项目简介

`ton-zig-agent-kit` 是一个用 Zig 构建的 TON agent runtime，通过结构化 JSON tool actions，为 AI 系统提供钱包上下文、合约智能分析、账户活动语义摘要、安全的执行前分析，以及基于 TON 支付确认的工作流触发原语。

### 为什么属于 Agent Infrastructure 赛道

这个项目的目标不是做一个只给人类手工使用的区块链 CLI，而是为 AI agent 提供可发现、可组合、可机器消费的运行时能力。它通过 `capabilities`、`runtime-spec` 以及一组结构化工具动作，支持 agent 发现能力、检查钱包与合约状态、在执行前进行转账/合约调用分析、理解账户近期活动语义，并把 TON 支付作为下游工作流触发事件。

### 核心亮点

- 通过 `capabilities` 与 `runtime-spec` 提供 runtime handshake 和形式化 action contract
- 采用 analyze-first 执行模型，提供 risk flags、recommended actions 和 deployment-aware planning
- 支持 payment-confirmed workflow trigger，输出 trigger payload、workflow name 与 correlation metadata

### 核心工具动作

- `capabilities`
- `runtime-spec`
- `demo-manifest`
- `wallet-state`
- `inspect-contract`
- `recent-activity`
- `portfolio`
- `analyze-transfer`
- `analyze-contract-call`
- `watch-payment`

### 验证结果

本地验证命令：

```bash
zig build
zig test src/root.zig
```

结果：

- build 通过
- **245 passed**
- **7 skipped**
- **0 failed**
