# `ton-zig-agent-kit` 完整规划

## 项目定位

**一句话**：支持与任意 TON 合约底层交互的 Zig 原生工具包，面向 AI Agent 场景

**核心能力声明**：
- Raw Layer：任何合约都能调 `runGetMethod` / 发 BoC
- 标准合约：提供 first-class wrapper
- 自定义合约：底层能力完备，需要接口信息即可调用

---

## 赛道

Track 1: Agent Infrastructure

---

## 项目结构

```
ton-zig-agent-kit/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig                  # CLI 入口
│   ├── root.zig                  # 库导出 root
│   │
│   ├── core/                     # Layer 1: Raw Contract (地基)
│   │   ├── http_client.zig       # TonAPI / TON Center HTTP provider
│   │   ├── provider.zig           # Multi-provider failover
│   │   ├── cell.zig              # Cell / Builder / Slice 编解码
│   │   ├── boc.zig               # BoC 序列化/反序列化
│   │   ├── address.zig            # 地址解析 (user-friendly ↔ raw)
│   │   └── types.zig             # 通用类型定义
│   │
│   ├── wallet/                   # Layer 1: Wallet
│   │   ├── wallet.zig            # 通用钱包接口
│   │   ├── wallet_v4.zig         # 主流钱包版本
│   │   └── signing.zig           # 离线签名 + seqno 管理
│   │
│   ├── contract/                 # Layer 2: Contract (可扩展)
│   │   ├── contract.zig          # 通用合约调用接口
│   │   ├── jetton.zig            # TEP-74 Jetton 标准封装
│   │   ├── nft.zig               # TEP-62/64/66 NFT 标准封装
│   │   └── abi_adapter.zig       # ABI 查询 + 自描述接口
│   │
│   ├── paywatch/                 # Layer 2: Payment Flow (核心差异化)
│   │   ├── invoice.zig           # 生成 unique comment invoice
│   │   ├── watcher.zig           # 轮询监听入账
│   │   └── verifier.zig         # 链上状态验证
│   │
│   ├── tools/                    # Layer 2: Agent Tools
│   │   ├── tools.zig             # 暴露给 AI 的工具接口
│   │   └── types.zig             # 工具参数/返回值类型
│   │
│   └── demo/                     # Layer 3: Demo
│       └── telegram_bot.zig      # Telegram bot 示例
│
├── tests/
│   ├── core_tests.zig
│   ├── cell_tests.zig
│   ├── wallet_tests.zig
│   ├── contract_tests.zig
│   └── paywatch_tests.zig
│
└── README.md
```

---

## 模块 API 设计

### Layer 1: Raw Contract (core/)

#### `core/http_client.zig` — HTTP Provider

```zig
pub const TonHttpClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, api_key: ?[]const u8) !TonHttpClient
    pub fn deinit(self: *TonHttpClient) void

    // 任意合约读
    pub fn runGetMethod(self: *TonHttpClient, address: []const u8, method: []const u8, stack: []const []const u8) !RunGetMethodResponse

    // 任意合约写
    pub fn sendBoc(self: *TonHttpClient, body: []const u8) !SendBocResponse

    // 通用查询
    pub fn getBalance(self: *TonHttpClient, address: []const u8) !BalanceResponse
    pub fn getTransactions(self: *TonHttpClient, address: []const u8, limit: u32) !TransactionsResponse
    pub fn lookupTx(self: *TonHttpClient, lt: i64, hash: []const u8) !TransactionResponse
};

pub const RunGetMethodResponse = struct {
    exit_code: i32,
    stack: []StackEntry,  // 可解析为任意类型
    logs: []const u8,
};
```

#### `core/cell.zig` — Cell/Builder/Slice

```zig
pub const Cell = struct {
    data: [128]u8,   // max 1023 bits = 128 bytes
    bit_len: u16,
    refs: [4]?*Cell,
    ref_cnt: u2,
};

pub const Builder = struct { ... };
pub const Slice = struct { ... };

// 核心操作
pub fn builderToCell(builder: *Builder) !*Cell
pub fn cellToSlice(cell: *Cell) *Slice
pub fn slice.loadUint(s: *Slice, comptime bits: u16) !u64
pub fn builder.storeUint(b: *Builder, value: u64, bits: u16) !void

// 地址编解码
pub fn loadAddress(s: *Slice) ![Address]
pub fn builder.storeAddress(b: *Builder, addr: *const Address) !void

// Coins 编解码
pub fn loadCoins(s: *Slice) !u64
pub fn builder.storeCoins(b: *Builder, coins: u64) !void
```

#### `core/contract.zig` — 任意合约调用接口

```zig
pub const GenericContract = struct {
    client: *TonHttpClient,
    address: []const u8,
};

pub fn callGetMethod(contract: *GenericContract, method: []const u8, args: []const []const u8) !RunGetMethodResponse
pub fn sendMessage(contract: *GenericContract, body: []u8) !SendBocResponse
```

### Layer 2: Standard Contract (contract/)

#### `contract/jetton.zig` — Jetton 标准封装

