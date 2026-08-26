// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {NFTAuctionV1} from "../src/NFTAuctionV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
//import {NFTAuctionV1Handler} from "./handlers/NFTAuctionV1Handler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

contract AppleNFT is ERC721("AppleNFT", "APL") {
    function mint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}

contract MockUsdc is ERC20("USDC", "USDC") {
    function decimals() public override pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockDai is ERC20("DAI", "DAI") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract BananaNFT is ERC721Upgradeable {}

contract NFTAuctionV1Test is Test {
    bytes32 public constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 public constant AUCTION_STORAGE_LOCATION =
        0x4c48d9668da3b85d45dd9d4fe97ed0e93efd4218c47ce0da3f0ab7fa4d259a00;
    address public constant SEPOLIA_NFT_ADDR = 0xD4731999Cf9DBB165752C0321Eb474E65307000F;

    uint256 public currTs;

    NFTAuctionV1 public auctionSys;
    address public auctionSysAddr;
    address public auctionSysOwner = makeAddr("auctionSysOwner");
    ERC1967Proxy public auctionSysProxy;
    address public auctionSysProxyAddr;

    address public random = makeAddr("random");

    NFTAuctionV1 public nftSys1;
    address public nftSys1Addr;
    address public nftSys1Owner = makeAddr("nftSys1Owner");
    ERC1967Proxy public nftSys1Proxy;
    address public nftSys1ProxyAddr;

    AppleNFT appleNft;
    address appleNftAddr;
    uint256 public constant APPLENFT_TOKENID_1 = 1;
    uint256 public constant  APPLENFT_TOKENID_2 = 2;

    uint256 public constant AUCTION_ID_1 = 1;

    address public seller1 = makeAddr("seller1");

    address public bidder1 = makeAddr("bidder1");
    address public bidder2 = makeAddr("bidder2");

    uint256 public auctionSysProxyInitBalance;
    uint256 public seller1InitBalance;
    uint256 public bidder1InitBalance;
    uint256 public bidder2InitBalance;

    //NFTAuctionV1Handler public v1Handler;

    uint256 public tokenCfgCount;

    address public usdcAddr;
    address public daiAddr;
    address public usdcBidder = 0x0077777d7EBA4688BDeF3E311b846F25870A19B9;
    address public daiBidder = 0xc94b1BEe63A3e101FE5F71C80F912b4F4b055925;

    uint256 public usdcBidderInitBalance;
    uint256 public daiBidderInitBalance;

    bool isForkMode;
    address sepoliaNFT1Owner;
    uint256 sepoliaNFT1OwnerInitBalance;

    int256 public constant ETH_USD_FEED = 180000000000;
    int256 public constant USDC_USD_FEED = 99993782;
    int256 public constant DAI_USD_FEED = 99988309;
    MockV3Aggregator public mockEthUsdFeed = new MockV3Aggregator(8, ETH_USD_FEED);
    MockV3Aggregator public mockUsdcUsdFeed = new MockV3Aggregator(8, USDC_USD_FEED);
    MockV3Aggregator public mockDaiUsdFeed = new MockV3Aggregator(8, DAI_USD_FEED);    

    MockUsdc mockUsdc = new MockUsdc();
    MockDai mockDai = new MockDai();

    // #region 共用函数
    //// 部署NFTAuctionV1合约
    function newNftContract(string memory sys, address owner, string memory nftName, string memory nftSymbol, NFTAuctionV1.TokenInitConfig[] memory tokenInitList)
        public
        returns (NFTAuctionV1 nftSys, address nftSysImpAddr, ERC1967Proxy nftSysProxy, address nftSysProxyAddr)
    {
        vm.startPrank(owner);
        console.log(sys, "owner:", owner);
        nftSys = new NFTAuctionV1();
        nftSysImpAddr = address(nftSys);
        console.log(sys, "implementation address:", nftSysImpAddr);
        bytes memory initData = abi.encodeCall(NFTAuctionV1.initialize, (owner, nftName, nftSymbol, tokenInitList));
        nftSysProxy = new ERC1967Proxy(nftSysImpAddr, initData);
        nftSysProxyAddr = address(nftSysProxy);
        console.log(sys, "proxy address:", nftSysProxyAddr);
        vm.stopPrank();
    }

    // 获取AuctionStorage.auctionId
    function getStorageAuctionId() public view returns (uint256) {
        return uint256(vm.load(auctionSysProxyAddr, AUCTION_STORAGE_LOCATION));
    }

    // 获取AuctionStorage.ntfToken2AuctionId
    function getStorageNtfToken2AuctionId(address nftContract, uint256 tokenId) public view returns (uint256) {
        // mapping 基础slot = 根槽 + 相对偏移1
        bytes32 mapBase = bytes32(uint256(AUCTION_STORAGE_LOCATION) + 1);
        // 第一层key：nftContract合约地址
        bytes32 layer1 = keccak256(abi.encode(nftContract, mapBase));
        // 第二层key：tokenId
        bytes32 finalSlot = keccak256(abi.encode(tokenId, layer1));

        return uint256(vm.load(auctionSysProxyAddr, finalSlot));
    }

    // 获取bidPriceReturns的slot
    function getBidPriceReturnsSlot(uint256 auctionId, address bidder, uint256 token) public pure returns (bytes32) {
        // mapping 基础slot = 根槽 + 相对偏移3
        bytes32 mapBase = bytes32(uint256(AUCTION_STORAGE_LOCATION) + 3);
        // 第一层key：auctionId
        bytes32 layer1 = keccak256(abi.encode(auctionId, mapBase));
        // 第二层key：bidder
        bytes32 layer2 = keccak256(abi.encode(bidder, layer1));
        // 第三层key：token
        bytes32 finalSlot = keccak256(abi.encode(token, layer2));
        return finalSlot;
    }

    // #endregion 共用函数

    function setUp() public {
        currTs = block.timestamp;
        console.log("currTs of setUp:", currTs);        

        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](3);

        isForkMode = vm.envOr("FORK_MODE", false);
        if(isForkMode) {
            string memory rpc = vm.envString("SEPOLIA_RPC_URL");
            uint256 forkId = vm.createFork(rpc);
            vm.selectFork(forkId);

            currTs = block.timestamp;
            console.log("FORK_MODE currTs of setUp:", currTs);

            // daiBidderInitBalance = IERC20(daiAddr).balanceOf(daiBidder);
            // usdcBidderInitBalance = IERC20(usdcAddr).balanceOf(usdcBidder);

            seller1 = vm.envAddress("SEPOLIA_SELLER1_ADDR");
            seller1InitBalance = seller1.balance;

            bidder1 = vm.envAddress("SEPOLIA_BIDDER1_ADDR");
            bidder2 = vm.envAddress("SEPOLIA_BIDDER2_ADDR");
            bidder1InitBalance = bidder1.balance;
            bidder2InitBalance = bidder2.balance;

            sepoliaNFT1Owner = ERC721(SEPOLIA_NFT_ADDR).ownerOf(1);
            deal(sepoliaNFT1Owner, 10 ether);
            sepoliaNFT1OwnerInitBalance = sepoliaNFT1Owner.balance;

            // 构造token初始配置
            usdcAddr = vm.envAddress("USDC_ADDR");
            daiAddr = vm.envAddress("DAI_ADDR");
            tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: 0, tokenAddr: address(0), feedAddr: vm.envAddress("ETH_USD_FEED")});
            tokenInitList[1] = NFTAuctionV1.TokenInitConfig({token: 1, tokenAddr: usdcAddr, feedAddr: vm.envAddress("USDC_USD_FEED")});
            tokenInitList[2] = NFTAuctionV1.TokenInitConfig({token: 2, tokenAddr: daiAddr, feedAddr: vm.envAddress("DAI_USD_FEED")});            

        } else {
            // 部署 AppleNFT 用来测试
            appleNft = new AppleNFT();
            appleNftAddr = address(appleNft);
            console.log("seller1 address:", seller1);
            console.log("appleNftAddr:", appleNftAddr);
            vm.prank(seller1);
            appleNft.mint(seller1, APPLENFT_TOKENID_1);
            appleNft.mint(seller1, APPLENFT_TOKENID_2);

            // 给bidder1、bidder2账号各充 10 ether
            deal(seller1, 10 ether);
            deal(bidder1, 100 ether);
            deal(bidder2, 100 ether);

            seller1InitBalance = seller1.balance;
            bidder1InitBalance = bidder1.balance;
            bidder2InitBalance = bidder2.balance;

            mockUsdc.mint(usdcBidder, 1000 * 10 ** 6);
            mockDai.mint(daiBidder, 1000 * 10 ** 18);            

            // 构造token初始配置
            usdcAddr = address(mockUsdc);
            daiAddr =  address(mockDai);       
            tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: 0, tokenAddr: address(0), feedAddr: address(mockEthUsdFeed)});
            tokenInitList[1] = NFTAuctionV1.TokenInitConfig({token: 1, tokenAddr: usdcAddr, feedAddr: address(mockUsdcUsdFeed)});
            tokenInitList[2] = NFTAuctionV1.TokenInitConfig({token: 2, tokenAddr: daiAddr, feedAddr: address(mockDaiUsdFeed)});
            
        }

        daiBidderInitBalance = IERC20(daiAddr).balanceOf(daiBidder);
        usdcBidderInitBalance = IERC20(usdcAddr).balanceOf(usdcBidder);
        
        tokenCfgCount = 3;

        // 部署 拍卖合约
        (auctionSys, auctionSysAddr, auctionSysProxy, auctionSysProxyAddr) =
            newNftContract("auction", auctionSysOwner, "AuctionSys", "AS", tokenInitList);
        
        auctionSysProxyInitBalance = auctionSysProxyAddr.balance;       

        // 不变量测试准备
        // v1Handler = new NFTAuctionV1Handler(auctionSysProxyAddr, NFTAuctionV1(auctionSysProxyAddr), appleNft);
        // targetContract(address(v1Handler));

        console.log("By default account is:", address(this));
        console.log("===setUp End=========");
    }

    // 测试sepolia测试网ETH/USD返回的价格
    function test_Chainlink() public {
        //vm.skip(!isForkMode); // 若不是Fork模式，则不执行以下代码

        NFTAuctionV1.FeedResult memory feedRt = NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(2, 50);
        console.log("tokenDecimals:", feedRt.tokenDecimals);
        console.log("rawPrice:", feedRt.rawPrice);        
        console.log("updateTime:", feedRt.updateTime);
        console.log("feedDecimals:", feedRt.feedDecimals);
        console.log("decimals:", feedRt.decimals);
        console.log("usdValue:", feedRt.usd18Value);
    }

    // #region UUPS Test Start===========================================

    // 读取【裸逻辑合约自己的存储】，从未初始化，owner=0
    function test_Impl_Owner() public view {
        address implOwner = auctionSys.owner();
        console.log("Get owner of auction system:", implOwner);
        vm.assertNotEq(auctionSysOwner, implOwner, "auctionSysOwner == implOwner");
    }

    // 读取逻辑合约IMPLEMENTATION_SLOT值，0x0
    function test_Impl_ImplSlot() public view {
        address implImplSlotAddr = address(uint160(uint256(vm.load(auctionSysAddr, IMPLEMENTATION_SLOT))));
        console.log("Value of implementation slot in Auction System:", implImplSlotAddr);
        vm.assertNotEq(auctionSysAddr, implImplSlotAddr, "auctionSysAddr == implImplSlotAddr");
    }

    // 读取【Proxy代理合约的独立存储】，部署时执行过initialize，owner=auctionSysOwner
    function test_Proxy_Owner() public view {
        address proxyOwner = NFTAuctionV1(auctionSysProxyAddr).owner();
        console.log("Get owner of auction system proxy:", proxyOwner);
        vm.assertEq(auctionSysOwner, proxyOwner, "auctionSysOwner != proxyOwner");
    }

    // 读取Proxy代理合约IMPLEMENTATION_SLOT值=auctionSysAddr
    function test_Proxy_ImplSlot() public view {
        address proxyImplSlotAddr = address(uint160(uint256(vm.load(auctionSysProxyAddr, IMPLEMENTATION_SLOT))));
        console.log("Value of implementation slot in Auction System Proxy:", proxyImplSlotAddr);
        vm.assertEq(auctionSysAddr, proxyImplSlotAddr, "auctionSysAddr != proxyImplSlotAddr");
    }

    // V1升级V2地址address(0) revert
    function test_RevertWhen_UpgradeToZeroAddr() public {
        vm.prank(auctionSysOwner); // 只对当前下一行代码使用auctionSysOwner账号运行，需要在某个区间一致运行请使用vm.startPrank()+vm.stopPrank()
        vm.expectRevert();
        NFTAuctionV1(auctionSysProxyAddr).upgradeToAndCall(address(0), "");
        console.log("Success => Upgrade to address(0) failed");
    }

    // 非管理员执行升级操作 revert OwnableUnauthorizedAccount(address)
    function test_RevertIf_NonAdmin() public {
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", random));
        NFTAuctionV1(auctionSysProxyAddr).upgradeToAndCall(address(0), "");
        console.log("Success => Non admin failed to perform upgrade operation");
    }

    // 升级至无UUPS的普通合约 revert ERC1967InvalidImplementation(address)
    function test_RevertWhen_UpgradeToNonUUPSContract() public {
        address nftContract;
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
        } else {
            nftContract = appleNftAddr;
        }

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSignature("ERC1967InvalidImplementation(address)", nftContract));
        NFTAuctionV1(auctionSysProxyAddr).upgradeToAndCall(nftContract, "");
        console.log("Success => Upgrade to non UUPS contract failed");
    }

    // #endregion UUPS Test End=======================================================  

    // #region batchAddTokenCfg 测试开始============================================================
    // batchAddTokenCfg 测试成功场景
    function test_batchAddTokenCfg_Success() public {
        uint256 token1 = 4;
        address tokenAddr1 = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr1 = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;
        uint256 token2 = 5;
        address tokenAddr2 = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
        address feedAddr2 = 0xc59E3633BAAC79493d908e63626716e204A45EdF;

        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](2);
        // EURC -> USD
        tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: token1, tokenAddr: tokenAddr1, feedAddr: feedAddr1});
        // LINK -> USD
        tokenInitList[1] = NFTAuctionV1.TokenInitConfig({token: token2, tokenAddr: tokenAddr2, feedAddr: feedAddr2});

        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenIsExists(token1), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenIsExists(token2), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr1), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr2), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr1), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr2), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token1), address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token2), address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token1), address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token2), address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenCount(), tokenCfgCount);

        vm.prank(auctionSysOwner);
        NFTAuctionV1(auctionSysProxyAddr).batchAddTokenCfg(tokenInitList);

        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenIsExists(token1), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenIsExists(token2), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr1), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr2), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr1), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr2), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token1), tokenAddr1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token2), tokenAddr2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token1), feedAddr1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token2), feedAddr2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenCount(), tokenCfgCount + 2);
    }

    // batchAddTokenCfg: 不是管理员调用 revert
    function test_batchAddTokenCfg_RevertWhen_nonAdmin() public {
        uint256 token1 = 4;
        address tokenAddr1 = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr1 = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;
        uint256 token2 = 5;
        address tokenAddr2 = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
        address feedAddr2 = 0xc59E3633BAAC79493d908e63626716e204A45EdF;

        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](2);
        // EURC -> USD
        tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: token1, tokenAddr: tokenAddr1, feedAddr: feedAddr1});
        // LINK -> USD
        tokenInitList[1] = NFTAuctionV1.TokenInitConfig({token: token2, tokenAddr: tokenAddr2, feedAddr: feedAddr2});

        vm.prank(seller1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", seller1));
        NFTAuctionV1(auctionSysProxyAddr).batchAddTokenCfg(tokenInitList);
    }

    // batchAddTokenCfg: 入参数组长度超过10 revert
    function test_batchAddTokenCfg_RevertIf_AllowedTokenSizeOver() public {
        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](11);
        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.AllowedTokenSizeOver.selector));
        NFTAuctionV1(auctionSysProxyAddr).batchAddTokenCfg(tokenInitList);
    }

    // batchAddTokenCfg: token配置已存在 revert
    function test_batchAddTokenCfg_RevertIf_TokenCfgExists() public {
        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](1);
        uint256 token1 = 0;
        address tokenAddr1 = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr1 = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;
        // EURC -> USD
        tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: token1, tokenAddr: tokenAddr1, feedAddr: feedAddr1});
        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenCfgExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).batchAddTokenCfg(tokenInitList);
    }

    // batchAddTokenCfg: tokenAddr已存在 revert
    function test_batchAddTokenCfg_RevertIf_TokenAddrExists() public {
        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](1);
        uint256 token1 = 3;
        address tokenAddr1 = address(0);
        address feedAddr1 = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;
        // EURC -> USD
        tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: token1, tokenAddr: tokenAddr1, feedAddr: feedAddr1});

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenAddrExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).batchAddTokenCfg(tokenInitList);
    }

    // batchAddTokenCfg: feedAddr已存在 revert
    function test_batchAddTokenCfg_RevertIf_FeedAddrExists() public {
        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](1);
        uint256 token1 = 3;
        address tokenAddr1 = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr1;

        if(isForkMode) {
            feedAddr1 = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        } else {
            feedAddr1 = address(mockEthUsdFeed);
        }

        // EURC -> USD
        tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: token1, tokenAddr: tokenAddr1, feedAddr: feedAddr1});

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.FeedAddrExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).batchAddTokenCfg(tokenInitList);
    }

    // batchAddTokenCfg: tokenAddr==address(0) revert
    function test_batchAddTokenCfg_InvalidTokenAddr() public {
        vm.prank(auctionSysOwner);
        NFTAuctionV1(auctionSysProxyAddr).updCfgTokenAddr(0, 0x779877A7B0D9E8603169DdbD7836e478b4624789);

        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](1);
        uint256 token1 = 3;
        address tokenAddr1 = address(0);
        address feedAddr1 = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;
        // EURC -> USD
        tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: token1, tokenAddr: tokenAddr1, feedAddr: feedAddr1});

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.InvalidTokenAddr.selector));
        NFTAuctionV1(auctionSysProxyAddr).batchAddTokenCfg(tokenInitList);
    }

    // batchAddTokenCfg: feedAddr==address(0) revert
    function test_batchAddTokenCfg_RevertIf_InvalidFeedAddr() public {
        NFTAuctionV1.TokenInitConfig[] memory tokenInitList = new NFTAuctionV1.TokenInitConfig[](1);
        uint256 token1 = 3;
        address tokenAddr1 = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr1 = address(0);
        // EURC -> USD
        tokenInitList[0] = NFTAuctionV1.TokenInitConfig({token: token1, tokenAddr: tokenAddr1, feedAddr: feedAddr1});

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.InvalidFeedAddr.selector));
        NFTAuctionV1(auctionSysProxyAddr).batchAddTokenCfg(tokenInitList);
    }

    // #endregion batchAddTokenCfg 测试结束============================================================

    // #region 添加新token配置 测试开始============================================================
    
    // addTokenCfg 测试成功场景
    function test_addTokenCfg_Success() public {
        // sepolia: EUR -> USD
        uint256 token = 3;
        address tokenAddr = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;        

        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenCount(), tokenCfgCount);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenIsExists(token), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token), address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token), address(0));

        vm.prank(auctionSysOwner);
        NFTAuctionV1(auctionSysProxyAddr).addTokenCfg(token, tokenAddr, feedAddr);

        // 验证
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenCount(), tokenCfgCount + 1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenIsExists(token), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token), tokenAddr);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token), feedAddr);
    }

    // addTokenCfg: 不是管理员调用 revert
    function test_addTokenCfg_RevertWhen_nonAdmin() public {
        // sepolia: EUR -> USD
        uint256 token = 3;
        address tokenAddr = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910; 

        vm.prank(seller1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", seller1));
        NFTAuctionV1(auctionSysProxyAddr).addTokenCfg(token, tokenAddr, feedAddr);
    }

    // addTokenCfg: tokenAddr==address(0) revert
    function test_addTokenCfg_RevertIf_InvalidTokenAddr() public {
        // sepolia: EUR -> USD
        uint256 token = 3;
        address feedAddr = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.InvalidTokenAddr.selector));
        NFTAuctionV1(auctionSysProxyAddr).addTokenCfg(token, address(0), feedAddr);
    }

    // addTokenCfg: feedAddr==address(0) revert
    function test_addTokenCfg_RevertIf_InvalidFeedAddr() public {
        // sepolia: EUR -> USD
        uint256 token = 3;
        address tokenAddr = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;        

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.InvalidFeedAddr.selector));
        NFTAuctionV1(auctionSysProxyAddr).addTokenCfg(token, tokenAddr, address(0));
    }

    // addTokenCfg: token 配置已存在
    function test_addTokenCfg_RevertIf_TokenCfgExists() public {
        uint256 token = 2;
        address tokenAddr = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910; 

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenCfgExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).addTokenCfg(token, tokenAddr, feedAddr);
    }

    // addTokenCfg: tokenAddr 已存在
    function test_addTokenCfg_RevertIf_TokenAddrExists() public {
        uint256 token = 3;
        address tokenAddr;
        address feedAddr = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;

        if(isForkMode) {
            tokenAddr = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        } else {
            tokenAddr = usdcAddr;
        }

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenAddrExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).addTokenCfg(token, tokenAddr, feedAddr);
    }

    // addTokenCfg: feedAddr 已存在
    function test_addTokenCfg_RevertIf_FeedAddrExists() public {
        uint256 token = 3;
        address tokenAddr = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        address feedAddr;

        if(isForkMode){            
            feedAddr = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E; 
        } else {
            feedAddr = address(mockUsdcUsdFeed);
        }        

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.FeedAddrExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).addTokenCfg(token, tokenAddr, feedAddr);
    }

    // #endregion 添加新token配置 测试结束============================================================

    // #region updCfgTokenAddr 测试开始============================================================

    // updCfgTokenAddr 测试成功场景
    function test_updCfgTokenAddr_Success() public {
        uint256 token = 1;
        address tokenAddr = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;

        address beforeTokenAddr = NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(beforeTokenAddr), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token), beforeTokenAddr);

        vm.prank(auctionSysOwner);
        NFTAuctionV1(auctionSysProxyAddr).updCfgTokenAddr(token, tokenAddr);

        address nowTokenAddr = NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token);
        assertEq(nowTokenAddr, tokenAddr);
        assertNotEq(beforeTokenAddr, nowTokenAddr);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(beforeTokenAddr), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token), tokenAddr);
    }

    // updCfgTokenAddr: 不是管理员调用 revert
    function test_updCfgTokenAddr_RevertWhen_nonAdmin() public {
        uint256 token = 1;
        address tokenAddr = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;

        vm.prank(seller1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", seller1));
        NFTAuctionV1(auctionSysProxyAddr).updCfgTokenAddr(token, tokenAddr);
    }    

    // updCfgTokenAddr: tokenAddr==address(0) revert
    function test_updCfgTokenAddr_RevertIf_InvalidTokenAddr() public {
        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.InvalidTokenAddr.selector));
        NFTAuctionV1(auctionSysProxyAddr).updCfgTokenAddr(1, address(0));
    }

    // updCfgTokenAddr: token配置不存在 revert
    function test_updCfgTokenAddr_RevertIf_TokenCfgNotExists() public {
        uint256 token = 3;
        address tokenAddr = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenCfgNotExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).updCfgTokenAddr(token, tokenAddr);
    }

    // updCfgTokenAddr: tokenAddr跟原先的一样 revert
    function test_updCfgTokenAddr_RevertIf_TokenAddrSameBefore() public {
        uint256 token = 1;
        address tokenAddr;

        if(isForkMode) {
            tokenAddr = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
        } else {
            tokenAddr = usdcAddr;
        }

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenAddrSameBefore.selector));
        NFTAuctionV1(auctionSysProxyAddr).updCfgTokenAddr(token, tokenAddr);
    }

    // updCfgTokenAddr: 别的token已存在tokenAddr revert
    function test_updCfgTokenAddr_RevertIf_TokenAddrExists() public {
        uint256 token = 1;
        address tokenAddr;

        if(isForkMode) {
            tokenAddr = 0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357;
        } else {
            tokenAddr = daiAddr;
        }

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenAddrExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).updCfgTokenAddr(token, tokenAddr);
    }    

    // #endregion updCfgTokenAddr 测试结束============================================================

    // #region updCfgFeedAddr 测试开始============================================================

    // updCfgFeedAddr 测试成功场景
    function test_updCfgFeedAddr_Success() public {
        uint256 token = 1;
        address feedAddr = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;

        address beforeFeedAddr = NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(beforeFeedAddr), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token), beforeFeedAddr);

        vm.prank(auctionSysOwner);
        NFTAuctionV1(auctionSysProxyAddr).updCfgFeedAddr(token, feedAddr);

        address nowFeedAddr = NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token);
        assertEq(nowFeedAddr, feedAddr);
        assertNotEq(beforeFeedAddr, nowFeedAddr);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(beforeFeedAddr), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token), feedAddr);
    }

    // updCfgFeedAddr: 不是管理员调用 revert
    function test_updCfgFeedAddr_RevertWhen_nonAdmin() public {
        uint256 token = 1;
        address feedAddr = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;

        vm.prank(seller1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", seller1));
        NFTAuctionV1(auctionSysProxyAddr).updCfgFeedAddr(token, feedAddr);
    }

    // updCfgFeedAddr: feedAddr==address(0) revert
    function test_updCfgFeddAddr_RevertIf_InvalidFeedAddr() public {
        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.InvalidFeedAddr.selector));
        NFTAuctionV1(auctionSysProxyAddr).updCfgFeedAddr(1, address(0));
    }

    // updCfgFeedAddr: token配置不存在 revert
    function test_updCfgFeedAddr_RevertIf_TokenCfgNotExists() public {
        uint256 token = 3;
        address feedAddr = 0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910;

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenCfgNotExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).updCfgTokenAddr(token, feedAddr);
    }

    // updCfgFeedAddr: feedAddr跟原先的一样 revert
    function test_updCfgFeedAddr_RevertIf_FeedAddrSameBefore() public {
        uint256 token = 1;
        address feedAddr;

        if(isForkMode) {
            feedAddr = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
        } else {
            feedAddr = address(mockUsdcUsdFeed);
        }
        
        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.FeedAddrSameBefore.selector));
        NFTAuctionV1(auctionSysProxyAddr).updCfgFeedAddr(token, feedAddr);
    }

    // updCfgFeedAddr: 别的token已存在feedAddr revert
    function test_updCfgFeedAddr_RevertIf_FeedAddrExists() public {
        uint256 token = 1;
        address feedAddr;

        if(isForkMode) {
            feedAddr = 0x14866185B1962B63C3Ea9E03Bc1da838bab34C19;
        } else {
            feedAddr = address(mockDaiUsdFeed);
        }

        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.FeedAddrExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).updCfgFeedAddr(token, feedAddr);
    }

    // #endregion updCfgFeedAddr 测试结束============================================================

    // #region delTokenCfg 测试开始============================================================
    // delTokenCfg 测试成功场景
    function test_delTokenCfg_Success() public {
        uint256 token = 1;        
        
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenIsExists(token), true);
        address tokenAddr = NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token);
        address feedAddr = NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token);
        assertNotEq(tokenAddr, address(0));
        assertNotEq(feedAddr, address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr), true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenCount(), tokenCfgCount);
        
        vm.prank(auctionSysOwner);
        NFTAuctionV1(auctionSysProxyAddr).delTokenCfg(token);

        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenIsExists(token), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddrIsExists(tokenAddr), false);        
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddrIsExists(feedAddr), false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenAddr(token), address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getFeedAddr(token), address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getTokenCount(), tokenCfgCount - 1);
    }

    // delTokenCfg: 不是管理员调用 revert
    function test_delTokenCfg_RevertWhen_nonAdmin() public {
        vm.prank(seller1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", seller1));
        NFTAuctionV1(auctionSysProxyAddr).delTokenCfg(1);
    }

    // delTokenCfg: token 配置不存在 revert
    function test_delTokenCfg_RevertIf_TokenCfgNotExists() public {
        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.TokenCfgNotExists.selector));
        NFTAuctionV1(auctionSysProxyAddr).delTokenCfg(3);
    }

    // #endregion delTokenCfg 测试结束============================================================
    
    // #region 创建拍卖 测试开始============================================================
    // createAuction 测试成功场景1：allowedTokens ETH和代币全有 & NFT第一次创建拍卖
    function test_createAuction_Success1() public {      
        uint256[] memory allowedTokens = new uint256[](3);
        allowedTokens[0] = 0;
        allowedTokens[1] = 1;
        allowedTokens[2] = 2;
        address nftContract;
        address caller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            caller = sepoliaNFT1Owner;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            caller = seller1;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }

        NFTAuctionV1.CreateAuctionParams memory params = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens
        });

        uint256 endTime = params.startTime + (params.durationHours * 1 hours);

        NFTAuctionV1.FeedResult memory feedRt = NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(0, params.startPrice);

        // check emit AuctionCreated
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionCreated(
            AUCTION_ID_1, caller, nftContract, APPLENFT_TOKENID_1, feedRt.usd18Value, params.startTime, endTime, true, allowedTokens, feedRt.decimals, params.startPrice 
        );
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(params);

        // check 函数返回的值
        assertEq(auctionId, AUCTION_ID_1);

        // check storage auctionId
        assertEq(getStorageAuctionId(), AUCTION_ID_1);

        // check storage ntfToken2AuctionId
        assertEq(getStorageNtfToken2AuctionId(nftContract, APPLENFT_TOKENID_1), AUCTION_ID_1);

        // check storage auctionCount
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // check Storage AuctionInfo
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.auctionId, AUCTION_ID_1);
        assertEq(info.tokenId, APPLENFT_TOKENID_1);
        assertEq(info.startPrice, feedRt.usd18Value);
        assertEq(info.startTime, params.startTime);
        assertEq(info.durationHours, params.durationHours);
        assertEq(info.endTime, endTime);
        assertEq(info.currHighestPrice, feedRt.usd18Value);
        assertEq(info.highestBidder, address(0));
        assertEq(info.nftContract, nftContract);
        assertEq(info.seller, caller);
        assertEq(info.isCreated, true);
        assertEq(info.isEnded, false);
        assertEq(info.isToken, true);
        assertEq(info.allowedTokens, allowedTokens);
        assertEq(info.highestBidToken, 0);
        assertEq(info.currHighestTokenAmount, params.startPrice);
        assertEq(info.currHighestDecimals, feedRt.decimals);

        vm.stopPrank();
    }

    // createAuction 测试成功场景2：allowedTokens ETH和代币全有 & 此NFT取消拍卖后再次创建拍卖
    function test_createAuction_Success2() public {
        uint256[] memory allowedTokens = new uint256[](3);
        allowedTokens[0] = 0;
        allowedTokens[1] = 1;
        allowedTokens[2] = 2;
        address nftContract;
        
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }

        // 1. 对 APPLENFT_TOKENID_1 创建拍卖 1        
        NFTAuctionV1.CreateAuctionParams memory params1 = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens
        });
        uint256 auctionId1 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params1);
        assertEq(auctionId1, 1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // 2. 对 APPLENFT_TOKENID_2 创建拍卖 2
        NFTAuctionV1.CreateAuctionParams memory params2 = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_2,
            startPrice: 2, 
            startTime: currTs + 2 minutes, 
            durationHours: 26, 
            allowedTokens: allowedTokens
        });
        uint256 auctionId2 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params2); 
        assertEq(auctionId2, 2);       
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 2);                

        // 3. 对拍卖 1 取消拍卖
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // 4. 对拍卖 1 再次创建拍卖
        uint256 auctionId12 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params1);

        // 5. 验证
        assertEq(auctionId1, auctionId12);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 2); 

        vm.stopPrank();       
    }

    // createAuction 测试成功场景3：allowedTokens仅ETH & NFT第一次创建拍卖
    function test_createAuction_Success3() public {     
        uint256[] memory allowedTokens = new uint256[](1);
        allowedTokens[0] = 0;
        address nftContract;
        address caller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            caller = sepoliaNFT1Owner;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            caller = seller1;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }

        NFTAuctionV1.CreateAuctionParams memory params = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens
        });

        uint256 endTime = params.startTime + (params.durationHours * 1 hours);
        
        // check emit AuctionCreated
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionCreated(
            AUCTION_ID_1, caller, nftContract, APPLENFT_TOKENID_1, params.startPrice, params.startTime, endTime, false, allowedTokens, 18, params.startPrice 
        );
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(params);

        // check 函数返回的值
        assertEq(auctionId, AUCTION_ID_1);

        // check storage auctionId
        assertEq(getStorageAuctionId(), AUCTION_ID_1);

        // check storage ntfToken2AuctionId
        assertEq(getStorageNtfToken2AuctionId(nftContract, APPLENFT_TOKENID_1), AUCTION_ID_1);

        // check storage auctionCount
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // check Storage AuctionInfo
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.auctionId, AUCTION_ID_1);
        assertEq(info.tokenId, APPLENFT_TOKENID_1);
        assertEq(info.startPrice, params.startPrice);
        assertEq(info.startTime, params.startTime);
        assertEq(info.durationHours, params.durationHours);
        assertEq(info.endTime, endTime);
        assertEq(info.currHighestPrice, params.startPrice);
        assertEq(info.highestBidder, address(0));
        assertEq(info.nftContract, nftContract);
        assertEq(info.seller, caller);
        assertEq(info.isCreated, true);
        assertEq(info.isEnded, false);
        assertEq(info.isToken, false);
        assertEq(info.allowedTokens, allowedTokens);
        assertEq(info.highestBidToken, 0);
        assertEq(info.currHighestTokenAmount, params.startPrice);
        assertEq(info.currHighestDecimals, 18);

        vm.stopPrank();
    }

    // createAuction 测试成功场景4：allowedTokens仅ETH & 此NFT取消拍卖后再次创建拍卖
    function test_createAuction_Success4() public {
        uint256[] memory allowedTokens = new uint256[](1);
        allowedTokens[0] = 0;        
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }

        // 1. 对 APPLENFT_TOKENID_1 创建拍卖 1        
        NFTAuctionV1.CreateAuctionParams memory params1 = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens
        });
        uint256 auctionId1 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params1);
        assertEq(auctionId1, 1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // 2. 对 APPLENFT_TOKENID_2 创建拍卖 2
        NFTAuctionV1.CreateAuctionParams memory params2 = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_2,
            startPrice: 2, 
            startTime: currTs + 2 minutes, 
            durationHours: 26, 
            allowedTokens: allowedTokens
        });
        uint256 auctionId2 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params2); 
        assertEq(auctionId2, 2);       
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 2);                

        // 3. 对拍卖 1 取消拍卖
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // 4. 对拍卖 1 再次创建拍卖
        uint256 auctionId12 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params1);

        // 5. 验证
        assertEq(auctionId1, auctionId12);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 2); 

        vm.stopPrank(); 
    }

    // createAuction 测试成功场景5：allowedTokens空 & NFT第一次创建拍卖
    function test_createAuction_Success5() public {
        uint256[] memory allowedTokens;
        address nftContract;
        address caller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            caller = sepoliaNFT1Owner;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            caller = seller1;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }          

        NFTAuctionV1.CreateAuctionParams memory params = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens
        });

        uint256 endTime = params.startTime + (params.durationHours * 1 hours);
        
        // check emit AuctionCreated
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionCreated(
            AUCTION_ID_1, caller, nftContract, APPLENFT_TOKENID_1, params.startPrice, params.startTime, endTime, false, allowedTokens, 18, params.startPrice 
        );
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(params);

        // check 函数返回的值
        assertEq(auctionId, AUCTION_ID_1);

        // check storage auctionId
        assertEq(getStorageAuctionId(), AUCTION_ID_1);

        // check storage ntfToken2AuctionId
        assertEq(getStorageNtfToken2AuctionId(nftContract, APPLENFT_TOKENID_1), AUCTION_ID_1);

        // check storage auctionCount
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // check Storage AuctionInfo
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.auctionId, AUCTION_ID_1);
        assertEq(info.tokenId, APPLENFT_TOKENID_1);
        assertEq(info.startPrice, params.startPrice);
        assertEq(info.startTime, params.startTime);
        assertEq(info.durationHours, params.durationHours);
        assertEq(info.endTime, endTime);
        assertEq(info.currHighestPrice, params.startPrice);
        assertEq(info.highestBidder, address(0));
        assertEq(info.nftContract, nftContract);
        assertEq(info.seller, caller);
        assertEq(info.isCreated, true);
        assertEq(info.isEnded, false);
        assertEq(info.isToken, false);
        assertEq(info.allowedTokens, allowedTokens);
        assertEq(info.highestBidToken, 0);
        assertEq(info.currHighestTokenAmount, params.startPrice);
        assertEq(info.currHighestDecimals, 18);

        vm.stopPrank();
    }
    

    // createAuction 测试成功场景6：allowedTokens空 & 此NFT取消拍卖后再次创建拍卖
    function test_createAuction_Success6() public {
        uint256[] memory allowedTokens;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }

        // 1. 对 APPLENFT_TOKENID_1 创建拍卖 1        
        NFTAuctionV1.CreateAuctionParams memory params1 = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens
        });
        uint256 auctionId1 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params1);
        assertEq(auctionId1, 1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // 2. 对 APPLENFT_TOKENID_2 创建拍卖 2
        NFTAuctionV1.CreateAuctionParams memory params2 = NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_2,
            startPrice: 2, 
            startTime: currTs + 2 minutes, 
            durationHours: 26, 
            allowedTokens: allowedTokens
        });
        uint256 auctionId2 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params2); 
        assertEq(auctionId2, 2);       
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 2);                

        // 3. 对拍卖 1 取消拍卖
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);

        // 4. 对拍卖 1 再次创建拍卖
        uint256 auctionId12 = NFTAuctionV1(auctionSysProxyAddr).createAuction(params1);

        // 5. 验证
        assertEq(auctionId1, auctionId12);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 2); 

        vm.stopPrank(); 
    }

    // createAuction测试场景：待创建拍卖的开始价格不大于0 revert
    // src/NFTAuctionV1.sol:119，startPrice > 0 → startPrice != 0，startPrice 为 uint256，值域无负数，属于等价突变，不存在安全风险，接受存活。
    function test_createAuction_RevertIf_StartPriceZero() public {
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
        } else {
            nftContract = appleNftAddr;
        }

        vm.expectRevert(abi.encodeWithSignature("StartPriceMustGtZero()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 0, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: _createAllowedTokens()
        }));        
    }

    // createAuction测试场景：待创建拍卖的allowedTokens长度超过token配置 revert
    function test_createAuction_RevertIf_AllowedTokenSizeOver() public {
        uint256[] memory allowedTokens = new uint256[](4);
        allowedTokens[0] = 0;
        allowedTokens[1] = 1;
        allowedTokens[2] = 2;
        allowedTokens[3] = 3;

        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
        } else {
            nftContract = appleNftAddr;
        }

        vm.expectRevert(abi.encodeWithSignature("AllowedTokenSizeOver()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 10, 
            allowedTokens: allowedTokens
        }));
    }

    // createAuction测试场景：待创建拍卖的持续时间小于24 revert
    function test_createAuction_RevertIf_DurationHoursLe24() public {
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
        } else {
            nftContract = appleNftAddr;
        }

        vm.expectRevert(abi.encodeWithSignature("DurationHoursOutOfRange()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 10, 
            allowedTokens: _createAllowedTokens()
        }));
    }

    // durationHours边界：大于24，例如 25 success
    function test_createAuction_DurationHours25() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        // 预期：成功创建，不revert
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 25, 
            allowedTokens: allowedTokens 
        }));
        vm.stopPrank();
    }

    // src/NFTAuctionV1.sol:121,durationHours >= 24 && durationHours <= 168 → durationHours >= 24 == durationHours <= 168 属于等价突变，不存在安全风险，接受存活。
    // createAuction测试场景：待创建拍卖的持续时间等于168 success
    function test_createAuction_DurationHours168() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        // 预期：成功创建，不revert
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 168, 
            allowedTokens: allowedTokens 
        }));
        vm.stopPrank();
    }

    // createAuction测试场景：待创建拍卖的持续时间大于168 revert
    function test_createAuction_RevertIf_DurationHoursGe168() public {
        uint256[] memory allowedTokens;
        uint256 invalidDurationHours = 24440054405305269366569402256811496959409073762505157381672968839269610695612;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
        } else {
            nftContract = appleNftAddr;
        }
        
        vm.expectRevert(abi.encodeWithSignature("DurationHoursOutOfRange()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: invalidDurationHours, 
            allowedTokens: allowedTokens 
        }));
    }

    // createAuction测试场景：待创建拍卖的开始时间等于当前时间 revert
    function test_createAuction_RevertIf_StartTimeEqCurr() public {
        uint256[] memory allowedTokens;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;       
        } else {
            nftContract = appleNftAddr;
        }

        vm.expectRevert(abi.encodeWithSignature("StartTimeMustGtCurrTime()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: block.timestamp, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
    }

    // createAuction测试场景：待创建拍卖的开始时间小于当前时间 revert
    function test_createAuction_RevertIf_StartTimeLeCurr() public {
        uint256[] memory allowedTokens;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;       
        } else {
            nftContract = appleNftAddr;
        }

        vm.expectRevert(abi.encodeWithSignature("StartTimeMustGtCurrTime()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: 0, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
    }

    // createAuction测试场景：待创建拍卖的开始时间等于_currTs + 1 weeks success
    // (currTs ∣ 1 weeks) ≤ (currTs + 1 weeks), 同时测试突变 currTs + 1 weeks -> currTs ∣ 1 weeks
    // (currTs ^ 1 weeks) ≤ (currTs + 1 weeks), 同时测试突变 currTs + 1 weeks -> currTs ^ 1 weeks
    function test_createAuction_StartTimeEqCurrTsAdd1Weeks() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);    
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            // seller1授权appleNFT到拍卖合约
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
      
        skip(1 hours);
        // 预期：成功创建，不revert
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: block.timestamp + 1 weeks, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
        vm.stopPrank();
    }

    // createAuction测试场景：待创建拍卖的开始时间(currTs * 1 weeks)超过允许的最大时间 revert
    function test_createAuction_RevertIf_StartTimeEqCurrTsMult1Weeks() public {
        uint256[] memory allowedTokens;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;       
        } else {
            nftContract = appleNftAddr;
        }

        skip(1 hours);
        uint256 invalidStartTime = block.timestamp * 1 weeks;
        vm.expectRevert(abi.encodeWithSignature("StartTimeOverMaxValue()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: invalidStartTime, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
    }

    // createAuction测试场景：待创建拍卖的开始时间超过允许的最大时间 revert
    function test_createAuction_RevertIf_StartTimeOverMaxValue() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 invalidStartTime = 115792089237316195423570985008687907853269984665640564039457584007913129639905;
        
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;       
        } else {
            nftContract = appleNftAddr;
        }
        
        vm.expectRevert(abi.encodeWithSignature("StartTimeOverMaxValue()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: invalidStartTime, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
    }

    // createAuction测试场景：待创建拍卖的NFT所在的合约地址为address(0) revert
    function test_createAuction_RevertIf_NftAddrZero() public {
        uint256[] memory allowedTokens;
        vm.expectRevert(abi.encodeWithSignature("InvalidNftContractAddr()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: address(0), 
            tokenId: APPLENFT_TOKENID_1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
    }    

    // createAuction测试场景：NFT不存在 revert
    function test_createAuction_RevertIf_NftNonExist() public {
        uint256[] memory allowedTokens;
        uint256 nonExistTokenId = 9999999;
        address nftContract;        

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
            vm.expectRevert("ERC721: owner query for nonexistent token");
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
            vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", nonExistTokenId));
        }
        
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: nonExistTokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));

        vm.stopPrank();
    }

    // createAuction测试场景：创建拍卖者不是该NFT的持有者 revert
    // kill mutate: msg.sender == nft.ownerOf(tokenId) -> msg.sender >= nft.ownerOf(tokenId)
    function test_createAuction_RevertIf_NotNftOwner1() public {
        uint256[] memory allowedTokens;
        address caller;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            caller = usdcBidder;
            vm.prank(usdcBidder);
        } else {
            nftContract = appleNftAddr;
            caller = makeAddr("seller2");
            vm.prank(caller);
        }
        
        vm.expectRevert(abi.encodeWithSignature("NotNftOwner(address)", caller));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
    }

    // createAuction测试场景：创建拍卖者不是该NFT的持有者 revert
    // kill mutate: msg.sender == nft.ownerOf(tokenId) -> msg.sender <= nft.ownerOf(tokenId)
    function test_createAuction_RevertIf_NotNftOwner2() public {
        uint256[] memory allowedTokens;
        address caller;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            caller = daiBidder;
            vm.prank(daiBidder);
        } else {
            nftContract = appleNftAddr;
            caller = address(this);
            vm.prank(caller);
        }

        vm.expectRevert(abi.encodeWithSignature("NotNftOwner(address)", caller));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
    }

    // createAuction测试场景：待创建拍卖的NFT没有授权给任何合约
    function test_createAuction_RevertIf_NftNotApprove() public {
        uint256[] memory allowedTokens;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.prank(sepoliaNFT1Owner);
        } else {
            nftContract = appleNftAddr;
            vm.prank(seller1);
        }
        
        vm.expectRevert(abi.encodeWithSignature("NftNotApproved()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: 1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
    }

    // createAuction测试场景：seller1的appleNft已授权，只是不是授权给auctionSysProxyAddr，而且地址大于auctionSysProxyAddr
    // kill mutate: address(this) == nft.getApproved(tokenId) -> address(this) <= nft.getApproved(tokenId)
    function test_createAuction_RevertIf_ApproveAddrGtProxyAddr() public {
        uint256[] memory allowedTokens;
        // 构造一个大于auctionSysProxyAddr的地址
        address testAddr = address(uint160(auctionSysProxyAddr) + uint160(1));

        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(testAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(testAddr, tokenId);
        }

        vm.expectRevert(abi.encodeWithSignature("NftNotApproved()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
        vm.stopPrank();
    }

    // createAuction测试场景：seller1持有者approve和approvedForAll同时都授权给此合约 success
    // kill mutate: address(this) == nft.getApproved(tokenId) || nft.isApprovedForAll(msg.sender, address(this)) -> address(this) == nft.getApproved(tokenId) != nft.isApprovedForAll(msg.sender, address(this))
    function test_createAuction_ApproveSingleAndAll() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }
        
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
        vm.stopPrank();
    }

    // createAuction测试场景：无效的Token revert
    function test_createAuction_RevertIf_InvalidAllowedToken() public {
        uint256[] memory allowedTokens = new uint256[](1);
        allowedTokens[0] = 6;

        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }       

        // 对指定NFT创建拍卖
        vm.expectRevert(abi.encodeWithSignature("InvalidAllowedToken(uint256)", allowedTokens[0]));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));

        vm.stopPrank();
    }

    // // src/NFTAuctionV1.sol:132, nftContract != address(0) → nftContract > address(0) 属于等价突变，不存在安全风险，接受存活。
    // // src/NFTAuctionV1.sol:136, $.ntfToken2AuctionId[nftContract][tokenId] == 0 → $.ntfToken2AuctionId[nftContract][tokenId] <= 0 属于等价突变，不存在安全风险，接受存活。

    // createAuction测试场景：创建已经创建拍卖的NFT revert
    function test_createAuction_RevertIf_NftCreated() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        // 第一次对指定NFT创建拍卖
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));

        // 再次对指定NFT创建拍卖
        vm.expectRevert(abi.encodeWithSignature("AuctionAlreadyExists(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));

        vm.stopPrank();
    }

    // createAuction测试场景：待创建拍卖的结束时间必须等于startTime + (durationHours * 1 hours)
    // startTime | (durationHours * 1 hours) ≤ startTime + (durationHours * 1 hours), 同时测试突变 startTime + (durationHours * 1 hours) -> startTime | (durationHours * 1 hours)
    // startTime ^ (durationHours * 1 hours) ≤ startTime + (durationHours * 1 hours), 同时测试突变 startTime + (durationHours * 1 hours) -> startTime ^ (durationHours * 1 hours)
    function test_createAuction_EndTime() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 27, 
            allowedTokens: allowedTokens 
        }));
        vm.stopPrank();
        // 验证结束时间
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.endTime, currTs + 1 minutes + 27 hours);
    }

    // 用来复现testFuzz_createAuction报错的
    // function test_createAuction_singleFuzz() public {
    //     vm.startPrank(seller1);
    //     appleNft.setApprovalForAll(auctionSysProxyAddr, true);
    //     address nftContract = appleNftAddr;
    //     uint256 tokenId = 1;
    //     uint256 startPrice = 2;
    //     uint256 startTime = 115792089237316195423570985008687907853269984665640564039457584007913129639905;
    //     uint256 durationHours = 24;

    //     uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(nftContract, tokenId, startPrice, startTime, durationHours);
    //     console.log(auctionId);
    // }

    // createAuction无状态模糊测试
    function testFuzz_createAuction(uint256 tokenId, uint256 startPrice, uint256 startTime, uint256 durationHours, uint256[] calldata allowedTokens)
        public
    {
        address nftContract;
        address caller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            caller = sepoliaNFT1Owner;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            caller = seller1;
            vm.startPrank(seller1);            
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }

        try NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: startPrice, 
            startTime: startTime, 
            durationHours: durationHours, 
            allowedTokens: allowedTokens 
        })) returns (
            uint256 auctionId
        ) {
            console.log(auctionId);
        } catch (bytes memory revertData) {
            bool isExpectedRevert =
                (
                    // 开始价格报错
                    keccak256(revertData) == keccak256(abi.encodeWithSignature("StartPriceMustGtZero()"))
                    // allowedTokens长度不能超过可允许的token配置的最大长度
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("AllowedTokenSizeOver()"))
                    // 持续时间报错
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("DurationHoursOutOfRange()"))
                    // 开始时间小于当前时间报错
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("StartTimeMustGtCurrTime()"))
                    // 开始时间超过允许值报错
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("StartTimeOverMaxValue()"))
                    // nftContract零地址报错
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("InvalidNftContractAddr()"))
                    // 相同NFT重复创建拍卖报错
                    //|| keccak256(revertData) == keccak256(abi.encodeWithSignature("AuctionAlreadyExists(uint256)", auctionId))
                    // 不存在tokenId报错
                    || keccak256(revertData)
                        == keccak256(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", tokenId))
                    // tokenId所有者报错
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("NotNftOwner(address)", caller))
                    // nft未授权给此拍卖合约报错
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("NftNotApproved()"))
                    // 无效的允许token
                    || _isInvalidAllowedToken(revertData, allowedTokens)
            );
            assertTrue(isExpectedRevert, "Debug!");
        }

        vm.stopPrank();
    }    

    // // #endregion 创建拍卖 测试结束===================================================

    // #region 取消拍卖 测试开始==================================================
    // cancelAuction 测试成功场景
    function test_cancelAuction_Success() public {
        uint256[] memory allowedTokens;
        address nftContract;
        address caller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            caller = sepoliaNFT1Owner;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            caller = seller1;
            vm.startPrank(seller1);            
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }

        // 创建拍卖       
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: APPLENFT_TOKENID_1,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));

        NFTAuctionV1.AuctionInfo memory infoBf = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(infoBf.isCreated, true);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 1);
        
        // 验证emit
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionCancel(auctionId, caller);
        // 取消拍卖
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);

        vm.stopPrank();

        // 验证值改变
        NFTAuctionV1.AuctionInfo memory infoAf = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(infoAf.isCreated, false);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getAuctionCount(), 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(sepoliaNFT1Owner.balance, sepoliaNFT1OwnerInitBalance);
    }

    // cancelAuction测试场景：拍卖没有创建 revert
    function test_cancelAuction_RevertIf_AuctionNotExists() public {
        uint256 auctionId = 2;
        vm.expectRevert(abi.encodeWithSignature("AuctionNotExists(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);
    }

    // cancelAuction测试场景：取消拍卖的当前时间大于开始时间 revert
    function test_cancelAuction_RevertIf_GtStartTime() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);            
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        // 创建拍卖        
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 minutes, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));

        // 快进2个小时
        skip(2 hours);
        vm.expectRevert(abi.encodeWithSignature("AuctionAlreadyStarted(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);

        vm.stopPrank();
    }

    // cancelAuction测试场景：取消拍卖的当前时间等于开始时间 revert
    // kill mutate: block.timestamp < auction.startTime -> block.timestamp <= auction.startTime
    function test_cancelAuction_RevertIf_EqStartTime() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);            
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        // 创建拍卖       
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 hours, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));

        // 快进1个小时
        skip(1 hours);
        vm.expectRevert(abi.encodeWithSignature("AuctionAlreadyStarted(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);

        vm.stopPrank();
    }

    // cancelAuction测试场景：调用者不是卖家 revert
    function test_cancelAuction_RevertIf_NotSeller1() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);            
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        // 创建拍卖        
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 1, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
        }));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSignature("NotAuctionSeller(address)", address(this)));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);
    }

    // cancelAuction测试场景：调用者不是卖家 revert
    // kill mutate: auction.seller == msg.sender -> auction.seller <= msg.sender
    function test_cancelAuction_RevertIf_NotSeller2() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);            
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

       // 创建拍卖
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
            nftContract: nftContract, 
            tokenId: tokenId,
            startPrice: 1, 
            startTime: currTs + 1 hours, 
            durationHours: 24, 
            allowedTokens: allowedTokens 
        }));
        vm.stopPrank();

        address seller2 = makeAddr("seller2");
        vm.prank(seller2);
        vm.expectRevert(abi.encodeWithSignature("NotAuctionSeller(address)", seller2));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);
    }

    // #endregion 取消拍卖 测试结束===============================================

    // #region 各种代币转成对应的USD价格 测试结束===============================================
    
    struct GetUsdCase {
        uint256 tokenType;
        uint256 amount;
        int256 mockRawPrice;
        uint8 tokenDecimals;        
    }

    function fixtureCases() public pure returns (GetUsdCase[] memory){
        GetUsdCase[] memory arr = new GetUsdCase[](3);
        arr[0] = GetUsdCase({
            tokenType: 0,
            amount: 1 ether,
            mockRawPrice: ETH_USD_FEED,
            tokenDecimals: 18
        });
        arr[1] = GetUsdCase({
            tokenType: 1,
            amount: 1,
            mockRawPrice: USDC_USD_FEED,
            tokenDecimals: 6
        });
        arr[2] = GetUsdCase({
            tokenType: 2,
            amount: 1,
            mockRawPrice: DAI_USD_FEED,
            tokenDecimals: 18
        });
        return arr;
    }

    // table开头，参数名 cases，对应 fixtureCases
    // getUSDByToken 测试成功场景1：ETH
    // getUSDByToken 测试成功场景2：USDC
    // getUSDByToken 测试成功场景3：DAI
    function tableGetUSDByToken(GetUsdCase memory cases) public {
        NFTAuctionV1.FeedResult memory feedRt = NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(cases.tokenType, cases.amount);        
                
        if(isForkMode){
            assertGt(feedRt.rawPrice, 0);
            assertGt(feedRt.updateTime, 0);
            assertEq(feedRt.usd18Value, (cases.amount * uint256(feedRt.rawPrice) * 10 ** 8) / ((10 ** uint256(cases.tokenDecimals)) * (10 ** 8)));
        } else {
            assertEq(feedRt.rawPrice, cases.mockRawPrice);
            assertEq(feedRt.usd18Value, (cases.amount * uint256(cases.mockRawPrice) * 10 ** 8) / ((10 ** uint256(cases.tokenDecimals)) * (10 ** 8)));
            assertEq(feedRt.updateTime, block.timestamp);
        }

        assertEq(feedRt.tokenDecimals, cases.tokenDecimals);
        assertEq(feedRt.feedDecimals, 8);
        assertEq(feedRt.decimals, 8);
    }    

    // getUSDByToken 测试场景：feedAddr==address(0) revert
    function test_getUSDByToken_RevertIf_InvalidFeedAddr() public {
        vm.expectRevert(NFTAuctionV1.InvalidFeedAddr.selector);
        NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(10, 1);
    }

    // // getUSDByToken 测试场景：tokenAddr==address(0) revert
    // function test_getUSDByToken_RevertIf_InvalidTokenAddr() public {
        
    //     vm.expectRevert(NFTAuctionV1.InvalidTokenAddr.selector);
    //     NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(1, 1);
    // }

    // #endregion 各种代币转成对应的USD价格 测试结束===============================================

    // #region 拍卖出价 测试开始==================================================
    // bidAuction 测试成功场景1：仅能ETH出价 创建拍卖 -> 验证值 -> bidder1出价 -> 验证值 -> bidder1再此出价 -> 验证值 -> bidder2出价 -> 验证值
    function test_bidAuction_Success1() public {
        uint256[] memory allowedTokens;
        address nftContract;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);            
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }

        // 创建拍卖       
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: APPLENFT_TOKENID_1,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();
        // 初始值
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.currHighestPrice, 0.01 ether);
        assertEq(info.highestBidder, address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);

        // 时间快进2小时
        skip(2 hours);

        // bidder1出价
        uint256 _bidVal1 = 1.5 ether;
        _bid(auctionId, bidder1, _bidVal1, 0, _bidVal1, 18);

        // 验证
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);       
        assertEq(info1.currHighestPrice, _bidVal1);
        assertEq(info1.highestBidder, bidder1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidVal1);
        assertEq(bidder1.balance, bidder1InitBalance - _bidVal1);
        // kill mutate: auction.highestBidder != address(0) -> auction.highestBidder >= address(0)
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, address(0), 0), 0);

        // bidder1再次出价
        uint256 _bidVal12 = 1.8 ether;
        _bid(auctionId, bidder1, _bidVal12, 0, _bidVal12, 18);

        // 验证
        NFTAuctionV1.AuctionInfo memory info12 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);        
        assertEq(info12.currHighestPrice, _bidVal12);
        assertEq(info12.highestBidder, bidder1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), _bidVal1);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidVal1 + _bidVal12);
        assertEq(bidder1.balance, bidder1InitBalance - _bidVal1 - _bidVal12);

        // bidder2出价
        uint256 _bidVal2 = 2 ether;
        _bid(auctionId, bidder2, _bidVal2, 0, _bidVal2, 18);

        // 验证
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);        
        assertEq(info2.currHighestPrice, _bidVal2);
        assertEq(info2.highestBidder, bidder2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), _bidVal1 + _bidVal12);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidVal1 + _bidVal12 + _bidVal2);
        assertEq(bidder2.balance, bidder2InitBalance - _bidVal2);
    }

    // bidAuction 测试成功场景2：可ETH和其他代币出价 创建拍卖 -> 验证值 -> bidder1出价 -> 验证值 -> bidder1再此出价 -> 验证值 -> bidder2出价 -> 验证值
    function test_bidAuction_Success2() public {
        address nftContract;
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).setApprovalForAll(auctionSysProxyAddr, true);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);            
            appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        }
        // 创建拍卖        
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: APPLENFT_TOKENID_1,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens() 
            }));
        vm.stopPrank();
        // 初始值
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        NFTAuctionV1.FeedResult memory feedRt0 = NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(0, 0.01 ether);
        assertEq(info.currHighestPrice, feedRt0.usd18Value);
        assertEq(info.highestBidder, address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, usdcBidder, 1), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);

        // 时间快进2小时
        skip(2 hours);

        // daiBidder出价
        uint256 _bidVal1 = 50 * 10 ** 18;        
        vm.prank(daiBidder);        
        IERC20(daiAddr).approve(auctionSysProxyAddr, _bidVal1);
        NFTAuctionV1.FeedResult memory feedRt1 = NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(2, _bidVal1);        
        _bid(auctionId, daiBidder, feedRt1.usd18Value, 2, _bidVal1, feedRt1.decimals);

        // 验证
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);       
        assertEq(info1.currHighestPrice, feedRt1.usd18Value);
        assertEq(info1.highestBidder, daiBidder);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, usdcBidder, 1), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(IERC20(daiAddr).balanceOf(daiBidder), daiBidderInitBalance - _bidVal1);
        assertEq(IERC20(daiAddr).balanceOf(auctionSysProxyAddr), _bidVal1);
        // kill mutate: auction.highestBidder != address(0) -> auction.highestBidder >= address(0)
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, address(0), 0), 0);

        // usdcBidder出价
        uint256 _bidVal12 = 58 * 10 ** 6;
        vm.prank(usdcBidder);        
        IERC20(usdcAddr).approve(auctionSysProxyAddr, _bidVal12);
        NFTAuctionV1.FeedResult memory feedRt12 = NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(1, _bidVal12);        
        _bid(auctionId, usdcBidder, feedRt12.usd18Value, 1, _bidVal12, feedRt12.decimals);

        // 验证
        NFTAuctionV1.AuctionInfo memory info12 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);        
        assertEq(info12.currHighestPrice, feedRt12.usd18Value);
        assertEq(info12.highestBidder, usdcBidder);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), _bidVal1);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(IERC20(usdcAddr).balanceOf(auctionSysProxyAddr), _bidVal12);
        assertEq(IERC20(usdcAddr).balanceOf(usdcBidder), usdcBidderInitBalance - _bidVal12);

        // bidder2出价
        uint256 _bidVal2 = 1 ether;
        NFTAuctionV1.FeedResult memory feedRt2 = NFTAuctionV1(auctionSysProxyAddr).getUSDByToken(0, _bidVal2);
        _bid(auctionId, bidder2, feedRt2.usd18Value, 0, _bidVal2, feedRt2.decimals);

        // 验证
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);        
        assertEq(info2.currHighestPrice, feedRt2.usd18Value);
        assertEq(info2.highestBidder, bidder2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), _bidVal1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, usdcBidder, 1), _bidVal12);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidVal2);
        assertEq(bidder2.balance, bidder2InitBalance - _bidVal2);
    }

    // src/NFTAuctionV1.sol:220, auction.highestBidder != address(0) -> auction.highestBidder > address(0), 等价突变，可忽略

    // bidAuction测试场景：没有此拍卖 revert
    function test_bidAuction_RevertIf_NonAuction() public {
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionNotExists(uint256)", 1));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(1, 0, 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：出价者是卖方 revert
    function test_bidAuction_RevertWhen_sellerBid() public {       
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;            
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        // 创建拍卖
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));

        // 测试
        vm.expectRevert(abi.encodeWithSignature("SellerCannotBid()"));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(auctionId, 0, 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(sepoliaNFT1Owner.balance, sepoliaNFT1OwnerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);

        vm.stopPrank();
    }

    // bidAuction测试场景：当前时间小于拍卖开始时间 revert
    function test_bidAuction_RevertIf_CurrTimeLeStartTime() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionNotStarted(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(auctionId, 0, 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：当前时间等于拍卖开始时间 success
    function test_bidAuction_RevertIf_CurrTimeEqStartTime() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        skip(1 hours);

        uint256 _bidder1Value = 1.5 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId, 0, 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
    }

    // bidAuction测试场景：当前时间大于拍卖结束时间 revert
    function test_bidAuction_RevertIf_CurrTimeGtEndTime() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        skip(26 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionExpired(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(auctionId, 0, 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：当前时间等于拍卖结束时间 revert
    function test_bidAuction_RevertIf_CurrTimeEqEndTime() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        skip(25 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionExpired(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(auctionId, 0, 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：出价人账户金额不足 revert EVMError:OutOfFunds
    function test_bidAuction_RevertWhen_BidValueInSufficient() public {
        address account1 = makeAddr("account1");
        vm.prank(account1);
        assertEq(account1.balance, 0);

        bool reverted;
        try NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(1, 0, 0) {
            // 成功执行，不符合预期，测试失败
            assertFalse(true);
        } catch {
            // 任意回滚都进入这里，包含EVM OutOfFunds
            reverted = true;
            assertEq(account1.balance, 0);
        }
        assertTrue(reverted);
    }

    // bidAuction测试场景：出价<当前最高价 revert
    function test_bidAuction_RevertIf_BidValueLeHighestPrice() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 1 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        skip(2 hours);

        uint256 currHighestPrice = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId).currHighestPrice;

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("NotOverCurrHighestPrice(uint256)", currHighestPrice));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 0.5 ether}(auctionId, 0, 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：出价=当前最高价 revert
    function test_bidAuction_RevertIf_BidValueEqHighestPrice() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }
        
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 1 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        skip(2 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("NotOverCurrHighestPrice(uint256)", 1 ether));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1 ether}(auctionId, 0, 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：合约接收到msg.value累计值超过uint256最大值
    // 关键点：合约里能接收的最大累计金额为uint256的最大值
    // 代币精度为10^18, 那么 msg.value 必须 ≤ ~6.15604e47，三数相乘才不会溢出 uint256
    function test_bidAuction_RevertIf_OverflowPayment() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        // 创建拍卖        
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 1 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        skip(2 hours);

        vm.startPrank(bidder1);
        // 第一次出价
        deal(bidder1, type(uint256).max);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: (type(uint256).max / 2)}(auctionId, 0, 0);
        // 第二次出价
        deal(bidder1, type(uint256).max);
        bool reverted;
        try NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: (type(uint256).max / 2 + 20 ether)}(auctionId, 0, 0) {
            // 成功执行，不符合预期，测试失败
            assertFalse(true);
        } catch {
            // 任意回滚都进入这里，包含EvmError: OverflowPayment
            reverted = true;
        }
        assertEq(reverted, true);

        vm.stopPrank();
    }

    // bidAuction测试场景：记录某拍卖某出价者需要退回的金额累计相加超过uint256最大值
    function test_bidAuction_RevertIf_AccOverflow() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;
        // 创建拍卖        
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(SEPOLIA_NFT_ADDR).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }       

        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 1 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        uint256 testValue = type(uint256).max - 20 ether;
        bytes32 finalSlot = getBidPriceReturnsSlot(auctionId, bidder1, 0);
        vm.store(auctionSysProxyAddr, finalSlot, bytes32(testValue));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), testValue);

        skip(2 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("refundAfterBid()"));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 21 ether}(auctionId, 0, 0);
        // 检查
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), testValue);
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.currHighestPrice, 1 ether);
        assertEq(info.highestBidder, address(0));
    }

    // bidAuction测试场景：记录某拍卖某出价者需要退回的金额累计相加等于uint256最大值 success
    function test_bidAuction_ReturnsMaxBoundary() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        // 创建拍卖
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 1 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens 
            }));
        vm.stopPrank();

        uint256 testValue = type(uint256).max - 20 ether;
        bytes32 finalSlot = getBidPriceReturnsSlot(auctionId, bidder1, 0);
        vm.store(auctionSysProxyAddr, finalSlot, bytes32(testValue));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), testValue);

        skip(2 hours);

        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 20 ether}(auctionId, 0, 0);
        // 检查
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), testValue);
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.currHighestPrice, 20 ether);
        assertEq(info.highestBidder, bidder1);
    }

    // bidAuction测试场景：代币出价，代币数为0，revert
    function test_bidAuction_RevertIf_InvalidBidAmount() public {
        address nftContract;
        uint256 tokenId = 1;
        // 创建拍卖
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 1 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens() 
            }));
        vm.stopPrank();

        skip(2 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.InvalidBidAmount.selector));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction(auctionId, 1, 0);
    }

    // bidAuction测试场景：出价是不允许的代币，revert
    function test_bidAuction_RevertIf_InvalidBidToken() public {
        address nftContract;
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(SEPOLIA_NFT_ADDR).approve(auctionSysProxyAddr, 1);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, 1);
        }       
        
        // 创建拍卖
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: 1,
                startPrice: 1 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens() 
            }));
        vm.stopPrank();

        skip(2 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSelector(NFTAuctionV1.InvalidBidToken.selector));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction(auctionId, 4, 1);
    }

    // src/NFTAuctionV1.sol:216，(type(uint256).max - $.bidPriceReturns[auctionId][msg.sender]) -> (type(uint256).max ^ $.bidPriceReturns[auctionId][msg.sender])，属于等价突变，不存在安全风险，接受存活。

    // // #endregion 拍卖出价 测试结束==============================================

    // // #region 退款 测试结束==============================================
    // refund 测试成功场景1：仅ETH
    function test_refund_Success1() public {
        uint256[] memory allowedTokens;
        address nftContract;
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(SEPOLIA_NFT_ADDR).approve(auctionSysProxyAddr, 1);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, 1);
        }

        // 创建拍卖        
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: 1,
                startPrice: 1 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens
            }));
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId, 0, 0);
        // 检查
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);

        // bidder2出价
        uint256 _bidder2Value = 20 ether;
        vm.prank(bidder2);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder2Value}(auctionId, 0, 0);
        // 检查
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), _bidder1Value);
        assertEq(bidder2.balance, bidder2InitBalance - _bidder2Value);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value + _bidder2Value);

        // bidder1退款
        vm.prank(bidder1);
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.Refund(auctionId, bidder1, 0, _bidder1Value);
        NFTAuctionV1(auctionSysProxyAddr).refund(auctionId, 0);
        // 检查
        assertEq(bidder1.balance, bidder1InitBalance);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder2Value);
    }

    // refund 测试成功场景2：ETH和代币全部
    function test_refund_Success2() public {
        address nftContract;
        uint256 tokenId = 1;
        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(SEPOLIA_NFT_ADDR).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        // 创建拍卖        
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens()
            }));
        vm.stopPrank();

        skip(2 hours);

        // daiBidder出价
        uint256 _bidVal1 = 50 * 10 ** 18;
        vm.startPrank(daiBidder);
        IERC20(daiAddr).approve(auctionSysProxyAddr, _bidVal1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction(auctionId, 2, _bidVal1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, usdcBidder, 1), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);
        vm.stopPrank();

        // usdcBidder出价
        uint256 _bidVal2 = 60 * 10 ** 6;
        vm.startPrank(usdcBidder);
        IERC20(usdcAddr).approve(auctionSysProxyAddr, _bidVal2);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction(auctionId, 1, _bidVal2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), _bidVal1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, usdcBidder, 1), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);
        vm.stopPrank();

        // bidder1出价
        uint256 _bidVal3 = 1 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidVal3}(auctionId, 0, 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), _bidVal1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, usdcBidder, 1), _bidVal2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);

        // daiBidder退款
        vm.prank(daiBidder);
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.Refund(auctionId, daiBidder, 2, _bidVal1);
        NFTAuctionV1(auctionSysProxyAddr).refund(auctionId, 2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, usdcBidder, 1), _bidVal2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);

        // usdcBidder退款
        vm.prank(usdcBidder);
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.Refund(auctionId, usdcBidder, 1, _bidVal2);
        NFTAuctionV1(auctionSysProxyAddr).refund(auctionId, 1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, daiBidder, 2), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, usdcBidder, 1), 0);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1, 0), 0);        
    }

    // refund测试场景1： auctionId、msg.sender都不存在 退款 revert
    function test_refund_NotRefund1() public {
        vm.expectRevert(abi.encodeWithSignature("NotRefund()"));
        NFTAuctionV1(auctionSysProxyAddr).refund(1, 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
    }

    // refund测试场景2：出价未被超过Not refund revert
    function test_refund_NotRefund2() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(SEPOLIA_NFT_ADDR).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        // 创建拍卖       
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens
            }));
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.startPrank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId, 0, 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        // bidder1退款
        vm.expectRevert(abi.encodeWithSignature("NotRefund()"));
        NFTAuctionV1(auctionSysProxyAddr).refund(auctionId, 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        vm.stopPrank();
    }

    // refund测试场景3： auctionId存在，msg.sender不存在 退款 revert
    function test_refund_NotRefund3() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            vm.startPrank(sepoliaNFT1Owner);
            ERC721(SEPOLIA_NFT_ADDR).approve(auctionSysProxyAddr, tokenId);
        } else {
            nftContract = appleNftAddr;
            vm.startPrank(seller1);
            appleNft.approve(auctionSysProxyAddr, tokenId);
        }

        // 创建拍卖
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens
            }));
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId, 0, 0);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);

        // bidder2出价
        uint256 _bidder2Value = 20 ether;
        vm.prank(bidder2);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder2Value}(auctionId, 0, 0);
        assertEq(bidder2.balance, bidder2InitBalance - _bidder2Value);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value + _bidder2Value);

        // 默认账号退款
        vm.expectRevert(abi.encodeWithSignature("NotRefund()"));
        NFTAuctionV1(auctionSysProxyAddr).refund(auctionId, 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value + _bidder2Value);
    }

    // refund测试场景：合约ETH不足，call转账失败，revert "Refund to bidder failed!"
    function test_refund_NoETH() public {
        uint256 testValue = 10 ether;
        bytes32 finalSlot = getBidPriceReturnsSlot(1, bidder1, 0);
        vm.store(auctionSysProxyAddr, finalSlot, bytes32(testValue));

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("RefundTransferFailed(address,uint256)", bidder1, testValue));
        NFTAuctionV1(auctionSysProxyAddr).refund(1, 0);
    }

    // src/NFTAuctionV1.sol:238, _price > 0 -> _price != 0, 等价突变

    // #endregion 退款 测试结束=================================================

    // #region 结束拍卖 测试开始=================================================
    // endAuction 测试成功场景1:没人竞拍
    function test_endAuction_Success1() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;
        address seller;
        uint256 sellerInitBalance;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
            sellerInitBalance = sepoliaNFT1OwnerInitBalance;            
        } else {
            nftContract = appleNftAddr;
            seller = seller1;
            sellerInitBalance = seller1InitBalance;            
        }

        // 创建拍卖
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);    
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens
            }));

        skip(26 hours);

        // 检查
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info1.isEnded, false);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
        assertEq(ERC721(nftContract).ownerOf(tokenId), info1.seller);
        
        // 卖家结束拍卖
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionEnd(auctionId, info1.seller, address(0), 0, block.timestamp, 0, 0);
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);

        // 检查
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info2.isEnded, true);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
        assertEq(ERC721(nftContract).ownerOf(tokenId), info1.seller);

        vm.stopPrank();
    }

    // endAuction 测试成功场景2:仅ETH竞拍，有人竞拍，买家结束拍卖
    function test_endAuction_Success2() public {
        uint256[] memory allowedTokens;
        address nftContract;
        uint256 tokenId = 1;
        address seller;
        uint256 sellerInitBalance;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
            sellerInitBalance = sepoliaNFT1OwnerInitBalance;            
        } else {
            nftContract = appleNftAddr;
            seller = seller1;
            sellerInitBalance = seller1InitBalance;            
        }

        // 创建拍卖
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);    
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: allowedTokens
            }));

        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        vm.startPrank(bidder1);
        uint256 bidder1Value = 2 ether;
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: bidder1Value}(auctionId, 0, 0);
        // 检查
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info1.isEnded, false);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - bidder1Value);
        assertEq(ERC721(nftContract).ownerOf(tokenId), info1.seller);
        assertEq(info1.currHighestPrice, bidder1Value);
        assertEq(info1.highestBidder, bidder1);

        skip(24 hours);

        // 买家bidder1结束拍卖
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionEnd(
            auctionId, info1.highestBidder, info1.highestBidder, info1.currHighestPrice, block.timestamp, 0, info1.currHighestTokenAmount
        );
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        // 检查
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info2.isEnded, true);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller.balance, sellerInitBalance + info2.currHighestTokenAmount);
        assertEq(ERC721(nftContract).ownerOf(tokenId), info2.highestBidder);

        vm.stopPrank();
    }

    // endAuction 测试成功场景3：ETH和代币全部可以出价，有人竞拍，卖家结束拍卖
    function test_endAuction_Success3() public {
        address nftContract;
        uint256 tokenId = 1;
        address seller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
        } else {
            nftContract = appleNftAddr;
            seller = seller1;                
        }

        // 创建拍卖
        uint256 sellerInitUsdcBalance = ERC20(usdcAddr).balanceOf(seller);
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);    
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens()
            }));
        
        assertEq(ERC20(usdcAddr).balanceOf(auctionSysProxyAddr), 0);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
        vm.stopPrank();        

        skip(2 hours);

        // usdcBidder出价
        uint256 _bidVal = 50 * 10 ** 6;
        vm.startPrank(usdcBidder);
        IERC20(usdcAddr).approve(auctionSysProxyAddr, _bidVal);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction(auctionId, 1, _bidVal);
        // 检查
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info1.isEnded, false);        
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
        assertEq(ERC20(usdcAddr).balanceOf(seller), sellerInitUsdcBalance);
        assertEq(ERC20(usdcAddr).balanceOf(usdcBidder), usdcBidderInitBalance - _bidVal);
        assertEq(ERC20(usdcAddr).balanceOf(auctionSysProxyAddr), _bidVal);         
        vm.stopPrank();

        skip(24 hours);

        // 卖家结束拍卖
        vm.startPrank(seller);
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionEnd(
            auctionId, info1.seller, info1.highestBidder, info1.currHighestPrice, block.timestamp, 1, info1.currHighestTokenAmount
        );
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        // 检查
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info2.isEnded, true);
        assertEq(ERC721(nftContract).ownerOf(tokenId), info2.highestBidder);
        assertEq(ERC721(nftContract).ownerOf(tokenId), usdcBidder);
        assertEq(ERC20(usdcAddr).balanceOf(seller), sellerInitUsdcBalance + _bidVal);
        assertEq(ERC20(usdcAddr).balanceOf(usdcBidder), usdcBidderInitBalance - _bidVal);
        assertEq(ERC20(usdcAddr).balanceOf(auctionSysProxyAddr), 0);
        
        vm.stopPrank();
    }

    // endAuction测试场景：拍卖没有创建 revert
    function test_endAuction_RevertIf_NotCreated() public {      
        address nftContract;
        uint256 tokenId = 1;
        address seller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
        } else {
            nftContract = appleNftAddr;
            seller = seller1;                
        }
        
        uint256 sellerInitBalance = seller.balance;

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionNotExists(uint256)", 1));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(1);

        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
    }

    // endAuction测试场景：拍卖没有到期 revert
    function test_endAuction_RevertIf_NotExpired() public {
        address nftContract;
        uint256 tokenId = 1;
        address seller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
        } else {
            nftContract = appleNftAddr;
            seller = seller1;                
        }

        uint256 sellerInitBalance = seller.balance;

        // 创建拍卖
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens()
            }));
        vm.stopPrank();

        // 结束拍卖
        vm.expectRevert(abi.encodeWithSignature("AuctionNotExpired(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
    }

    // endAuction测试场景：当前时间刚好=拍卖已到期时间 success
    function test_endAuction_EndTimeMaxBoundary() public {
        address nftContract;
        uint256 tokenId = 1;
        address seller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
        } else {
            nftContract = appleNftAddr;
            seller = seller1;                
        }

        uint256 sellerInitBalance = seller.balance;

        // 创建拍卖
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens()
            }));
        skip(25 hours);
        // 结束拍卖
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);        
        vm.stopPrank();
    }

    // endAuction测试场景：拍卖已结束 revert
    function test_endAuction_RevertIf_Ended() public {
        // seller1创建拍卖 -> seller1结束拍卖
        address nftContract;
        uint256 tokenId = 1;
        address seller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
        } else {
            nftContract = appleNftAddr;
            seller = seller1;                
        }

        uint256 sellerInitBalance = seller.balance;

        // 创建拍卖
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens()
            }));
        skip(26 hours);
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        vm.stopPrank();

        // 结束拍卖
        vm.expectRevert(abi.encodeWithSignature("AuctionEnded(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
    }

    // endAuction测试场景：调用者不是卖家也不是获胜买家 revert
    // kill mutate: _bidderAddr == msg.sender -> _bidderAddr >= msg.sender
    function test_endAuction_RevertIf_NotCaller1() public {
        address nftContract;
        uint256 tokenId = 1;
        address seller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
        } else {
            nftContract = appleNftAddr;
            seller = seller1;                
        }

        uint256 sellerInitBalance = seller.balance;

        // 创建拍卖
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens()
            }));
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 1 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId, 0, 0);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);

        skip(24 hours);

        // 结束拍卖
        // 构造一个大于auctionSysProxyAddr的地址
        address testAddr = address(uint160(bidder1) + uint160(1));
        vm.prank(testAddr);
        vm.expectRevert(abi.encodeWithSignature("NotHighestBidderOrSeller()"));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
    }

    // endAuction测试场景：调用者不是卖家也不是获胜买家 revert
    // kill mutate: _bidderAddr == msg.sender -> _bidderAddr <= msg.sender
    function test_endAuction_RevertIf_NotCaller2() public {
        address nftContract;
        uint256 tokenId = 1;
        address seller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
        } else {
            nftContract = appleNftAddr;
            seller = seller1;                
        }

        uint256 sellerInitBalance = seller.balance;

        // 创建拍卖
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens()
            }));
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 1 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId, 0, 0);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);

        skip(24 hours);

        // 结束拍卖
        vm.expectRevert(abi.encodeWithSignature("NotHighestBidderOrSeller()"));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
    }

    // endAuction测试场景：此合约转账失败 revert
    function test_endAuction_RevertIf_NoPayable() public {
        address nftContract;
        uint256 tokenId = 1;
        address seller;

        if(isForkMode) {
            nftContract = SEPOLIA_NFT_ADDR;
            seller = sepoliaNFT1Owner;
        } else {
            nftContract = appleNftAddr;
            seller = seller1;                
        }

        uint256 sellerInitBalance = seller.balance;

        // 创建拍卖
        vm.startPrank(seller);
        ERC721(nftContract).approve(auctionSysProxyAddr, tokenId);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(NFTAuctionV1.CreateAuctionParams({
                nftContract: nftContract, 
                tokenId: tokenId,
                startPrice: 0.01 ether, 
                startTime: currTs + 1 hours, 
                durationHours: 24, 
                allowedTokens: _createAllowedTokens()
            }));
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 1 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId, 0, 0);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);

        skip(24 hours);
        // 改变此合约里的ETH
        vm.deal(auctionSysProxyAddr, 0);

        // 结束拍卖
        vm.prank(bidder1);
        vm.expectRevert();
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller.balance, sellerInitBalance);
        assertEq(auctionSysProxyAddr.balance, 0);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(ERC721(nftContract).ownerOf(tokenId), seller);
    }

    // src/NFTAuctionV1.sol:269, _bidderAddr == address(0) -> _bidderAddr <= address(0), 等价突变，可忽略

    // #endregion 结束拍卖 测试结束==============================================

    // // #region invariant testing ==============================================
    // // 恒定不变测试：proxy合约balance永远>=出价之和-退款之和-交易之和
    // function invariant_balance() public view {
    //     assertGe(
    //         auctionSysProxyAddr.balance,
    //         (v1Handler.ghost_bidSum() - v1Handler.ghost_refundSum() - v1Handler.ghost_endValueSum())
    //     );
    // }

    // // // invariant_balance复现
    // // function test_reproduce_balance_issue() public {
    // //     // setUp自动执行，部署合约
    // //     // ========== 步骤1 create ==========
    // //     //vm.startPrank(0xb6DDA0a9fBA4EB783d0cBc9aB44eC82702ed0305);
    // //     v1Handler.create(
    // //         467,
    // //         89900047961061425986379404691942066161803187134324,
    // //         278571866036544921172,
    // //         715192216682093730948166430439482,
    // //         374143318842495837892
    // //     );
    // //     //vm.stopPrank();

    // //     // ========== 步骤2 create ==========
    // //     //vm.startPrank(0x0000000000000000000000000000000000004505);
    // //     v1Handler.create(
    // //         1800000000000000000,
    // //         355,
    // //         3,
    // //         2000000000000000000,
    // //         21000000000000000000
    // //     );
    // //     //vm.stopPrank();

    // //     // ========== 步骤3 bid ==========
    // //     //vm.startPrank(0x0000000000000000000000000000000000000d36);
    // //     v1Handler.bid(
    // //         1099794980143326351922066467088116956885136440392,
    // //         72475405630964902819927660838223,
    // //         74351223583823190557526605416250411060347,
    // //         1170686145495929657897793633421753363265652495068583590418888760101172548
    // //     );
    // //     //vm.stopPrank();

    // //     // ========== 步骤4 create ==========
    // //     //vm.startPrank(0x000000000000000000000000000000000000109b);
    // //     v1Handler.create(
    // //         24,
    // //         24440054405305269366569402256811496959409073762505157381672968839269610695612,
    // //         100000000000000000000,
    // //         24440054405305269366569402256811496959409073762505157381672968839269610695612,
    // //         82
    // //     );
    // //     //vm.stopPrank();

    // //     // ========== 步骤5 bid ==========
    // //     //vm.startPrank(0x0000000000000000000000000000000000003C24);
    // //     v1Handler.bid(
    // //         1000000000000000000,
    // //         1800000000000000000,
    // //         1800000000000000000,
    // //         1000000000000000000
    // //     );
    // //     //vm.stopPrank();

    // //     // ========== 步骤6 bid ==========
    // //     //vm.startPrank(0x955487B7d3F76a7FB3541c0f63B5F8106680c536);
    // //     v1Handler.bid(
    // //         855071345745232009466725576130540106060422356619165391904676280659785499620,
    // //         39030382427304357428776483520730882006646030029,
    // //         3223177000343105299384652673253647601996376731843744068258199097222838,
    // //         325034683592225282058780095899515
    // //     );
    // //     //vm.stopPrank();

    // //     // 执行失衡校验，触发断言失败
    // //     assertGe(auctionSysProxyAddr.balance, (v1Handler.ghost_bidSum() - v1Handler.ghost_refundSum() - v1Handler.ghost_endValueSum()));

    // // }

    // // 仅用于打印调试统计
    // function invariant_callSummary() public view {
    //     //v1Handler.callSummary();
    // }
    // // #endregion invariant testing ==============================================

    // // #region 测试业务的公共函数================================================

    function _createAllowedTokens() internal pure returns (uint256[] memory allowedTokens) {
        allowedTokens = new uint256[](3);
        allowedTokens[0] = 0;
        allowedTokens[1] = 1;
        allowedTokens[2] = 2;
    }

    function _isInvalidAllowedToken(bytes memory revertData, uint256[] calldata allowedTokens) internal pure returns (bool) {
        for(uint256 i = 0 ; i < allowedTokens.length ; i++) {
            if(keccak256(revertData) == keccak256(abi.encodeWithSignature("InvalidAllowedToken(uint256)", allowedTokens[i]))) return true;          
        }
        return false;
    }

    function _bid(uint256 auctionId, address bidder, uint256 bidVal, uint256 bidToken, uint256 bidTokenAmount, uint8 decimals) internal {
        vm.startPrank(bidder);
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.BidInfo(auctionId, bidder, block.timestamp, bidVal, bidToken, bidTokenAmount, decimals);
        if(bidToken == 0){
            NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: bidTokenAmount}(auctionId, bidToken, bidTokenAmount);
        } else {
            NFTAuctionV1(auctionSysProxyAddr).bidAuction(auctionId, bidToken, bidTokenAmount);
        }
        vm.stopPrank();
    }

    // // #endregion 测试业务的公共函数================================================
}
