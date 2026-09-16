# NFT多币种拍卖系统

## 项目概述

基于 Foundry 框架开发的 Solidity 智能合约项目，实现了一个**可升级、多币种支持的 NFT 链上拍卖系统**。

核心特性：
- **UUPS 可升级架构** + EIP-7201 安全存储隔离
- **多币种竞价**：支持 ETH 及多种 ERC20 代币（如 USDC、DAI）混合出价
- **Chainlink 价格预言机**：通过 USD 统一比价，实现跨币种公平竞价
- **管理员币种管理**：动态添加/修改/删除支持的代币配置
- **拍卖级代币快照**：创建拍卖时可限定该场拍卖的可用币种，并保存配置快照
- **完整的拍卖生命周期**：创建 → 出价 → 退款 → 结束 → 资产清算

## 技术栈

| 类别 | 技术 |
|------|------|
| Solidity | `^0.8.33` |
| 合约库 | OpenZeppelin Contracts Upgradeable (`Initializable` / `OwnableUpgradeable` / `UUPSUpgradeable` / `ERC721Upgradeable`) |
| 预言机 | Chainlink Data Feed (`AggregatorV3Interface`) |
| 测试框架 | Foundry (Forge) |
| 测试类型 | Fuzz Testing / Invariant Testing / Table Testing / Mutation Testing / Brutalized Testing |
| 存储规范 | EIP-7201 `erc7201:nftauction.storage.auction.v1` |
| 升级模式 | UUPS Upgradeable (ERC-1822) |

## 快速开始

### 前置要求

