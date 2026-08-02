// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {NFTAuctionV1} from "../src/NFTAuctionV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {NFTAuctionV1Handler} from "./handlers/NFTAuctionV1Handler.sol";

contract AppleNFT is ERC721("AppleNFT", "APL") {
    function mint(address to, uint256 tokenId) external {
        _safeMint(to, tokenId);
    }
}

contract BananaNFT is ERC721Upgradeable {}

contract NFTAuctionV1Test is Test {
    bytes32 public constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 public constant AUCTION_STORAGE_LOCATION =
        0x4c48d9668da3b85d45dd9d4fe97ed0e93efd4218c47ce0da3f0ab7fa4d259a00;

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

    uint256 public constant AUCTION_ID_1 = 1;

    address public seller1 = makeAddr("seller1");

    address public bidder1 = makeAddr("bidder1");
    address public bidder2 = makeAddr("bidder2");

    uint256 public auctionSysProxyInitBalance;
    uint256 public seller1InitBalance;
    uint256 public bidder1InitBalance;
    uint256 public bidder2InitBalance;

    NFTAuctionV1Handler public v1Handler;

    // #region 共用函数
    //// 部署NFTAuctionV1合约
    function newNftContract(string memory sys, address owner, string memory nftName, string memory nftSymbol)
        public
        returns (NFTAuctionV1 nftSys, address nftSysImpAddr, ERC1967Proxy nftSysProxy, address nftSysProxyAddr)
    {
        vm.startPrank(owner);
        console.log(sys, "owner:", owner);
        nftSys = new NFTAuctionV1();
        nftSysImpAddr = address(nftSys);
        console.log(sys, "implementation address:", nftSysImpAddr);
        bytes memory initData = abi.encodeCall(NFTAuctionV1.initialize, (owner, nftName, nftSymbol));
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
    function getBidPriceReturnsSlot(uint256 auctionId, address bidder) public pure returns (bytes32) {
        // mapping 基础slot = 根槽 + 相对偏移3
        bytes32 mapBase = bytes32(uint256(AUCTION_STORAGE_LOCATION) + 3);
        // 第一层key：auctionId
        bytes32 layer1 = keccak256(abi.encode(auctionId, mapBase));
        // 第二层key：bidder
        bytes32 finalSlot = keccak256(abi.encode(bidder, layer1));
        return finalSlot;
    }

    // #endregion 共用函数

    function setUp() public {
        currTs = block.timestamp;
        console.log("currTs of setUp:", currTs);

        // 部署 拍卖合约
        (auctionSys, auctionSysAddr, auctionSysProxy, auctionSysProxyAddr) =
            newNftContract("auction", auctionSysOwner, "AuctionSys", "AS");

        // 部署 AppleNFT 用来测试
        appleNft = new AppleNFT();
        appleNftAddr = address(appleNft);
        console.log("seller1 address:", seller1);
        console.log("appleNftAddr:", appleNftAddr);
        vm.prank(seller1);
        appleNft.mint(seller1, APPLENFT_TOKENID_1);

        // 给bidder1、bidder2账号各充 10 ether

        deal(bidder1, 100 ether);
        deal(bidder2, 100 ether);

        auctionSysProxyInitBalance = auctionSysProxyAddr.balance;
        seller1InitBalance = seller1.balance;
        bidder1InitBalance = bidder1.balance;
        bidder2InitBalance = bidder2.balance;

        // 不变量测试准备
        v1Handler = new NFTAuctionV1Handler(auctionSysProxyAddr, NFTAuctionV1(auctionSysProxyAddr), appleNft);
        targetContract(address(v1Handler));

        console.log("By default account is:", address(this));
        console.log("===setUp End=========");
    }

    // #region UUPS Test Start===========================================

    // 读取【裸逻辑合约自己的存储】，从未初始化，owner=0
    function test_impl_owner() public view {
        address implOwner = auctionSys.owner();
        console.log("Get owner of auction system:", implOwner);
        vm.assertNotEq(auctionSysOwner, implOwner, "auctionSysOwner == implOwner");
    }

    // 读取逻辑合约IMPLEMENTATION_SLOT值，0x0
    function test_impl_implSlot() public view {
        address implImplSlotAddr = address(uint160(uint256(vm.load(auctionSysAddr, IMPLEMENTATION_SLOT))));
        console.log("Value of implementation slot in Auction System:", implImplSlotAddr);
        vm.assertNotEq(auctionSysAddr, implImplSlotAddr, "auctionSysAddr == implImplSlotAddr");
    }

    // 读取【Proxy代理合约的独立存储】，部署时执行过initialize，owner=auctionSysOwner
    function test_proxy_owner() public view {
        address proxyOwner = NFTAuctionV1(auctionSysProxyAddr).owner();
        console.log("Get owner of auction system proxy:", proxyOwner);
        vm.assertEq(auctionSysOwner, proxyOwner, "auctionSysOwner != proxyOwner");
    }

    // 读取Proxy代理合约IMPLEMENTATION_SLOT值=auctionSysAddr
    function test_proxy_implSlot() public view {
        address proxyImplSlotAddr = address(uint160(uint256(vm.load(auctionSysProxyAddr, IMPLEMENTATION_SLOT))));
        console.log("Value of implementation slot in Auction System Proxy:", proxyImplSlotAddr);
        vm.assertEq(auctionSysAddr, proxyImplSlotAddr, "auctionSysAddr != proxyImplSlotAddr");
    }

    // V1升级V2地址address(0) revert
    function test_upgradeTo_zeroAddr_revert() public {
        vm.prank(auctionSysOwner); // 只对当前下一行代码使用auctionSysOwner账号运行，需要在某个区间一致运行请使用vm.startPrank()+vm.stopPrank()
        vm.expectRevert();
        NFTAuctionV1(auctionSysProxyAddr).upgradeToAndCall(address(0), "");
        console.log("Success => Upgrade to address(0) failed");
    }

    // 非管理员执行升级操作 revert OwnableUnauthorizedAccount(address)
    function test_nonAdmin_revert() public {
        vm.prank(random);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", random));
        NFTAuctionV1(auctionSysProxyAddr).upgradeToAndCall(address(0), "");
        console.log("Success => Non admin failed to perform upgrade operation");
    }

    // 升级至无UUPS的普通合约 revert ERC1967InvalidImplementation(address)
    function test_nonUUPSContract_revert() public {
        vm.prank(auctionSysOwner);
        vm.expectRevert(abi.encodeWithSignature("ERC1967InvalidImplementation(address)", appleNftAddr));
        NFTAuctionV1(auctionSysProxyAddr).upgradeToAndCall(appleNftAddr, "");
        console.log("Success => Upgrade to non UUPS contract failed");
    }

    // #endregion UUPS Test End=======================================================

    // #region 创建拍卖 测试开始============================================================
    // createAuction 测试成功场景
    function test_createAuction_success() public {
        vm.prank(seller1);
        appleNft.setApprovalForAll(auctionSysProxyAddr, true);

        uint256 startPrice = 1;
        uint256 startTime = currTs + 1 minutes;
        uint256 durationHours = 24;
        uint256 endTime = startTime + (durationHours * 1 hours);

        vm.prank(seller1);
        // check emit AuctionCreated
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionCreated(
            AUCTION_ID_1, seller1, appleNftAddr, APPLENFT_TOKENID_1, startPrice, startTime, endTime
        );
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, startPrice, startTime, durationHours);

        // check 函数返回的值
        assertEq(auctionId, AUCTION_ID_1);

        // check storage auctionId
        assertEq(getStorageAuctionId(), AUCTION_ID_1);

        // check storage ntfToken2AuctionId
        console.log(
            "AuctionStorage.ntfToken2AuctionId[appleNftAddr][APPLENFT_TOKENID_1] =",
            getStorageNtfToken2AuctionId(appleNftAddr, APPLENFT_TOKENID_1)
        );
        assertEq(getStorageNtfToken2AuctionId(appleNftAddr, APPLENFT_TOKENID_1), AUCTION_ID_1);

        // check Storage AuctionInfo
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.auctionId, AUCTION_ID_1);
        assertEq(info.tokenId, APPLENFT_TOKENID_1);
        assertEq(info.startPrice, startPrice);
        assertEq(info.startTime, startTime);
        assertEq(info.durationHours, durationHours);
        assertEq(info.endTime, endTime);
        assertEq(info.currHighestPrice, startPrice);
        assertEq(info.highestBidder, address(0));
        assertEq(info.nftContract, appleNftAddr);
        assertEq(info.seller, seller1);
        assertEq(info.isCreated, true);
        assertEq(info.isEnded, false);
    }

    // createAuction测试场景：待创建拍卖的开始价格不大于0 revert
    // src/NFTAuctionV1.sol:119，startPrice > 0 → startPrice != 0，startPrice 为 uint256，值域无负数，属于等价突变，不存在安全风险，接受存活。
    function test_createAuction_startPriceZero() public {
        vm.expectRevert(abi.encodeWithSignature("StartPriceMustGtZero()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 0, currTs + 1 minutes, 24);
    }

    // createAuction测试场景：待创建拍卖的持续时间小于24 revert
    function test_createAuction_durationHoursLe24() public {
        vm.expectRevert(abi.encodeWithSignature("DurationHoursOutOfRange()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 10);
    }

    // durationHours边界：大于24，例如 25
    function test_createAuction_durationHours_25() public {
        vm.startPrank(seller1);
        // seller1授权appleNFT到拍卖合约
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        // 预期：成功创建，不revert
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 minutes, 25);
        vm.stopPrank();
    }

    // src/NFTAuctionV1.sol:121,durationHours >= 24 && durationHours <= 168 → durationHours >= 24 == durationHours <= 168 属于等价突变，不存在安全风险，接受存活。

    function test_createAuction_durationHours_168() public {
        vm.startPrank(seller1);
        // seller1授权appleNFT到拍卖合约
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        // 预期：成功创建，不revert
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 minutes, 168);
        vm.stopPrank();
    }

    // createAuction测试场景：待创建拍卖的持续时间大于168 revert
    function test_createAuction_durationHoursGe168() public {
        uint256 invalidDurationHours = 24440054405305269366569402256811496959409073762505157381672968839269610695612;
        vm.expectRevert(abi.encodeWithSignature("DurationHoursOutOfRange()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, invalidDurationHours);
    }

    // createAuction测试场景：待创建拍卖的开始时间等于当前时间 revert
    function test_createAuction_startTimeEqCurr() public {
        vm.expectRevert(abi.encodeWithSignature("StartTimeMustGtCurrTime()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, block.timestamp, 24);
    }

    // createAuction测试场景：待创建拍卖的开始时间小于当前时间 revert
    function test_createAuction_startTimeLeCurr() public {
        vm.expectRevert(abi.encodeWithSignature("StartTimeMustGtCurrTime()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, 0, 24);
    }

    // createAuction测试场景：待创建拍卖的开始时间等于_currTs + 1 weeks
    // (currTs ∣ 1 weeks) ≤ (currTs + 1 weeks), 同时测试突变 currTs + 1 weeks -> currTs ∣ 1 weeks
    // (currTs ^ 1 weeks) ≤ (currTs + 1 weeks), 同时测试突变 currTs + 1 weeks -> currTs ^ 1 weeks
    function test_createAuction_startTime_eqCurrTsAdd1Weeks() public {
        vm.startPrank(seller1);
        // seller1授权appleNFT到拍卖合约
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        skip(1 hours);
        // 预期：成功创建，不revert
        NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, block.timestamp + 1 weeks, 24);
        vm.stopPrank();
    }

    // createAuction测试场景：待创建拍卖的开始时间(currTs * 1 weeks)超过允许的最大时间 revert
    function test_createAuction_startTimeNotAllowed1() public {
        skip(1 hours);
        uint256 invalidStartTime = block.timestamp * 1 weeks;
        vm.expectRevert(abi.encodeWithSignature("StartTimeOverMaxValue()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, invalidStartTime, 24);
    }

    // createAuction测试场景：待创建拍卖的开始时间超过允许的最大时间 revert
    function test_createAuction_startTimeNotAllowed2() public {
        uint256 invalidStartTime = 115792089237316195423570985008687907853269984665640564039457584007913129639905;
        vm.expectRevert(abi.encodeWithSignature("StartTimeOverMaxValue()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, invalidStartTime, 24);
    }

    // createAuction测试场景：待创建拍卖的NFT所在的合约地址为address(0) revert
    function test_createAuction_nftAddrZero() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidNftContractAddr()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(address(0), 1, 1, currTs + 1 minutes, 24);
    }

    // src/NFTAuctionV1.sol:132, nftContract != address(0) → nftContract > address(0) 属于等价突变，不存在安全风险，接受存活。
    // src/NFTAuctionV1.sol:136, $.ntfToken2AuctionId[nftContract][tokenId] == 0 → $.ntfToken2AuctionId[nftContract][tokenId] <= 0 属于等价突变，不存在安全风险，接受存活。

    // createAuction测试场景：创建已经创建拍卖的NFT revert
    function test_createAuction_nftCreated() public {
        vm.startPrank(seller1);

        // seller1授权appleNFT到拍卖合约
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);

        // 第一次对指定NFT创建拍卖
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 24);

        // 再次对指定NFT创建拍卖
        vm.expectRevert(abi.encodeWithSignature("AuctionAlreadyExists(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 24);

        vm.stopPrank();
    }

    // createAuction测试场景：NFT不存在 revert
    function test_createAuction_nftNonExist() public {
        uint256 nonExistTokenId = 2;
        vm.startPrank(seller1);
        appleNft.setApprovalForAll(auctionSysProxyAddr, true);

        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", nonExistTokenId));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, nonExistTokenId, 1, currTs + 1 minutes, 24);

        vm.stopPrank();
    }

    // createAuction测试场景：创建拍卖者不是该NFT的持有者 revert
    // kill mutate: msg.sender == nft.ownerOf(tokenId) -> msg.sender >= nft.ownerOf(tokenId)
    function test_createAuction_nftNotOwner1() public {
        address seller2 = makeAddr("seller2");
        vm.prank(seller2);
        vm.expectRevert(abi.encodeWithSignature("NotNftOwner(address)", seller2));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 24);
    }

    // createAuction测试场景：创建拍卖者不是该NFT的持有者 revert
    // kill mutate: msg.sender == nft.ownerOf(tokenId) -> msg.sender <= nft.ownerOf(tokenId)
    function test_createAuction_nftNotOwner2() public {
        vm.expectRevert(abi.encodeWithSignature("NotNftOwner(address)", address(this)));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 24);
    }

    // createAuction测试场景：待创建拍卖的NFT没有授权给任何合约
    function test_createAuction_nftNotApprove() public {
        vm.prank(seller1);
        vm.expectRevert(abi.encodeWithSignature("NftNotApproved()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 24);
    }

    // createAuction测试场景：seller1的appleNft已授权，只是不是授权给auctionSysProxyAddr，而且地址大于auctionSysProxyAddr
    // kill mutate: address(this) == nft.getApproved(tokenId) -> address(this) <= nft.getApproved(tokenId)
    function test_createAuction_approveGeAddr() public {
        // 构造一个大于auctionSysProxyAddr的地址
        address testAddr = address(uint160(auctionSysProxyAddr) + uint160(1));

        vm.startPrank(seller1);
        appleNft.approve(testAddr, APPLENFT_TOKENID_1);
        vm.expectRevert(abi.encodeWithSignature("NftNotApproved()"));
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 24);
        vm.stopPrank();
    }

    // createAuction测试场景：seller1持有者approve和approvedForAll同时都授权给此合约 success
    // kill mutate: address(this) == nft.getApproved(tokenId) || nft.isApprovedForAll(msg.sender, address(this)) -> address(this) == nft.getApproved(tokenId) != nft.isApprovedForAll(msg.sender, address(this))
    function test_createAuction_approveSingleAndAll() public {
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        appleNft.setApprovalForAll(auctionSysProxyAddr, true);
        NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 24);
        vm.stopPrank();
    }

    // createAuction测试场景：待创建拍卖的结束时间必须等于startTime + (durationHours * 1 hours)
    // startTime | (durationHours * 1 hours) ≤ startTime + (durationHours * 1 hours), 同时测试突变 startTime + (durationHours * 1 hours) -> startTime | (durationHours * 1 hours)
    // startTime ^ (durationHours * 1 hours) ≤ startTime + (durationHours * 1 hours), 同时测试突变 startTime + (durationHours * 1 hours) -> startTime ^ (durationHours * 1 hours)
    function test_createAuction_endTime() public {
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, 1, 1, currTs + 1 minutes, 27);
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
    function testFuzz_createAuction(uint256 tokenId, uint256 startPrice, uint256 startTime, uint256 durationHours)
        public
    {
        vm.startPrank(seller1);
        appleNft.setApprovalForAll(auctionSysProxyAddr, true);

        try NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, tokenId, startPrice, startTime, durationHours) returns (
            uint256 auctionId
        ) {
            console.log(auctionId);
        } catch (bytes memory revertData) {
            bool isExpectedRevert =
                (
                // 开始价格报错
                keccak256(revertData) == keccak256(abi.encodeWithSignature("StartPriceMustGtZero()"))
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
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("NotNftOwner(address)", seller1))
                    // nft未授权给此拍卖合约报错
                    || keccak256(revertData) == keccak256(abi.encodeWithSignature("NftNotApproved()"))
            );
            assertTrue(isExpectedRevert, "Debug!");
        }

        vm.stopPrank();
    }

    // #endregion 创建拍卖 测试结束===================================================

    // #region 取消拍卖 测试开始==================================================
    // cancelAuction 测试成功场景
    function test_cancelAuction_success() public {
        vm.startPrank(seller1);

        // 创建拍卖
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);

        NFTAuctionV1.AuctionInfo memory infoBf = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(infoBf.isCreated, true);
        assertEq(getStorageNtfToken2AuctionId(infoBf.nftContract, infoBf.tokenId), auctionId);

        // 在当前时间下，时间快进1小时
        skip(1 minutes);
        // 验证emit
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionCancel(auctionId, seller1);
        // 取消拍卖
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);

        vm.stopPrank();

        // 验证值改变
        NFTAuctionV1.AuctionInfo memory infoAf = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(infoAf.isCreated, false);
        assertEq(getStorageNtfToken2AuctionId(infoAf.nftContract, infoAf.tokenId), 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller1.balance, seller1InitBalance);
    }

    // cancelAuction测试场景：拍卖没有创建 revert
    function test_cancelAuction_nonAuction() public {
        uint256 auctionId = 2;
        vm.expectRevert(abi.encodeWithSignature("AuctionNotExists(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);
    }

    // cancelAuction测试场景：取消拍卖的当前时间大于开始时间 revert
    function test_cancelAuction_geStartTime() public {
        vm.startPrank(seller1);

        // 创建拍卖
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);

        // 快进2个小时
        skip(2 hours);
        vm.expectRevert(abi.encodeWithSignature("AuctionAlreadyStarted(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);

        vm.stopPrank();
    }

    // cancelAuction测试场景：取消拍卖的当前时间等于开始时间 revert
    // kill mutate: block.timestamp < auction.startTime -> block.timestamp <= auction.startTime
    function test_cancelAuction_eqStartTime() public {
        vm.startPrank(seller1);

        // 创建拍卖
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);

        // 快进1个小时
        skip(1 hours);
        vm.expectRevert(abi.encodeWithSignature("AuctionAlreadyStarted(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);

        vm.stopPrank();
    }

    // cancelAuction测试场景：调用者不是卖家 revert
    function test_cancelAuction_notSeller1() public {
        vm.startPrank(seller1);
        // 创建拍卖
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSignature("NotAuctionSeller(address)", address(this)));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);
    }

    // cancelAuction测试场景：调用者不是卖家 revert
    // kill mutate: auction.seller == msg.sender -> auction.seller <= msg.sender
    function test_cancelAuction_notSeller2() public {
        vm.startPrank(seller1);
        // 创建拍卖
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);
        vm.stopPrank();

        address seller2 = makeAddr("seller2");
        vm.prank(seller2);
        vm.expectRevert(abi.encodeWithSignature("NotAuctionSeller(address)", seller2));
        NFTAuctionV1(auctionSysProxyAddr).cancelAuction(auctionId);
    }

    // #endregion 取消拍卖 测试结束===============================================

    // #region 拍卖出价 测试开始==================================================
    // bidAuction 测试成功场景：创建拍卖 -> 验证值 -> bidder1出价 -> 验证值 -> bidder1再此出价 -> 验证值 -> bidder2出价 -> 验证值
    function test_bidAuction_success() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);
        vm.stopPrank();
        // 初始值
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.currHighestPrice, 1);
        assertEq(info.highestBidder, address(0));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);

        // 时间快进2小时
        skip(2 hours);

        // bidder1出价
        uint256 _bidVal1 = 1.5 ether;
        bid(auctionId, bidder1, _bidVal1);

        // 验证
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info1.currHighestPrice, _bidVal1);
        assertEq(info1.highestBidder, bidder1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), 0);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidVal1);
        assertEq(bidder1.balance, bidder1InitBalance - _bidVal1);
        // kill mutate: auction.highestBidder != address(0) -> auction.highestBidder >= address(0)
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, address(0)), 0);

        // bidder1再次出价
        uint256 _bidVal12 = 1.8 ether;
        bid(auctionId, bidder1, _bidVal12);

        // 验证
        NFTAuctionV1.AuctionInfo memory info12 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info12.currHighestPrice, _bidVal12);
        assertEq(info12.highestBidder, bidder1);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), _bidVal1);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidVal1 + _bidVal12);
        assertEq(bidder1.balance, bidder1InitBalance - _bidVal1 - _bidVal12);

        // bidder2出价
        uint256 _bidVal2 = 2 ether;
        bid(auctionId, bidder2, _bidVal2);

        // 验证
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info2.currHighestPrice, _bidVal2);
        assertEq(info2.highestBidder, bidder2);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), _bidVal1 + _bidVal12);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidVal1 + _bidVal12 + _bidVal2);
        assertEq(bidder2.balance, bidder2InitBalance - _bidVal2);
    }

    // src/NFTAuctionV1.sol:220, auction.highestBidder != address(0) -> auction.highestBidder > address(0), 等价突变，可忽略

    // bidAuction测试场景：没有此拍卖 revert
    function test_bidAuction_nonAuction() public {
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionNotExists(uint256)", 1));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(1);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：出价者是卖方 revert
    function test_bidAuction_sellerBid() public {
        vm.startPrank(seller1);

        // 创建拍卖
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);
        // 测试
        deal(seller1, 10 ether);
        vm.expectRevert(abi.encodeWithSignature("SellerCannotBid()"));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(auctionId);
        assertEq(seller1.balance, seller1InitBalance + 10 ether);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);

        vm.stopPrank();
    }

    // bidAuction测试场景：当前时间小于拍卖开始时间 revert
    function test_bidAuction_leStartTime() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);
        vm.stopPrank();

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionNotStarted(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：当前时间等于拍卖开始时间 success
    function test_bidAuction_eqStartTime() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(1 hours);

        uint256 _bidder1Value = 1.5 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
    }

    // bidAuction测试场景：当前时间大于拍卖结束时间 revert
    function test_bidAuction_geEndTime() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(26 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionExpired(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：当前时间等于拍卖结束时间 revert
    function test_bidAuction_eqEndTime() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId =
            NFTAuctionV1(auctionSysProxyAddr).createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(25 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionExpired(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：出价人账户金额不足 revert EVMError:OutOfFunds
    function test_bidAuction_outOfFunds() public {
        address account1 = makeAddr("account1");
        vm.prank(account1);
        assertEq(account1.balance, 0);

        bool reverted;
        try NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1.5 ether}(1) {
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
    function test_bidAuction_leHighestPrice() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        uint256 currHighestPrice = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId).currHighestPrice;

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("NotOverCurrHighestPrice(uint256)", currHighestPrice));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 0.5 ether}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：出价=当前最高价 revert
    function test_bidAuction_eqHighestPrice() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("NotOverCurrHighestPrice(uint256)", 1 ether));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 1 ether}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
    }

    // bidAuction测试场景：合约接收到msg.value累计值超过uint256最大值
    // 关键点：合约里能接收的最大累计金额为uint256的最大值
    function test_bidAuction_overflowPayment() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        vm.startPrank(bidder1);
        // 第一次出价
        deal(bidder1, type(uint256).max);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: (type(uint256).max / 2)}(auctionId);
        // 第二次出价
        deal(bidder1, type(uint256).max);
        bool reverted;
        try NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: (type(uint256).max / 2 + 20 ether)}(auctionId) {
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
    function test_bidAuction_accOverflow() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        uint256 testValue = type(uint256).max - 20 ether;
        bytes32 finalSlot = getBidPriceReturnsSlot(auctionId, bidder1);
        vm.store(auctionSysProxyAddr, finalSlot, bytes32(testValue));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), testValue);

        skip(2 hours);

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("refundAfterBid()"));
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 21 ether}(auctionId);
        // 检查
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), testValue);
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.currHighestPrice, 1 ether);
        assertEq(info.highestBidder, address(0));
    }

    // bidAuction测试场景：记录某拍卖某出价者需要退回的金额累计相加超过uint256最大值 success
    function test_bidAuction_returnsMaxBoundary() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        uint256 testValue = type(uint256).max - 20 ether;
        bytes32 finalSlot = getBidPriceReturnsSlot(auctionId, bidder1);
        vm.store(auctionSysProxyAddr, finalSlot, bytes32(testValue));
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), testValue);

        skip(2 hours);

        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: 20 ether}(auctionId);
        // 检查
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), testValue);
        NFTAuctionV1.AuctionInfo memory info = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info.currHighestPrice, 20 ether);
        assertEq(info.highestBidder, bidder1);
    }

    // src/NFTAuctionV1.sol:216，(type(uint256).max - $.bidPriceReturns[auctionId][msg.sender]) -> (type(uint256).max ^ $.bidPriceReturns[auctionId][msg.sender])，属于等价突变，不存在安全风险，接受存活。

    // #endregion 拍卖出价 测试结束==============================================

    // #region 退款 测试结束==============================================
    // refund 测试成功场景
    function test_refund_success() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId);
        // 检查
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);

        // bidder2出价
        uint256 _bidder2Value = 20 ether;
        vm.prank(bidder2);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder2Value}(auctionId);
        // 检查
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), _bidder1Value);
        assertEq(bidder2.balance, bidder2InitBalance - _bidder2Value);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value + _bidder2Value);

        // bidder1退款
        vm.prank(bidder1);
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.Refund(auctionId, bidder1, _bidder1Value);
        NFTAuctionV1(auctionSysProxyAddr).refund(auctionId);
        // 检查
        assertEq(bidder1.balance, bidder1InitBalance);
        assertEq(NFTAuctionV1(auctionSysProxyAddr).getBidPriceReturns(auctionId, bidder1), 0);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder2Value);
    }

    // refund测试场景1： auctionId、msg.sender都不存在 退款 revert
    function test_refund_notRefund1() public {
        vm.expectRevert(abi.encodeWithSignature("NotRefund()"));
        NFTAuctionV1(auctionSysProxyAddr).refund(1);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
    }

    // refund测试场景2：出价未被超过Not refund revert
    function test_refund_notRefund2() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.startPrank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        // bidder1退款
        vm.expectRevert(abi.encodeWithSignature("NotRefund()"));
        NFTAuctionV1(auctionSysProxyAddr).refund(auctionId);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        vm.stopPrank();
    }

    // refund测试场景3： auctionId存在，msg.sender不存在 退款 revert
    function test_refund_notRefund3() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);

        // bidder2出价
        uint256 _bidder2Value = 20 ether;
        vm.prank(bidder2);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder2Value}(auctionId);
        assertEq(bidder2.balance, bidder2InitBalance - _bidder2Value);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value + _bidder2Value);

        // 默认账号退款
        vm.expectRevert(abi.encodeWithSignature("NotRefund()"));
        NFTAuctionV1(auctionSysProxyAddr).refund(auctionId);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value + _bidder2Value);
    }

    // refund测试场景：合约ETH不足，call转账失败，revert "Refund to bidder failed!"
    function test_refund_noETH() public {
        uint256 testValue = 10 ether;
        bytes32 finalSlot = getBidPriceReturnsSlot(1, bidder1);
        vm.store(auctionSysProxyAddr, finalSlot, bytes32(testValue));

        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("RefundTransferFailed(address,uint256)", bidder1, testValue));
        NFTAuctionV1(auctionSysProxyAddr).refund(1);
    }

    // src/NFTAuctionV1.sol:238, _price > 0 -> _price != 0, 等价突变

    // #endregion 退款 测试结束=================================================

    // #region 结束拍卖 测试开始=================================================
    // endAuction 测试成功场景1:没人竞拍
    function test_endAuction_success1() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        skip(26 hours);
        // 检查
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info1.isEnded, false);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), info1.seller);

        // 卖家结束拍卖
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionEnd(auctionId, info1.seller, address(0), 0, block.timestamp);
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        // 检查
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info2.isEnded, true);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), info1.seller);

        vm.stopPrank();
    }

    // endAuction 测试成功场景2:有人竞拍，买家结束拍卖
    function test_endAuction_success2() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        vm.startPrank(bidder1);
        uint256 bidder1Value = 2 ether;
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: bidder1Value}(auctionId);
        // 检查
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info1.isEnded, false);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), info1.seller);
        assertEq(info1.currHighestPrice, bidder1Value);
        assertEq(info1.highestBidder, bidder1);

        skip(24 hours);

        // 买家bidder1结束拍卖
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionEnd(
            auctionId, info1.highestBidder, info1.highestBidder, info1.currHighestPrice, block.timestamp
        );
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        // 检查
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info2.isEnded, true);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller1.balance, info2.currHighestPrice);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), info2.highestBidder);

        vm.stopPrank();
    }

    // endAuction 测试成功场景3:有人竞拍，卖家结束拍卖
    function test_endAuction_success3() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 2 ether;
        vm.startPrank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId);
        // 检查
        NFTAuctionV1.AuctionInfo memory info1 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info1.isEnded, false);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
        vm.stopPrank();

        skip(24 hours);

        // 卖家结束拍卖
        vm.startPrank(seller1);
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.AuctionEnd(
            auctionId, info1.seller, info1.highestBidder, info1.currHighestPrice, block.timestamp
        );
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        // 检查
        NFTAuctionV1.AuctionInfo memory info2 = NFTAuctionV1(auctionSysProxyAddr).getAuctionInfo(auctionId);
        assertEq(info2.isEnded, true);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(seller1.balance, seller1InitBalance + _bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), bidder1);
        vm.stopPrank();
    }

    // endAuction测试场景：拍卖没有创建
    function test_endAuction_notCreated() public {
        vm.prank(bidder1);
        vm.expectRevert(abi.encodeWithSignature("AuctionNotExists(uint256)", 1));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(1);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(bidder1.balance, bidder1InitBalance);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
    }

    // endAuction测试场景：拍卖没有到期 revert
    function test_endAuction_notExpired() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        // 结束拍卖
        vm.expectRevert(abi.encodeWithSignature("AuctionNotExpired(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
    }

    // endAuction测试场景：当前时间刚好=拍卖已到期时间 success
    function test_endAuction_endTimeMaxBoundary() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);

        skip(25 hours);
        // 结束拍卖
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
        vm.stopPrank();
    }

    // endAuction测试场景：拍卖已结束 revert
    function test_endAuction_ended() public {
        // seller1创建拍卖 -> seller1结束拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        skip(26 hours);
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        vm.stopPrank();

        // 结束拍卖
        vm.expectRevert(abi.encodeWithSignature("AuctionEnded(uint256)", auctionId));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
    }

    // endAuction测试场景：调用者不是卖家也不是获胜买家 revert
    // kill mutate: _bidderAddr == msg.sender -> _bidderAddr >= msg.sender
    function test_endAuction_notCaller1() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);

        skip(24 hours);

        // 结束拍卖
        // 构造一个大于auctionSysProxyAddr的地址
        address testAddr = address(uint160(bidder1) + uint160(1));
        vm.prank(testAddr);
        vm.expectRevert(abi.encodeWithSignature("NotHighestBidderOrSeller()"));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
    }

    // endAuction测试场景：调用者不是卖家也不是获胜买家 revert
    // kill mutate: _bidderAddr == msg.sender -> _bidderAddr <= msg.sender
    function test_endAuction_notCaller2() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);

        skip(24 hours);

        // 结束拍卖
        vm.expectRevert(abi.encodeWithSignature("NotHighestBidderOrSeller()"));
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
    }

    // endAuction测试场景：此合约转账失败 revert
    function test_endAuction_noPayable() public {
        // 创建拍卖
        vm.startPrank(seller1);
        appleNft.approve(auctionSysProxyAddr, APPLENFT_TOKENID_1);
        uint256 auctionId = NFTAuctionV1(auctionSysProxyAddr)
            .createAuction(appleNftAddr, APPLENFT_TOKENID_1, 1 ether, currTs + 1 hours, 24);
        vm.stopPrank();

        skip(2 hours);

        // bidder1出价
        uint256 _bidder1Value = 10 ether;
        vm.prank(bidder1);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: _bidder1Value}(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, auctionSysProxyInitBalance + _bidder1Value);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);

        skip(24 hours);
        // 改变此合约里的ETH
        vm.deal(auctionSysProxyAddr, 0);

        // 结束拍卖
        vm.prank(bidder1);
        vm.expectRevert();
        NFTAuctionV1(auctionSysProxyAddr).endAuction(auctionId);
        assertEq(seller1.balance, seller1InitBalance);
        assertEq(auctionSysProxyAddr.balance, 0);
        assertEq(bidder1.balance, bidder1InitBalance - _bidder1Value);
        assertEq(appleNft.ownerOf(APPLENFT_TOKENID_1), seller1);
    }

    // src/NFTAuctionV1.sol:269, _bidderAddr == address(0) -> _bidderAddr <= address(0), 等价突变，可忽略

    // #endregion 结束拍卖 测试结束==============================================

    // #region invariant testing ==============================================
    // 恒定不变测试：proxy合约balance永远>=出价之和-退款之和-交易之和
    function invariant_balance() public view {
        assertGe(
            auctionSysProxyAddr.balance,
            (v1Handler.ghost_bidSum() - v1Handler.ghost_refundSum() - v1Handler.ghost_endValueSum())
        );
    }

    // // invariant_balance复现
    // function test_reproduce_balance_issue() public {
    //     // setUp自动执行，部署合约
    //     // ========== 步骤1 create ==========
    //     //vm.startPrank(0xb6DDA0a9fBA4EB783d0cBc9aB44eC82702ed0305);
    //     v1Handler.create(
    //         467,
    //         89900047961061425986379404691942066161803187134324,
    //         278571866036544921172,
    //         715192216682093730948166430439482,
    //         374143318842495837892
    //     );
    //     //vm.stopPrank();

    //     // ========== 步骤2 create ==========
    //     //vm.startPrank(0x0000000000000000000000000000000000004505);
    //     v1Handler.create(
    //         1800000000000000000,
    //         355,
    //         3,
    //         2000000000000000000,
    //         21000000000000000000
    //     );
    //     //vm.stopPrank();

    //     // ========== 步骤3 bid ==========
    //     //vm.startPrank(0x0000000000000000000000000000000000000d36);
    //     v1Handler.bid(
    //         1099794980143326351922066467088116956885136440392,
    //         72475405630964902819927660838223,
    //         74351223583823190557526605416250411060347,
    //         1170686145495929657897793633421753363265652495068583590418888760101172548
    //     );
    //     //vm.stopPrank();

    //     // ========== 步骤4 create ==========
    //     //vm.startPrank(0x000000000000000000000000000000000000109b);
    //     v1Handler.create(
    //         24,
    //         24440054405305269366569402256811496959409073762505157381672968839269610695612,
    //         100000000000000000000,
    //         24440054405305269366569402256811496959409073762505157381672968839269610695612,
    //         82
    //     );
    //     //vm.stopPrank();

    //     // ========== 步骤5 bid ==========
    //     //vm.startPrank(0x0000000000000000000000000000000000003C24);
    //     v1Handler.bid(
    //         1000000000000000000,
    //         1800000000000000000,
    //         1800000000000000000,
    //         1000000000000000000
    //     );
    //     //vm.stopPrank();

    //     // ========== 步骤6 bid ==========
    //     //vm.startPrank(0x955487B7d3F76a7FB3541c0f63B5F8106680c536);
    //     v1Handler.bid(
    //         855071345745232009466725576130540106060422356619165391904676280659785499620,
    //         39030382427304357428776483520730882006646030029,
    //         3223177000343105299384652673253647601996376731843744068258199097222838,
    //         325034683592225282058780095899515
    //     );
    //     //vm.stopPrank();

    //     // 执行失衡校验，触发断言失败
    //     assertGe(auctionSysProxyAddr.balance, (v1Handler.ghost_bidSum() - v1Handler.ghost_refundSum() - v1Handler.ghost_endValueSum()));

    // }

    // 仅用于打印调试统计
    function invariant_callSummary() public view {
        v1Handler.callSummary();
    }
    // #endregion invariant testing ==============================================

    // #region 测试业务的公共函数================================================

    function bid(uint256 auctionId, address bidder, uint256 bidVal) public {
        vm.startPrank(bidder);
        vm.expectEmit(true, true, true, true, auctionSysProxyAddr, 1);
        emit NFTAuctionV1.BidInfo(auctionId, bidder, block.timestamp, bidVal);
        NFTAuctionV1(auctionSysProxyAddr).bidAuction{value: bidVal}(auctionId);
        vm.stopPrank();
    }

    // #endregion 测试业务的公共函数================================================
}
