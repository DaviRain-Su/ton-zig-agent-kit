# ton-zig-agent-kit

TON-native agent runtime and execution toolkit built in Zig.

Submission-ready copy is available in `FINAL_SUBMISSION_COPY.md`.
See also `SUBMISSION.md`, `DOCS_INDEX.md`, `JUDGE_COMMANDS.md`, and `FINAL_CHECKLIST.md`.

## Judge Quickstart

```bash
zig build
zig test src/root.zig
./zig-out/bin/ton-zig-agent-kit tool demo-manifest
./zig-out/bin/ton-zig-agent-kit tool capabilities
```

## Why Judges Should Care

This project turns TON into an agent-consumable runtime surface.
It gives AI systems structured wallet context, contract intelligence, semantic activity understanding, safe preflight planning, and payment-triggered workflow primitives.

That makes it infrastructure for agents, not just another blockchain CLI.

## Hackathon Positioning

**Track:** Agent Infrastructure

**Tagline:** TON-native runtime for agent context, execution planning, and payment-triggered workflows

**Submission Pitch:** A Zig-built TON agent runtime that gives autonomous systems structured wallet context, contract intelligence, safe preflight execution analysis, and payment-triggered workflow primitives.

`ton-zig-agent-kit` is no longer just a TON CLI/toolkit. It now exposes a structured, agent-friendly runtime for:

- wallet state introspection
- transfer and contract-call preflight analysis
- contract intelligence and interface detection
- portfolio and recent-activity context
- payment-triggered workflow execution

This makes it suitable as a TON execution layer for autonomous agents, copilots, bots, and orchestration frameworks.

## Project Structure for Judges

- `src/main.zig` — CLI and tool-mode entrypoint
- `src/tools/tools_mod.zig` — agent runtime implementation
- `src/tools/types.zig` — structured JSON-facing result types
- `src/paywatch/` — payment monitoring and verification
- `src/contract/` — contract, ABI, Jetton, and NFT helpers
- `README.md` — repo overview and quickstart
- `SUBMISSION.md` — submission-oriented summary
- `WHY_AGENT_INFRASTRUCTURE.md` — track-fit explanation
- `RUNTIME_GUARANTEES.md` — runtime behavior and safety guarantees
- `DOCS_INDEX.md` — documentation entrypoint
- `examples/` — demo, integration, playbooks, and judge walkthroughs

## Machine-readable Assets

- `capabilities` — runtime handshake
- `runtime-spec` — formal action contract
- `demo-manifest` — compact evaluation path
- `examples/action-schemas.json` — schema-shaped action examples

## For Agent Builders

If you are building an autonomous agent, copilot, or workflow backend, start with:

1. `capabilities` — runtime handshake and action discovery
2. `wallet-state` — wallet readiness and deployment context
3. `inspect-contract` — interface detection and recommended actions
4. `recent-activity` — semantic activity feed and followups
5. `analyze-transfer` / `analyze-contract-call` — safe planning before execution
6. `watch-payment` — payment-triggered workflow handoff

## What It Provides

### Agent runtime primitives

- `wallet-state`
- `analyze-transfer`
- `analyze-contract-call`
- `inspect-contract`
- `recent-activity`
- `portfolio`
- `watch-payment`
- `capabilities`

### TON-native execution support

- wallet v4 / v5 support
- seqno and deployment-state detection
- state-init attachment planning for first send
- ABI-aware contract call analysis
- standard TON message body analysis
- Jetton and NFT interface detection

### Payment-triggered automation

- watch TON payments by comment
- emit structured trigger payloads
- attach user workflow payloads
- recommend next action after payment confirmation

## Why This Fits Agent Infrastructure

The project acts like a TON-native runtime that an agent can query before acting.

Instead of only providing low-level chain operations, it returns structured JSON suitable for autonomous decision loops:

- what wallet is available
- whether a wallet is deployed
- whether a transfer is executable
- whether state init will be required
- what contract interfaces are present
- what actions are recommended next
- what recent activity means semantically
- whether a payment event should trigger a workflow

## Build

```bash
zig build
```

## Test

```bash
zig test src/root.zig
```

Current validated result during implementation:

- **245 passed**
- **7 skipped**
- **0 failed**

## Tool Mode

Structured JSON tool mode:

```bash
ton-zig-agent-kit tool <action> '<json_payload>'
```

Role of the core manifest actions:

- `capabilities` — runtime handshake and capability discovery
- `runtime-spec` — formal machine-readable action contract
- `demo-manifest` — compact evaluation flow for judges and automated review

How they fit together:

- `capabilities` tells an agent or reviewer what the runtime can do
- `runtime-spec` defines the action-level contract and behavior expectations
- `demo-manifest` provides the shortest high-signal evaluation path
- `examples/action-schemas.json` provides schema-shaped examples for automated consumers

### Supported actions

- `wallet-state`
- `analyze-transfer`
- `analyze-contract-call`
- `watch-payment`
- `inspect-contract`
- `capabilities`
- `recent-activity`
- `portfolio`
- `demo-manifest`

## Quick Examples

### 1. Wallet state

