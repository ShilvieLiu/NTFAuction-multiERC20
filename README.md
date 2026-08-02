# NFT拍卖系统
## 项目概述
本项目使用 Foundry + Solidity + OpenZepplin 技术，实现一个拥有最基本拍卖功能、支持 UUPS 升级、仅使用 ETH 出价的 NFT 拍卖系统。

## 项目结构
```
.
├── README.md
├── foundry.lock
├── foundry.toml
├── lib
│   ├── forge-std
│   ├── openzeppelin-contracts
│   └── openzeppelin-contracts-upgradeable
├── remappings.txt
├── script
│   ├── UUPS.s.sol                  # V1版本部署script
│   └── UpgradeToV2.s.sol           # V2版本部署script
├── src
│   ├── NFTAuctionV1.sol            # V1版本合约
│   └── V2.sol                      # V2版本合约
└── test
    ├── NFTAuctionV1.t.sol          # V1版本合约测试
    └── handlers
        └── NFTAuctionV1Handler.sol # V1版本invariant handler测试文件
```
