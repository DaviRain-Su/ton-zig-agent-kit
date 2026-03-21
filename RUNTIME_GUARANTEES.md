# Runtime Guarantees

This document describes the behavioral guarantees of `ton-zig-agent-kit` tool mode.

## Core model

The runtime is designed around an **analyze-first** model for agent systems.

Tool actions exposed in the current structured tool interface are intended to provide:

- chain context
- planning hints
- semantic summaries
- event-trigger metadata

## Read-only and planning guarantees

### Read-only actions

These actions are intended to be observational and machine-readable:

- `capabilities`
- `demo-manifest`
- `runtime-spec`
- `wallet-state`
- `inspect-contract`
- `recent-activity`
- `portfolio`

### Planning-only actions

These actions are designed to analyze before execution, not to broadcast transactions themselves:

- `analyze-transfer`
- `analyze-contract-call`

They may return:

- `risk_flags`
- `recommended_action`
- `executable`
- deployment and state-init planning hints

### Watch / observation actions

- `watch-payment`

This action is intended to observe chain state until a matching payment condition is detected and then return structured trigger metadata.

## Safety guarantees

The runtime exposes safety-oriented hints where applicable:

- deployment awareness
- seqno awareness
- state-init planning
- risk flags
- recommended actions
- recommended followups

These are intended to help upstream agents avoid blind chain interactions.

## Output contract guarantees

Structured tool outputs are JSON-oriented and machine-consumable.

Common expectations:

- `success` is present in action responses
- failures are surfaced as structured error outputs where possible
- manifest-style actions return capability metadata intended for discovery and integration
- semantic actions return labels and followup hints where available

## Integration guarantee

The runtime is designed to be usable by:

- autonomous agents
- copilots
- workflow engines
- bot backends

through a simple action + JSON payload interface.

## Current non-goals

The current tool-mode surface is not intended to be a full transaction execution server.
Its primary goal is to provide structured context, planning, and workflow-trigger primitives for higher-level agent systems.
