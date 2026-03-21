# Agent Integration Guide

This guide shows how an agent framework, copilot, or workflow engine can use `ton-zig-agent-kit` as a TON runtime.

## Integration Model

The runtime is exposed through CLI tool mode:

```bash
ton-zig-agent-kit tool <action> '<json_payload>'
```

This makes it easy to wrap from:

- Python agents
- TypeScript copilots
- workflow engines
- bots
- autonomous planners

## Runtime Handshake

Use `capabilities` as the runtime handshake.

```bash
ton-zig-agent-kit tool capabilities
```

This returns:

- supported actions
- workflow coverage
- response style
- execution model
- safety primitives
- integration targets
- examples

A framework can call this first to discover how to interact with the runtime.

## Common Agent Loop

A minimal agent loop looks like this:

1. `capabilities`
2. `wallet-state`
3. `inspect-contract`
4. choose next tool
5. `analyze-transfer` or `analyze-contract-call`
6. optionally `watch-payment`

## Example: Planner-driven transfer flow

### Step 1: discover runtime

```bash
ton-zig-agent-kit tool capabilities
```

### Step 2: inspect wallet readiness

```bash
ton-zig-agent-kit tool wallet-state
```

### Step 3: analyze before acting

```bash
ton-zig-agent-kit tool analyze-transfer '{
  "destination":"0:...",
  "amount":10000000,
  "comment":"demo"
}'
```

### Step 4: read result fields

The planner should inspect:

- `success`
- `executable`
- `recommended_action`
- `risk_flags`
- `state_init_attached_if_execute`

## Example: Contract discovery flow

```bash
ton-zig-agent-kit tool inspect-contract '{"address":"0:..."}'
ton-zig-agent-kit tool recent-activity '{"address":"0:...","limit":5}'
```

The planner should inspect:

- `agent_hints`
- `risk_flags`
- `recommended_actions`
- `semantic_tag`
- `recommended_followup`

## Example: Payment-triggered workflow flow

```bash
ton-zig-agent-kit tool watch-payment '{
  "wallet_address":"0:...",
  "comment":"order-123",
  "timeout_ms":10000,
  "workflow_name":"grant_access",
  "correlation_id":"order-123",
  "trigger_payload":"{\"order_id\":\"123\"}"
}'
```

A workflow engine should inspect:

- `trigger_ready`
- `trigger_id`
- `workflow_name`
- `correlation_id`
- `trigger_payload`

## Response Contract

The runtime uses structured JSON responses.

This is intended for machine consumption, not only human display.

Common fields include:

- `success`
- `risk_flags`
- `recommended_action`
- `recommended_followup`
- `items`
- `details`

## Safety Model

The runtime is designed around an analyze-first approach.

Use these before execution:

- `wallet-state`
- `inspect-contract`
- `analyze-transfer`
- `analyze-contract-call`

This helps agent systems avoid blind chain interactions.

## Best Practice

Treat `ton-zig-agent-kit` as:

- a context layer
- a safety layer
- a workflow trigger layer

not only as a raw transaction utility.