```bash
ton-zig-agent-kit tool wallet-state
```

Returns agent-relevant wallet context such as:

- address
- wallet version
- wallet id
- public key
- balance
- seqno
- deployed / undeployed
- whether state init is required for first send

### 2. Analyze a transfer before execution

```bash
ton-zig-agent-kit tool analyze-transfer '{
  "destination":"0:...",
  "amount":10000000,
  "comment":"demo"
}'
```

Returns structured preflight analysis such as:

- wallet address
- deployment status
- seqno
- estimated body kind
- executable flag
- recommended action
- risk flags

### 3. Analyze a contract call

#### Auto mode

```bash
ton-zig-agent-kit tool analyze-contract-call '{
  "mode":"auto",
  "destination":"0:...",
  "function":"transfer",
  "amount":10000000,
  "args":["0:...",123]
}'
```

#### ABI mode

```bash
ton-zig-agent-kit tool analyze-contract-call '{
  "mode":"abi",
  "destination":"0:...",
  "abi_source":"@abi.json",
  "function":"transfer",
  "amount":10000000,
  "args":["0:...",123]
}'
```

#### Standard mode

```bash
ton-zig-agent-kit tool analyze-contract-call '{
  "mode":"standard",
  "destination":"0:...",
  "kind":"jetton_transfer",
  "spec":"@spec.json",
  "amount":10000000
}'
```

Returns:

- selector
- body BOC
- wallet runtime context
- deployment planning
- executable flag
- recommended action
- risk flags

### 4. Inspect a contract for agent use

```bash
ton-zig-agent-kit tool inspect-contract '{
  "address":"0:..."
}'
```

Returns:

- wallet / jetton / nft / abi interface detection
- agent hints
- risk flags
- recommended actions
- detailed observed message intelligence

`recommended_actions` now includes example tool payloads so an agent or reviewer can see the next executable step immediately.

### 5. Read recent activity with semantic tags

```bash
ton-zig-agent-kit tool recent-activity '{
  "address":"0:...",
  "limit":5
}'
```

Returns activity summaries with fields such as:

- `opcode_name`
- `comment`
- `message_kind`
- `semantic_tag`
- `recommended_followup`

Example semantic tags:

- `user_comment`
- `jetton_operation`
- `nft_operation`
- `contract_message`
- `transfer`

Example followup recommendations:

- `inspect_transfer_source`
- `portfolio`
- `inspect_contract`
- `recent_activity`

### 6. Read portfolio context

```bash
ton-zig-agent-kit tool portfolio '{
  "address":"0:...",
  "jetton_masters":["0:..."]
}'
```

Returns:

- TON balance
- wallet state JSON
- discovered jetton wallet addresses
- jetton balances

### 7. Watch payments as workflow triggers

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

When payment is confirmed, the result can include:

- `trigger_ready: true`
- `matched_comment`
- `recommended_next_action: "trigger_agent_workflow"`
- `trigger_id`
- `workflow_name`
- `correlation_id`
- `trigger_payload`

The emitted trigger payload includes:

- `event = payment_confirmed`
- wallet address
- comment
- tx hash
- tx lt
- amount
- sender
- timestamp
- optional `user_payload`

This is the strongest infrastructure story in the project: TON payments can directly trigger downstream agent workflows.

### 8. Discover runtime capabilities

```bash
ton-zig-agent-kit tool capabilities
```

This action also serves as the runtime handshake for agent frameworks.

Returns a runtime manifest-like JSON document containing:

- supported wallets
- supported contract categories
- workflows
- actions
- environment variables
- examples
- risk model summary
- tagline and submission pitch
- demo flows and agent patterns

### 9. Show demo manifest

```bash
ton-zig-agent-kit tool demo-manifest
```

Returns a compact JSON step list optimized for hackathon demos and judge walkthroughs.

## Environment Variables

Common runtime env vars:

- `TON_RPC_URL`
- `TON_RPC_URLS`
- `TON_API_KEY`
- `TON_API_KEYS`
- `TON_NETWORK`
- `TON_PRIVATE_KEY_HEX`
- `TON_SEED`
- `TON_SEED_FILE`

## Architecture

```text
src/
├── core/        # cells, BoC, addresses, provider, body inspection
├── wallet/      # signing, wallet deployment and message construction
├── contract/    # generic contract, ABI adapter, Jetton, NFT helpers
├── paywatch/    # invoices, payment watcher, verifier
├── tools/       # agent-facing runtime and JSON result types
├── demo/        # demos
├── main.zig     # CLI + tool mode
└── root.zig     # package exports
```

## Demo Narrative for Judges

A strong demo flow is:

1. `capabilities` → show runtime manifest
2. `wallet-state` → show wallet execution context
3. `inspect-contract` → show contract intelligence and recommended actions
4. `recent-activity` → show semantic transaction understanding
5. `analyze-transfer` or `analyze-contract-call` → show safe preflight planning
6. `watch-payment` → show payment-confirmed trigger payload for workflows

This sequence presents the project as infrastructure for agent execution on TON, not just a developer CLI.

## Status

Implemented and validated in the current Zig codebase with green tests.

## License

MIT
