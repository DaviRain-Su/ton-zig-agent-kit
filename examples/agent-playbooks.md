# Agent Playbooks

These playbooks show how an agent or workflow engine can use `ton-zig-agent-kit` as TON infrastructure.

## 1. Wallet Readiness Playbook

Goal: determine whether an agent wallet is ready to act.

### Steps

1. `wallet-state`
2. inspect:
   - deployed
   - seqno
   - state_init_required_for_first_send
3. if undeployed, route first action through deployment-aware flow

### Example

```bash
ton-zig-agent-kit tool wallet-state
```

## 2. Contract Discovery Playbook

Goal: understand what a TON contract is and what the agent should do next.

### Steps

1. `inspect-contract`
2. read:
   - interfaces
   - agent_hints
   - risk_flags
   - recommended_actions
3. `recent-activity`
4. use `recommended_followup` from recent activity items

### Example

```bash
ton-zig-agent-kit tool inspect-contract '{"address":"0:..."}'
ton-zig-agent-kit tool recent-activity '{"address":"0:...","limit":5}'
```

## 3. Safe Transfer Playbook

Goal: plan before a transfer is executed.

### Steps

1. `wallet-state`
2. `analyze-transfer`
3. inspect:
   - executable
   - recommended_action
   - risk_flags
   - state_init_attached_if_execute
4. only then proceed to execution flow

### Example

```bash
ton-zig-agent-kit tool analyze-transfer '{"destination":"0:...","amount":10000000,"comment":"demo"}'
```

## 4. Contract Call Planning Playbook

Goal: plan a contract interaction safely.

### Steps

1. `inspect-contract`
2. `analyze-contract-call`
3. inspect:
   - selector
   - executable
   - recommended_action
   - risk_flags
4. if needed, select ABI mode or standard mode explicitly

### Example

```bash
ton-zig-agent-kit tool analyze-contract-call '{"mode":"auto","destination":"0:...","function":"transfer","amount":10000000,"args":["0:...",1]}'
```

## 5. Payment Unlock Workflow Playbook

Goal: turn an on-chain TON payment into a downstream workflow trigger.

### Steps

1. `watch-payment`
2. wait for `trigger_ready = true`
3. consume:
   - trigger payload
   - trigger id
   - workflow name
   - correlation id
4. hand off to workflow engine or bot backend

### Example

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

## 6. Portfolio + Activity Review Playbook

Goal: combine balances and behavior before making an agent decision.

### Steps

1. `portfolio`
2. `recent-activity`
3. inspect semantic tags and followups
4. decide whether to inspect a contract, wait, or plan a transfer

### Example

```bash
ton-zig-agent-kit tool portfolio '{"address":"0:...","jetton_masters":["0:..."]}'
ton-zig-agent-kit tool recent-activity '{"address":"0:...","limit":5}'
```
