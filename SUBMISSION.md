# Submission Notes

## Project

**ton-zig-agent-kit**

## Track

**Agent Infrastructure**

## One-line Summary

A Zig-built TON-native agent runtime for wallet context, contract intelligence, safe execution planning, and payment-triggered workflows.

## Tagline

TON-native runtime for agent context, execution planning, and payment-triggered workflows.

## Problem

Most blockchain tooling is built for developers or manual CLI users, not autonomous agents.
Agents need structured runtime outputs, risk-aware preflight analysis, semantic activity context, and event primitives they can use to trigger workflows.

## Why Now / Why TON / Why Zig

### Why now

AI agents are moving from chat interfaces into execution environments.
That creates a need for infrastructure that can provide safe planning, context, and event hooks before touching blockchain state.

### Why TON

TON has real payment and contract interaction surfaces, but agent-oriented infrastructure around them is still early.
That makes it a strong place to build runtime primitives for agents.

### Why Zig

Zig makes it practical to build a lightweight, dependency-minimal, systems-level runtime with explicit memory control and predictable behavior.
That is a good fit for infrastructure that needs to be embedded, audited, and composed into larger systems.

## Solution

`ton-zig-agent-kit` turns TON functionality into an agent-friendly runtime with structured JSON tool actions.
It helps agents:

- understand wallet state and deployment context
- inspect contracts and detect standard interfaces
- analyze transfers and contract calls before execution
- summarize recent account activity with semantic labels
- observe portfolio state
- treat TON payments as workflow triggers

## Key Tool Actions

- `capabilities`
- `runtime-spec`
- `demo-manifest`
- `wallet-state`
- `inspect-contract`
- `recent-activity`
- `analyze-transfer`
- `analyze-contract-call`
- `portfolio`
- `watch-payment`

## Machine-readable Runtime Surface

The project exposes a machine-readable runtime surface for AI systems:

- `capabilities` acts as the runtime handshake
- `runtime-spec` provides a formal action contract
- `demo-manifest` provides an evaluation-oriented execution path
- `examples/action-schemas.json` provides schema-shaped examples for automated consumers

## Why This Is Machine-review Friendly

The repository is optimized for automated review because it exposes multiple machine-readable layers:

- capability discovery via `capabilities`
- formal action metadata via `runtime-spec`
- evaluation flow via `demo-manifest`
- schema-shaped examples via `examples/action-schemas.json`
- behavioral guarantees via `RUNTIME_GUARANTEES.md`

This reduces ambiguity for an AI reviewer and makes the project easier to classify as an agent runtime rather than a general blockchain CLI.

## Why It Fits Agent Infrastructure

This project is not only a TON SDK or CLI.
It is a runtime layer for AI systems that need:

- machine-readable chain context
- execution planning before sending messages
- contract intelligence and next-step recommendations
- activity semantics and followup hints
- payment-confirmed triggers for downstream workflows

## Judge Mapping

### Infrastructure surface
- `capabilities`
- `demo-manifest`

### Context layer
- `wallet-state`
- `recent-activity`
- `portfolio`

### Safe action planning
- `analyze-transfer`
- `analyze-contract-call`

### Contract intelligence
- `inspect-contract`

### Workflow trigger primitive
- `watch-payment`

## Demo Flow

1. `demo-manifest`
2. `capabilities`
3. `wallet-state`
4. `inspect-contract`
5. `recent-activity`
6. `analyze-transfer`
7. `watch-payment`

## Validation

Tested with:

```bash
zig build
zig test src/root.zig
```

Validated result during implementation:

- build passes
- **245 passed**
- **7 skipped**
- **0 failed**

## Notable Agent-Friendly Features

### Contract intelligence
- interface detection
- ABI presence detection
- risk flags
- agent hints
- recommended actions with example payloads

### Activity semantics
- semantic tags
- comment extraction
- jetton / nft operation hints
- recommended followups

### Safe execution planning
- deployment-state awareness
- seqno awareness
- state-init attachment planning
- executable recommendation
- risk flags

### Payment-triggered workflows
- payment confirmation watcher
- trigger payload generation
- trigger id
- workflow name
- correlation id

## Repository Docs

- `README.md`
- `WHY_AGENT_INFRASTRUCTURE.md`
- `examples/agent-runtime-demo.md`
- `examples/agent-playbooks.md`
- `examples/agent-integration.md`

## Short Pitch

`ton-zig-agent-kit` makes TON usable as agent infrastructure by exposing wallet state, contract intelligence, safe preflight analysis, and payment-triggered workflow primitives through structured JSON tool actions.