```zig
pub const JettonWallet = struct { ... };
pub const JettonMaster = struct { ... };

// TEP-74 标准接口
pub fn getJettonData(contract: *GenericContract) !JettonData
pub fn getWalletAddress(contract: *GenericContract, owner: []const u8) ![]const u8
pub fn jettonTransfer(wallet: *JettonWallet, destination: []const u8, amount: u64, response_destination: []const u8) ![]u8
```

#### `contract/abi_adapter.zig` — ABI 自描述接口

```zig
pub fn querySupportedInterfaces(client: *TonHttpClient, address: []const u8) !?SupportedInterfaces
pub fn queryAbiIpfs(client: *TonHttpClient, address: []const u8) !?AbiInfo
pub fn adaptToContract(address: []const u8, abi: ?AbiInfo) ContractAdapter
```

### Layer 3: Payment Flow (paywatch/)

```zig
pub fn createInvoice(destination: []const u8, amount: u64, description: []const u8) !Invoice
pub fn waitPayment(invoice: *Invoice, client: *TonHttpClient, timeout_ms: u32) !PaymentResult
pub fn verifyPayment(invoice: *Invoice, client: *TonHttpClient) !bool
```

### Agent Tools (tools/)

```zig
pub const AgentTools = struct {
    client: *TonHttpClient,
    keystore: *Keystore,
};

pub fn getBalance(tools: *AgentTools, address: []const u8) !BalanceResult
pub fn sendTon(tools: *AgentTools, to: []const u8, amount: u64, comment: ?[]const u8) !SendResult
pub fn createInvoice(tools: *AgentTools, amount: u64, description: []const u8) !InvoiceResult
pub fn verifyPayment(tools: *AgentTools, invoice_id: []const u8) !VerifyResult
pub fn lookupTx(tools: *AgentTools, lt: i64, hash: []const u8) !TxResult
```

---

## 关键技术要点

| 要点 | 说明 |
|------|------|
| TON 地址 | user-friendly (`EQCD...`) ↔ raw (`0x...`) 两种格式 |
| Cell 限制 | 最多 1023 bits，最多 4 个引用 |
| Nanoton | 1 TON = 10^9 nanotons |
| 钱包版本 | 主流 v4 (rwallet)，兼容 v3/v2 |
| Comment 编码 | UTF-8 text，放在 message body |
| 签名算法 | 通常 Ed25519 (wallet v4) |

---

## 开发顺序 (7 天)

| Day | 模块 | 交付 | 验收标准 |
|-----|------|------|---------|
| **1** | 项目骨架 + `core/http_client` + `core/address` | CLI 可查余额 + 地址转换 | `ton-zig-agent-kit rpc getBalance <addr>` 可用 |
| **2** | `core/cell` + `core/boc` + `core/contract` | Cell 编解码 + 任意合约调用 | `runGetMethod` 可用，测试通过 |
| **3** | `wallet/signing` + 转账 | 钱包签名 + `send_ton` 闭环 | 可从空钱包转账 |
| **4** | `contract/abi_adapter` + `contract/jetton` | ABI 查询 + Jetton 封装 | Jetton 余额/转账可用 |
| **5** | `paywatch/invoice` + `paywatch/watcher` | 支付监听完整流程 | invoice 生成 + 监听确认 |
| **6** | `tools/tools.zig` + `demo/telegram_bot` | Agent 接口 + Bot demo | "下单→付款→确认→发货" 跑通 |
| **7** | README + 视频 + 提交 | 提交 | README + 2min demo 视频 |

---

## 与任意合约交互的说明

### 能力边界

```
✅ 可以
├── 任意合约的 getMethod 调用（只要知道方法名和参数）
├── 任意合约的消息发送（只要知道 message body 格式）
├── 标准合约（Jetton/NFT/钱包）的高级封装
└── 有 ABI/self-description 的合约自动适配

⚠️ 需要额外信息
├── 未知合约的 getMethod 签名
├── 未知合约的 message body 格式
└── 合约业务逻辑（这超出工具范畴）
```

### 架构保证

```
Raw Layer (core/)
├── runGetMethod   → 任意合约读（需要方法名+参数）
├── sendBoc        → 任意合约写（需要 message 格式）
└── Cell/Builder   → 底层编解码

Contract Layer (contract/)
├── jetton.zig     → Jetton 标准封装
├── nft.zig        → NFT 标准封装
└── abi_adapter.zig → 有 ABI 时自动适配

Tools Layer (tools/)
└── 暴露统一接口给 AI Agent
```

---

## 提交文案

**Title**: `ton-zig-agent-kit: A Zig-native TON Contract Toolkit for AI Agents`

**One-liner**: 让 AI agent 能与任意 TON 合约交互，完成「收款 → 确认 → 触发合约」的完整闭环

**Abstract**:
1. `ton-zig-agent-kit` 是 Zig 原生的 TON 智能合约交互工具，支持与任意合约的底层交互（`runGetMethod` / BoC 发送）
2. 对标准合约（Jetton/NFT）提供 high-level wrapper，对支持 ABI 的合约提供自动适配
3. 面向 AI Agent 场景：生成支付 invoice、监听链上到账、验证 comment、完成自动化交付
