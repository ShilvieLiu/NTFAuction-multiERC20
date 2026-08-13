// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {NFTAuctionV1} from "../../src/NFTAuctionV1.sol";
import {AppleNFT} from "../NFTAuctionV1.t.sol";

contract NFTAuctionV1Handler is Test {
    NFTAuctionV1 public v1;
    AppleNFT public nft;
    address public proxyAddr;
    address[] public actors;
    address internal currentActor;
    uint256 internal currentTokenId;
    uint256 internal tokenIdCount = 1;

    uint256 public ghost_bidSum;
    uint256 public ghost_refundSum;
    uint256 public ghost_endValueSum;

    // Call counters
    mapping(bytes4 => uint256) public calls;
    // Successful call counters
    mapping(bytes4 => uint256) public successCalls;

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useTokenId(uint256 tokenIdSeed) {
        tokenIdCount++;
        address seller = actors[bound(tokenIdSeed, 0, actors.length - 1)];
        vm.startPrank(seller);
        nft.mint(seller, tokenIdCount);
        nft.approve(proxyAddr, tokenIdCount);
        vm.stopPrank();
        _;
    }

    // 初始化：自动生产10个账号
    constructor(address _proxyAddr, NFTAuctionV1 _v1, AppleNFT _nft) {
        proxyAddr = _proxyAddr;
        nft = _nft;
        v1 = _v1;
        for (uint256 i = 0; i < 10; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
            vm.deal(actors[i], type(uint256).max);
        }
    }

    // 创建拍卖
    function create(
        uint256 startPrice,
        uint256 startTime,
        uint256 durationHours,
        uint256 actorSeed,
        uint256 tokenIdSeed
    ) external useTokenId(tokenIdSeed) useActor(actorSeed) {
        // bound 约束合法参数，减少无效revert
        //startPrice = bound(startPrice, 0.001 ether, 50 ether);
        startTime = bound(startTime, block.timestamp + 1 hours, block.timestamp + 1 weeks);
        durationHours = bound(durationHours, 24, 168); // 24h ~ 168h

        uint256[] memory allowedTokens = new uint256[](3);
        allowedTokens[0] = 0;
        allowedTokens[1] = 1;
        allowedTokens[2] = 2;

        vm.assume(startPrice > 0);
        vm.assume(nft.ownerOf(tokenIdCount) == currentActor);
        vm.assume(v1.getNtfToken2AuctionId(address(nft), tokenIdCount) == 0);

        successCalls[v1.createAuction.selector]++;
        v1.createAuction(address(nft), tokenIdCount, startPrice, startTime, durationHours, allowedTokens);
        calls[v1.createAuction.selector]++;
    }

    // 取消拍卖
    function cancel(uint256 auctionIdSeed, uint256 actorSeed, uint256 timeSeed) external useActor(actorSeed) {
        vm.assume(v1.getAuctionCount() > 0);
        uint256 auctionId = bound(auctionIdSeed, 1, v1.getAuctionCount());

        NFTAuctionV1.AuctionInfo memory auction = v1.getAuctionInfo(auctionId);
        vm.assume(auction.isCreated);
        vm.assume(auction.seller == currentActor);

        uint256 time = bound(timeSeed, 1, auction.startTime - 1);
        vm.warp(time);

        successCalls[v1.cancelAuction.selector]++;
        v1.cancelAuction(auctionId);
        calls[v1.cancelAuction.selector]++;
    }

    // 出价
    function bid(uint256 auctionIdSeed, uint256 actorSeed, uint256 timeSeed, uint256 priceSeed)
        external
        useActor(actorSeed)
    {
        vm.assume(v1.getAuctionCount() > 0);
        uint256 auctionId = bound(auctionIdSeed, 1, v1.getAuctionCount());

        NFTAuctionV1.AuctionInfo memory auction = v1.getAuctionInfo(auctionId);
        vm.assume(auction.isCreated);
        vm.assume(auction.seller != currentActor);

        uint256 bidPrice = bound(priceSeed, auction.currHighestPrice + 1, type(uint256).max);
        console.log("bidPrice:", bidPrice);

        uint256 time = bound(timeSeed, auction.startTime, auction.endTime - 1);
        vm.warp(time);

        successCalls[v1.bidAuction.selector]++;
        v1.bidAuction{value: bidPrice}(auctionId, 0, 0);
        calls[v1.bidAuction.selector]++;

        ghost_bidSum = ghost_bidSum + bidPrice;
    }

    // 退款
    function withdraw(uint256 auctionIdSeed, uint256 actorSeed) external useActor(actorSeed) {
        vm.assume(v1.getAuctionCount() > 0);
        uint256 auctionId = bound(auctionIdSeed, 1, v1.getAuctionCount());

        uint256 value = v1.getBidPriceReturns(auctionId, currentActor, 0);
        vm.assume(value > 0);

        successCalls[v1.refund.selector]++;
        v1.refund(auctionId, 0);
        calls[v1.refund.selector]++;

        ghost_refundSum = ghost_refundSum + value;
    }

    // 结束拍卖
    function end(uint256 auctionIdSeed, uint256 actorSeed) external useActor(actorSeed) {
        vm.assume(v1.getAuctionCount() > 0);
        uint256 auctionId = bound(auctionIdSeed, 1, v1.getAuctionCount());

        NFTAuctionV1.AuctionInfo memory auction = v1.getAuctionInfo(auctionId);
        vm.assume(auction.isCreated);
        vm.assume(auction.isEnded != true);
        vm.assume(currentActor == auction.seller || currentActor == auction.highestBidder);

        vm.warp(block.timestamp + auction.endTime);

        successCalls[v1.endAuction.selector]++;
        v1.endAuction(auctionId);
        calls[v1.endAuction.selector]++;

        if (auction.highestBidder != address(0)) {
            ghost_endValueSum = ghost_endValueSum + auction.currHighestPrice;
        }
    }

    function callSummary() external view {
        console.log("createAuction calls:", calls[v1.createAuction.selector]);
        console.log("createAuction successful calls:", successCalls[v1.createAuction.selector]);

        console.log("cancelAuction calls:", calls[v1.cancelAuction.selector]);
        console.log("cancelAuction successful calls:", successCalls[v1.cancelAuction.selector]);

        console.log("bidAuction calls:", calls[v1.bidAuction.selector]);
        console.log("bidAuction successful calls:", successCalls[v1.bidAuction.selector]);

        console.log("refund calls:", calls[v1.refund.selector]);
        console.log("refund successful calls:", successCalls[v1.refund.selector]);

        console.log("endAuction calls:", calls[v1.endAuction.selector]);
        console.log("endAuction successful calls:", successCalls[v1.endAuction.selector]);
    }
}
