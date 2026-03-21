# Agent Runtime Demo

This is a suggested demo script for presenting `ton-zig-agent-kit` as an Agent Infrastructure submission.

## Goal

Show that the project provides a TON-native runtime for agents, with:

- capability discovery
- wallet context
- contract intelligence
- semantic activity understanding
- safe pre-execution analysis
- payment-triggered workflows

## Demo Flow

### 1. Show runtime manifest

```bash
ton-zig-agent-kit tool capabilities
```

Point out:

- structured JSON output
- supported workflows
- supported actions
- environment variables
- examples
- risk model

### 2. Show wallet runtime context

```bash
ton-zig-agent-kit tool wallet-state
```

Point out:

- deployed vs undeployed detection
- seqno
- wallet version
- state-init planning for first send

### 3. Show contract intelligence

```bash
ton-zig-agent-kit tool inspect-contract '{"address":"0:..."}'
```

Point out:

- wallet / jetton / nft / abi detection
- risk flags
- agent hints
- recommended actions with example payloads

### 4. Show semantic account activity

```bash
ton-zig-agent-kit tool recent-activity '{"address":"0:...","limit":5}'
```

Point out:

- semantic tags
- comments
- opcode names
- contract message understanding

### 5. Show safe transfer planning

```bash
ton-zig-agent-kit tool analyze-transfer '{"destination":"0:...","amount":10000000,"comment":"demo"}'
```

Point out:

- preflight execution analysis
- executable vs non-executable
- deployment context
- risk flags

### 6. Show payment-triggered workflow readiness

```bash
ton-zig-agent-kit tool watch-payment '{
  "wallet_address":"0:...",
  "comment":"order-123",
  "timeout_ms":10000,
  "workflow_name":"grant_access",
  "correlation_id":"order-123",
  "trigger_payload":"{\"workflow\":\"grant_access\",\"order_id\":\"123\"}"
}'
```

Point out:

- payment becomes an agent trigger
- trigger payload contains on-chain context
- workflow metadata includes `workflow_name` and `correlation_id`
- downstream workflow can be started automatically

## One-Line Pitch

`ton-zig-agent-kit` is a TON-native agent runtime in Zig that gives AI systems structured on-chain context, preflight execution analysis, and payment-triggered workflows.
