# Documentation Index

This file provides a compact map of the most important repository documents.

## Core overview

- `README.md` — main project overview, quickstart, tool actions, and judge-facing summary
- `SUBMISSION.md` — submission-oriented summary and track mapping
- `FINAL_SUBMISSION_COPY.md` — copy-ready submission text in English and Chinese
- `SHORT_PITCHES.md` — short pitch variants for forms and summaries
- `WHY_AGENT_INFRASTRUCTURE.md` — focused explanation of why this project fits Agent Infrastructure
- `RUNTIME_GUARANTEES.md` — behavioral guarantees, safety expectations, and action semantics
- `CHANGELOG.md` — summary of the runtime and submission-oriented enhancements
- `FINAL_CHECKLIST.md` — submission checklist
- `JUDGE_COMMANDS.md` — highest-signal evaluation commands

## Machine-readable assets

- `ton-zig-agent-kit tool capabilities` — runtime handshake and capability discovery
- `ton-zig-agent-kit tool runtime-spec` — formal machine-readable action contract
- `ton-zig-agent-kit tool demo-manifest` — compact evaluation flow
- `examples/action-schemas.json` — schema-shaped action examples

## Example and evaluation docs

- `examples/agent-runtime-demo.md` — high-level demo flow
- `examples/agent-playbooks.md` — agent workflow playbooks
- `examples/agent-integration.md` — integration guidance for agent frameworks and backends
- `examples/judge-walkthrough.md` — short judge-facing walkthrough
- `examples/ai-review-checklist.md` — checklist for automated or AI-based review

## Key implementation files

- `src/main.zig` — CLI and tool mode entrypoint
- `src/tools/tools_mod.zig` — agent runtime implementation
- `src/tools/types.zig` — structured tool result types
