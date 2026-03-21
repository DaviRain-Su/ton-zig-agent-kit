# Judge Walkthrough

This is a short walkthrough for presenting `ton-zig-agent-kit` in the Agent Infrastructure track.

## Goal

Help a judge understand in 2-3 minutes why this is infrastructure for AI agents.

## Step 1: Show runtime discovery

```bash
ton-zig-agent-kit tool capabilities
```

### What to say

- This acts as the runtime handshake.
- It tells an agent what actions exist, how responses are structured, and what safety/event primitives are available.

### What this proves

- runtime discovery
- capability negotiation
- agent integration surface

## Step 2: Show wallet execution context

```bash
ton-zig-agent-kit tool wallet-state
```

### What to say

- Agents need to know whether the wallet is deployed, what seqno it has, and whether first-send state init is needed.

### What this proves

- deployment-aware planning
- wallet readiness context

## Step 3: Show contract intelligence

```bash
ton-zig-agent-kit tool inspect-contract '{"address":"0:..."}'
```

### What to say

- This is not just metadata. The runtime detects interfaces, emits risk flags, and recommends next actions for the agent.

### What this proves

- contract intelligence layer
- next-step reasoning support

## Step 4: Show semantic activity understanding

```bash
ton-zig-agent-kit tool recent-activity '{"address":"0:...","limit":5}'
```

### What to say

- The runtime summarizes transactions semantically and suggests followups, so agents do not need to interpret raw TON activity themselves.

### What this proves

- semantic context layer
- followup recommendation layer

## Step 5: Show safe planning before execution

```bash
ton-zig-agent-kit tool analyze-transfer '{"destination":"0:...","amount":10000000,"comment":"demo"}'
```

### What to say

- Agents should not send blind transactions. This runtime provides analyze-first planning, executability checks, and risk flags.

### What this proves

- safety model
- preflight execution planning

## Step 6: Show payment-triggered automation

```bash
ton-zig-agent-kit tool watch-payment '{
  "wallet_address":"0:...",
  "comment":"order-123",
  "timeout_ms":10000,
  "workflow_name":"grant_access",
  "correlation_id":"order-123"
}'
```

### What to say

- A TON payment becomes a machine-readable workflow trigger with correlation metadata for downstream systems.

### What this proves

- event primitive
- workflow handoff primitive
- agent automation hook

## Closing line

`ton-zig-agent-kit` is a TON-native runtime for agents: it provides context, planning, safety, and event-triggered workflows through structured JSON tool actions.
