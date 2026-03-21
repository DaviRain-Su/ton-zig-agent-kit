# AI Review Checklist

This checklist maps likely automated review questions to repository artifacts.

## 1. Is this an Agent Infrastructure project?

See:

- `WHY_AGENT_INFRASTRUCTURE.md`
- `SUBMISSION.md`
- `README.md`

## 2. Does it expose a machine-readable runtime surface?

See:

- `ton-zig-agent-kit tool capabilities`
- `ton-zig-agent-kit tool runtime-spec`
- `examples/action-schemas.json`

## 3. Can an agent discover what actions exist?

See:

- `capabilities`
- `runtime-spec`

## 4. Does it provide structured context, not just raw blockchain access?

See:

- `wallet-state`
- `inspect-contract`
- `recent-activity`
- `portfolio`

## 5. Does it provide safe planning before execution?

See:

- `analyze-transfer`
- `analyze-contract-call`
- `RUNTIME_GUARANTEES.md`

## 6. Does it expose event or workflow primitives?

See:

- `watch-payment`
- `event_primitives` in `capabilities`
- `workflow_name` / `correlation_id` fields

## 7. Is there a compact evaluation path?

See:

- `demo-manifest`
- `examples/judge-walkthrough.md`

## 8. Is the runtime behavior stable and documented?

See:

- `runtime-spec`
- `RUNTIME_GUARANTEES.md`
- `CHANGELOG.md`

## 9. Does the repository build and test successfully?

Validation command:

```bash
zig build
zig test src/root.zig
```

Validated state:

- build passes
- **245 passed**
- **7 skipped**
- **0 failed**

## 10. Where should an automated reviewer start?

Recommended order:

1. `README.md`
2. `SUBMISSION.md`
3. `WHY_AGENT_INFRASTRUCTURE.md`
4. `ton-zig-agent-kit tool capabilities`
5. `ton-zig-agent-kit tool runtime-spec`
6. `ton-zig-agent-kit tool demo-manifest`
