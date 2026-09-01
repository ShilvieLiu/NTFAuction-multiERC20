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

## 项目接口
### 仅管理
- batchAddTokenCfg(TokenInitConfig[] memory tokenInitList) 批量添加token配置
- addTokenCfg(uint256 token, address tokenAddr, address feedAddr) 添加新token配置
- updCfgTokenAddr(uint256 token, address tokenAddr) 修改指定token配置的tokenAddr
- updCfgFeedAddr(uint256 token, address feedAddr) 修改指定token配置的feedAddr
- delTokenCfg(uint256 token) 删除指定token配置


### 所有人
- createAuction(CreateAuctionParams calldata params) 创建拍卖
- cancelAuction(uint256 auctionId) 取消拍卖
- refund(uint256 auctionId, uint256 token) 退款
- endAuction(uint256 auctionId) 结束拍卖
- bidAuction(uint256 auctionId, uint256 token, uint256 amount) 出价
- getAuctionInfo(uint256 auctionId) 根据auctionId获取某个拍卖详情
- getBidPriceReturns(uint256 auctionId, address bidder, uint256 token) 获取某拍卖某出价人某代币该退回的总数量
- getNtfToken2AuctionId(address nftContract, uint256 tokenId) 获取某合约某token是否已创建拍卖
- getAuctionCount() 获取拍卖数量
- getTokenIsExists(uint256 token) 配置中，token是否存在
- getTokenAddrIsExists(address addr) 配置中，tokenAddr是否存在
- getFeedAddrIsExists(address addr) 配置中，feedAddr是否存在
- getTokenAddr(uint256 token) 根据token获取配置的对应tokenAddr
- getFeedAddr(uint256 token) 根据token获取配置的对应feedAddr
- getTokenCount() 获取tokenCount
- getUSDByToken(uint256 token, uint256 tokenAmount) 获取当前对应的美元价格