- [Foundry](https://book.getfoundry.sh/getting-started/installation) 已安装
- 本地或远程 Ethereum RPC 节点

### 安装依赖

```bash
forge install
```

### 编译合约

```bash
forge build
```

### 运行测试

```bash
# 运行所有测试
forge test

# 运行测试并显示覆盖率
forge test --gas-report

# 运行 fuzz 测试
forge test --match-contract NFTAuctionV1Test --fuzz-runs 512

# 运行 invariant 测试
forge test --match-contract NFTAuctionV1Test --invariant-runs 512 --invariant-depth 200
```

### 运行测试覆盖率报告

```bash
forge coverage --report lcov
genhtml lcov.info -o coverage
```

### 本地部署（测试）

```bash
# 配置环境变量
cp .env.example .env
# 编辑 .env 填入相关配置

# 本地测试部署
forge script script/UUPS.s.sol --rpc-url http://localhost:8545 --broadcast
```

### 部署到 Sepolia 测试网

```bash
# 在 .env 中设置 FORK_MODE=true 并配置 SEPOLIA_RPC_URL
forge script script/UUPS.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

### 升级到 V2

```bash
forge script script/UpgradeToV2.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

## 项目结构

```
.
├── src/
│   ├── NFTAuctionV1.sol          # V1 拍卖合约（核心逻辑）
│   └── V2.sol                    # V2 升级示例合约
├── test/
│   ├── NFTAuctionV1.t.sol        # 单元测试 & Fuzz & Invariant 测试
│   └── handlers/
│       └── NFTAuctionV1Handler.sol  # Invariant 测试 Handler
├── script/
│   ├── UUPS.s.sol                # V1 部署脚本
│   └── UpgradeToV2.s.sol         # V2 升级脚本
├── foundry.toml                  # Foundry 配置
├── .env.example                  # 环境变量模板
└── README.md                     # 项目说明
```

## 合约架构

### 存储布局（EIP-7201）

合约采用 EIP-7201 命名存储槽，避免升级时的存储冲突：

```
erc7201:nftauction.storage.auction.v1
```

存储槽位置：`0x4c48d9668da3b85d45dd9d4fe97ed0e93efd4218c47ce0da3f0ab7fa4d259a00`

### 继承关系

```
NFTAuctionV1
  ├── Initializable          (可升级初始化)
  ├── OwnableUpgradeable     (所有权管理)
  ├── UUPSUpgradeable        (UUPS 升级模式)
  ├── ERC721Upgradeable      (NFT 标准)
  └── IERC721Receiver        (NFT 接收回调)
```

## 合约接口

### 管理员接口（仅 Owner）

| 函数 | 说明 |
|------|------|
| `batchAddTokenCfg(TokenInitConfig[] memory tokenInitList)` | 批量添加代币配置 |
| `addTokenCfg(uint256 token, address tokenAddr, address feedAddr)` | 添加新代币配置 |
| `updCfgTokenAddr(uint256 token, address tokenAddr)` | 修改代币合约地址 |
| `updCfgFeedAddr(uint256 token, address feedAddr)` | 修改预言机喂价地址 |
| `delTokenCfg(uint256 token)` | 删除代币配置 |

### 公开接口

| 函数 | 说明 |
|------|------|
| `createAuction(CreateAuctionParams calldata params)` | 创建拍卖 |
| `cancelAuction(uint256 auctionId)` | 取消拍卖（拍卖开始前） |
| `bidAuction(uint256 auctionId, uint256 token, uint256 amount)` | 参与拍卖出价 |
| `refund(uint256 auctionId, uint256 token)` | 退回未中标的出价 |
| `endAuction(uint256 auctionId)` | 结束拍卖（仅最高出价者或卖家可调用） |

### 查询接口

| 函数 | 说明 |
|------|------|
| `getAuctionInfo(uint256 auctionId)` | 获取拍卖详情 |
| `getBidPriceReturns(uint256 auctionId, address bidder, uint256 token)` | 获取可退款金额 |
| `getNtfToken2AuctionId(address nftContract, uint256 tokenId)` | 查询 NFT 是否已创建拍卖 |
| `getAuctionCount()` | 获取拍卖总数 |
| `getTokenIsExists(uint256 token)` | 查询代币是否已配置 |
| `getTokenAddrIsExists(address addr)` | 查询代币地址是否已配置 |
| `getFeedAddrIsExists(address addr)` | 查询喂价地址是否已配置 |
| `getTokenAddr(uint256 token)` | 获取代币合约地址 |
| `getFeedAddr(uint256 token)` | 获取喂价合约地址 |
| `getTokenCount()` | 获取已配置代币数量 |
| `getUSDByToken(uint256 token, uint256 tokenAmount)` | 获取代币对应的 USD 价格 |

## 拍卖流程

```
1. 管理员配置代币（ETH/USDC/DAI 等）+ Chainlink 喂价地址
         ↓
2. 卖家创建拍卖（指定 NFT、起拍价、开始时间、持续时间、允许的代币）
         ↓
3. 买家出价（支持 ETH 或 ERC20 代币，通过 USD 统一比价）
         ↓
4. 被超越的出价者可退款（refund）
         ↓
5. 拍卖到期后，最高出价者或卖家结束拍卖
         ↓
6. NFT 转移给最高出价者，款项转给卖家
```

## 代币配置说明

代币通过 `token` ID 进行标识：

| Token ID | 说明 | tokenAddr |
|----------|------|-----------|
| 0 | ETH（原生代币） | `address(0)` |
| 1 | USDC | USDC 合约地址 |
| 2 | DAI | DAI 合约地址 |

每个代币需要配置对应的 Chainlink `token/USD` 喂价地址，用于统一转换为 USD 进行跨币种比价。

## 环境变量配置

参考 `.env.example` 文件：

```bash
FORK_MODE=false                    # false=本地Mock, true=Sepolia测试网
SEPOLIA_RPC_URL=...                # Sepolia RPC 地址
SEPOLIA_SELLER1_ADDR=...           # 卖家地址
SEPOLIA_BIDDER1_ADDR=...           # 出价者地址
USDC_ADDR=...                      # USDC 合约地址
DAI_ADDR=...                       # DAI 合约地址
ETH_USD_FEED=...                   # ETH/USD Chainlink 喂价地址
USDC_USD_FEED=...                  # USDC/USD Chainlink 喂价地址
DAI_USD_FEED=...                   # DAI/USD Chainlink 喂价地址
```

## Foundry 配置

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.33"
optimizer = true
optimizer_runs = 100

[fuzz]
runs = 512
corpus_dir = "cache/fuzz-corpus"
show_edge_coverage = true

[invariant]
runs = 512
depth = 200
check_interval = 1
fail_on_revert = false
```

## 安全考虑

- **EIP-7201 存储隔离**：避免合约升级时的存储冲突
- **UUPS 升级授权**：仅 Owner 可触发升级
- **出价防重入**：通过退款机制和状态变量保护
- **价格预言机校验**：检查喂价数据有效性（负数校验）
- **时间戳操纵缓解**：对关键时间检查添加审计注释
- **ERC20 安全转账**：使用 OpenZeppelin `SafeERC20` 库

## License

SEE LICENSE IN LICENSE