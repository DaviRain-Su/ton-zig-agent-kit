# ton-zig-agent-kit

A **Zig-native TON contract toolkit for AI agents** - enabling AI agents to interact with any TON smart contract, complete "create invoice → monitor payment → verify on-chain" workflows.

## 🎯 Hackathon Submission

**Track**: Agent Infrastructure  
**Project**: `ton-zig-agent-kit` - A Zig-native TON execution and payment toolkit for AI agents  
**Submission Date**: 2026-03-25

## ✨ Features

### Core Capabilities

- ✅ **Raw Contract Interaction** - Call any TON contract via `runGetMethod` and BoC messaging
- ✅ **Cell/Builder/Slice** - Full bit-level serialization (up to 1023 bits, 4 refs per cell)
- ✅ **BoC Serialization** - Bag of Cells encode/decode
- ✅ **Wallet Operations** - Ed25519 signing, seqno management, transfer creation
- ✅ **Payment Flows** - Invoice generation, payment monitoring, on-chain verification

### Contract Standards

- ✅ **Jetton (TEP-74)** - Query balance, transfer tokens
- ✅ **NFT (TEP-62/64/66)** - Get NFT data, ownership info
- ✅ **Generic Contract** - Interface detection, ABI introspection

### AI Agent Tools

- ✅ **AgentTools** - Unified API for balance, invoice, verification
- ✅ **Error Handling** - Structured results with error codes
- ✅ **Multi-Provider** - Failover support for RPC endpoints

### Demo

- ✅ **Telegram Bot Demo** - Complete payment flow simulation

## 🚀 Quick Start

### Build

```bash
zig build
```

### Run Tests

```bash
zig build test
```

### CLI Usage

```bash
# Check TON balance
./zig-out/bin/ton-zig-agent-kit getBalance EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH

# Create payment invoice
./zig-out/bin/ton-zig-agent-kit paywatch invoice EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH 10

# Verify payment
./zig-out/bin/ton-zig-agent-kit paywatch verify <address> <comment>

# Run demo
./zig-out/bin/ton-zig-agent-kit demo bot

# Show help
./zig-out/bin/ton-zig-agent-kit help
```

## 🏗️ Architecture

```
ton-zig-agent-kit/
├── src/
│   ├── core/           # Layer 1: Raw Contract
│   │   ├── http_client.zig    # TonAPI/TON Center client
│   │   ├── cell.zig           # Cell/Builder/Slice
│   │   ├── boc.zig            # BoC serialization
│   │   ├── address.zig        # Address parsing
│   │   └── types.zig          # Core types
│   ├── wallet/         # Layer 1: Wallet
│   │   └── signing.zig        # Ed25519 signing
│   ├── contract/       # Layer 2: Contract Standards
│   │   ├── jetton.zig         # TEP-74 Jetton
│   │   ├── nft.zig            # TEP-62/64/66 NFT
│   │   └── abi_adapter.zig    # Interface detection
│   ├── paywatch/       # Layer 2: Payment Flows
│   │   ├── invoice.zig        # Invoice generation
│   │   ├── watcher.zig        # Payment monitoring
│   │   └── verifier.zig       # On-chain verification
│   ├── tools/          # Layer 2: Agent Tools
│   │   ├── tools_mod.zig      # AgentTools API
│   │   └── types.zig          # Tool result types
│   ├── demo/           # Layer 3: Demo
│   │   └── telegram_bot.zig   # Bot demo
│   ├── main.zig        # CLI entry
│   └── root.zig        # Library exports
```

## 📋 Implementation Status

| Day | Module | Status | Key Features |
|-----|--------|--------|--------------|
| 1 | core/http_client, core/address | ✅ | HTTP provider, address parsing |
| 2 | core/cell, core/boc | ✅ | Cell/Builder/Slice, BoC serialization |
| 3 | wallet/signing | ✅ | Ed25519 signing, wallet v4 messages |
| 4 | contract/jetton, contract/nft | ✅ | Jetton/NFT standard interfaces |
| 5 | paywatch | ✅ | Invoice, watcher, verifier |
| 6 | tools, demo | ✅ | AgentTools, Telegram bot demo |
| 7 | README, docs | ✅ | Documentation, final polish |

## 🔧 Technical Highlights

### Cell/Builder/Slice

Full bit-level control for TON's fundamental data structure:

```zig
var builder = Builder.init();
try builder.storeUint(42, 8);
try builder.storeCoins(1000000000);
try builder.storeAddress("EQ...");
const cell = try builder.toCell(allocator);
```

### Payment Verification

```zig
// Create invoice with unique comment
const invoice = try createInvoice(allocator, destination, amount, "Payment");

// Monitor for payment
var watcher = PaymentWatcher.init(&invoice, &client, 5000, 30000);
const result = try waitPayment(&watcher);

if (result.found) {
    // Payment confirmed on-chain
}
```

### Agent Tools

```zig
var tools = AgentTools.init(allocator, &client, config);

// Get balance
const balance = try tools.getBalance("EQ...");

// Create invoice
const invoice = try tools.createInvoice(1000000000, "Service payment");

// Verify payment
const verified = try tools.verifyPayment(invoice.comment);
```

## 🎬 Demo

Run the Telegram bot demo:

```bash
./zig-out/bin/ton-zig-agent-kit demo bot
```

Shows complete payment flow:
1. User creates order with `/buy 10`
2. Bot generates unique invoice with comment
3. User pays via TON wallet
4. Bot monitors and confirms payment
5. Order marked as complete

## 📦 Dependencies

- Zig 0.15.2+
- Standard library only (no external dependencies)

## 📝 License

MIT License - See LICENSE file

## 🤝 Acknowledgments

Built for **TON AI Hackathon** - Track 1: Agent Infrastructure

---

**Project**: ton-zig-agent-kit  
**Tagline**: A Zig-native TON execution and payment toolkit for AI agents  
**Team**: Davirian
