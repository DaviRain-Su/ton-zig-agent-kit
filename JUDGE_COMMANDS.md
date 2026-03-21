# Judge Commands

These are the highest-signal commands for quickly evaluating the project.

## 1. Build

```bash
zig build
```

## 2. Run tests

```bash
zig test src/root.zig
```

## 3. Runtime handshake

```bash
./zig-out/bin/ton-zig-agent-kit tool capabilities
```

## 4. Formal runtime contract

```bash
./zig-out/bin/ton-zig-agent-kit tool runtime-spec
```

## 5. Compact evaluation flow

```bash
./zig-out/bin/ton-zig-agent-kit tool demo-manifest
```

## Optional higher-signal operational commands

### Contract intelligence

```bash
./zig-out/bin/ton-zig-agent-kit tool inspect-contract '{"address":"0:..."}'
```

### Safe transfer planning

```bash
./zig-out/bin/ton-zig-agent-kit tool analyze-transfer '{"destination":"0:...","amount":10000000,"comment":"demo"}'
```

### Payment-triggered workflow

```bash
./zig-out/bin/ton-zig-agent-kit tool watch-payment '{"wallet_address":"0:...","comment":"order-123","timeout_ms":10000,"workflow_name":"grant_access","correlation_id":"order-123"}'
```
