# Changelog

## Agent Infrastructure Polish

This phase focused on turning `ton-zig-agent-kit` from a TON toolkit/CLI into a more submission-ready TON-native runtime for the Agent Infrastructure track.

### Runtime and tool surface
- added structured `tool` mode
- added `capabilities`
- added `demo-manifest`
- expanded tool actions for wallet, contract, activity, portfolio, and payment workflows

### Wallet and execution context
- added `wallet-state`
- added transfer preflight analysis
- added contract-call preflight analysis
- exposed deployment awareness, seqno awareness, and state-init planning

### Contract intelligence
- expanded `inspect-contract`
- added `agent_hints`
- added `risk_flags`
- added `recommended_actions`
- added example payloads for recommended actions

### Activity semantics
- expanded `recent-activity`
- added semantic tags
- added followup recommendations
- added summary counts for Jetton, NFT, ABI, and transfer-like activity

### Payment-triggered workflows
- expanded `watch-payment`
- added `trigger_ready`
- added `trigger_payload`
- added `trigger_id`
- added `workflow_name`
- added `correlation_id`
- supported custom workflow metadata in requests

### Submission and documentation
- rewrote `README.md` around Agent Infrastructure positioning
- added `SUBMISSION.md`
- added `WHY_AGENT_INFRASTRUCTURE.md`
- added `examples/agent-runtime-demo.md`
- added `examples/agent-playbooks.md`
- added `examples/agent-integration.md`
- added `examples/judge-walkthrough.md`

### Runtime manifest improvements
- added tagline and submission pitch
- added input schema / execution / response model metadata
- added safety primitives
- added event primitives
- added intended integrations
- added demo flows and agent patterns

### Validation
- kept `zig test src/root.zig` green
- fixed build issues and restored `zig build`
- validated final state with:
  - `zig build`
  - `zig test src/root.zig`
