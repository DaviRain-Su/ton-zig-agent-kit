# Final Checklist

Use this checklist before submitting the project.

## Repository state

- [ ] `zig build` passes
- [ ] `zig test src/root.zig` passes
- [ ] no unintended local debug edits remain
- [ ] README top section reflects final project positioning

## Core machine-readable assets

- [ ] `capabilities` works
- [ ] `runtime-spec` works
- [ ] `demo-manifest` works
- [ ] `examples/action-schemas.json` is present and up to date

## Submission documents

- [ ] `SUBMISSION.md` is up to date
- [ ] `FINAL_SUBMISSION_COPY.md` is up to date
- [ ] `SHORT_PITCHES.md` is up to date
- [ ] `WHY_AGENT_INFRASTRUCTURE.md` is present
- [ ] `RUNTIME_GUARANTEES.md` is present
- [ ] `DOCS_INDEX.md` is present

## Examples and review docs

- [ ] `examples/agent-runtime-demo.md` is present
- [ ] `examples/agent-playbooks.md` is present
- [ ] `examples/agent-integration.md` is present
- [ ] `examples/judge-walkthrough.md` is present
- [ ] `examples/ai-review-checklist.md` is present

## Messaging consistency

- [ ] project tagline is consistent across docs
- [ ] one-line summary is consistent across docs
- [ ] Agent Infrastructure framing is consistent across docs
- [ ] machine-readable runtime framing is consistent across docs

## Suggested final verification commands

```bash
zig build
zig test src/root.zig
./zig-out/bin/ton-zig-agent-kit tool capabilities
./zig-out/bin/ton-zig-agent-kit tool runtime-spec
./zig-out/bin/ton-zig-agent-kit tool demo-manifest
```
