# Why This Fits Agent Infrastructure

`ton-zig-agent-kit` is not just a TON SDK or a human-oriented CLI.
It is a TON-native runtime layer designed for AI agents and orchestration systems.

## What makes it infrastructure

Agent Infrastructure projects typically provide reusable execution and context primitives that other systems can build on.
This project does exactly that for TON.

It gives agents:

- structured wallet context
- contract intelligence
- semantic account activity summaries
- preflight execution analysis
- payment-triggered event primitives

## Why this is not just a wallet tool

Traditional wallet tooling focuses on raw send operations.
This runtime helps agents decide **whether** and **how** to act before execution.

Examples:

- `wallet-state` tells the agent whether the wallet is deployed and whether state init is needed
- `analyze-transfer` returns executable status and risk flags before a transfer is sent
- `analyze-contract-call` plans ABI or standard body execution before submission
- `inspect-contract` identifies interfaces and recommends next actions
- `recent-activity` summarizes transactions semantically and suggests followups
- `watch-payment` turns a TON payment into a workflow trigger

## Infrastructure primitives exposed by the runtime

### Context primitives
- wallet readiness
- deployment status
- seqno
- recent activity semantics
- portfolio state

### Safety primitives
- risk flags
- recommended action
- recommended followup
- state-init planning
- deployment awareness
- analyze-first execution model

### Event primitives
- `payment_confirmed`
- trigger payloads
- trigger id
- workflow name
- correlation id

### Contract intelligence primitives
- wallet detection
- Jetton detection
- NFT detection
- ABI detection
- recommended action templates

## Who can integrate with it

This runtime is suitable for:

- autonomous agents
- copilots
- workflow engines
- bot backends
- agent orchestration platforms

## Why this is strong for the Agent Infrastructure track

The project gives TON a reusable runtime surface for AI systems.
Instead of requiring every agent builder to implement chain-specific parsing, planning, and payment monitoring themselves, `ton-zig-agent-kit` provides those capabilities as structured tool actions.

That is infrastructure.

## Minimal judge framing

If a judge asks why this belongs in Agent Infrastructure, the short answer is:

> `ton-zig-agent-kit` is a TON-native runtime for AI agents. It gives them structured chain context, safe execution planning, contract intelligence, and payment-triggered workflow primitives through machine-readable tool actions.
