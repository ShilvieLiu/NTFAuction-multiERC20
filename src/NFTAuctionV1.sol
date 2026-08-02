// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {console} from "forge-std/console.sol";

contract NFTAuctionV1 is Initializable, OwnableUpgradeable, UUPSUpgradeable, ERC721Upgradeable {
    struct AuctionInfo {
        uint256 auctionId;
        uint256 tokenId;
        uint256 startPrice; // 起拍价
        uint256 startTime; // 拍卖开始时间
        uint256 durationHours; // 持续时间(小时)
        uint256 endTime; // 拍卖结束时间
        uint256 currHighestPrice; // 当前最高价
        address highestBidder; // 当前最高价出价人
        address nftContract; // NFT合约地址:支持各种各样的NFT在此合约拍卖
        address seller; // 卖家
        bool isCreated; // 是否创建了拍卖
        bool isEnded; // 是否拍卖已结束
    }

    /// @custom:storage-location erc7201:nftauction.storage.auction.v1
    struct AuctionStorage {
        uint256 auctionId; // 是拍卖ID，同时也是拍卖个数
        mapping(address ntfContract => mapping(uint256 tokenId => uint256 auctionId)) ntfToken2AuctionId; // 已创建的拍卖
        mapping(uint256 auctionId => AuctionInfo) auctions; // 拍卖的详情   
        mapping(uint256 auctionId => mapping(address bidder => uint256 bidPrice)) bidPriceReturns; // 出价退回
    }

    // keccak256(abi.encode(uint256(keccak256("nftauction.storage.auction.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AUCTION_STORAGE_LOCATION =
        0x4c48d9668da3b85d45dd9d4fe97ed0e93efd4218c47ce0da3f0ab7fa4d259a00;

    function _getAuctionStorage() private pure returns (AuctionStorage storage $) {
        assembly {
            $.slot := AUCTION_STORAGE_LOCATION
        }
    }

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 startTime,
        uint256 endTime
    );

    event AuctionCancel(uint256 indexed auctionId, address indexed operator);

    event BidInfo(uint256 indexed auctionId, address indexed bidder, uint256 bidTime, uint256 bidPrice);

    event AuctionEnd(uint256 indexed auctionId, address indexed operator, address indexed winner, uint256 price, uint256 endTime);

    event Refund(uint256 indexed auctionId, address indexed withdrawee, uint256 price);

    // 开始时间必须大于0
    error StartPriceMustGtZero();

    // 持续时间超过指定范围
    error DurationHoursOutOfRange();

    // 开始时间必须大于当前时间
    error StartTimeMustGtCurrTime();

    // 开始时间超过最大值
    error StartTimeOverMaxValue();

    // 无效的nftContract地址
    error InvalidNftContractAddr();

    // 不是NFT的所有者
    error NotNftOwner(address caller);

    // NFT没有授权
    error NftNotApproved();

    // 拍卖不存在
    error AuctionNotExists(uint256 auctionId);

    // 拍卖已存在
    error AuctionAlreadyExists(uint256 auctionId);

    // 拍卖已经开始
    error AuctionAlreadyStarted(uint256 auctionId);

    // 不是拍卖的卖家
    error NotAuctionSeller(address account);
    
    // 卖家不能出价
    error SellerCannotBid();

    // 拍卖没有开始
    error AuctionNotStarted(uint256 auctionId);

    // 拍卖已过期
    error AuctionExpired(uint256 auctionId);

    // 没有超过当前最高价
    error NotOverCurrHighestPrice(uint256 currHighestPrice);

    // 退款之后再出价
    error refundAfterBid();

    // 没有退款
    error NotRefund();

    // 退款交易失败
    error RefundTransferFailed(address to, uint256 price);

    // 拍卖没有到期
    error AuctionNotExpired(uint256 auctionId);

    // 拍卖已结束
    error AuctionEnded(uint256 auctionId);

    // 不是获胜bidder也不是卖家
    error NotHighestBidderOrSeller();

    // 拍卖结束转账失败
    error EndAuctionTransferFailed(address to, uint256 price);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, string memory nftName, string memory nftSymbol) public initializer {
        __Ownable_init(initialOwner);
        __ERC721_init(nftName, nftSymbol);
    }

    // 强制开发者自定义谁才能升级合约
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        //require(newImplementation != address(0), "New implementation is not zero address!"); // 可省略，因为UUPSUpgradeable里已校验
    }

    /**
     * 内部：根据auctionId获取某个拍卖详情
     * @param auctionId 拍卖ID
     */
    function _getAuctionInfo(uint256 auctionId) internal view returns (AuctionInfo storage) {
        AuctionStorage storage $ = _getAuctionStorage();
        return $.auctions[auctionId];
    }

    /**
     * 外部：根据auctionId获取某个拍卖详情
     * @param auctionId 拍卖ID
     */
    function getAuctionInfo(uint256 auctionId) external view returns (AuctionInfo memory) {
        return _getAuctionInfo(auctionId);
    }    

    /** 获取某拍卖某出价人该退回的总金额
     * @param auctionId 拍卖Id
     * @param bidder 出价人地址
     */
    function getBidPriceReturns(uint256 auctionId, address bidder) public view returns (uint256) {
        AuctionStorage storage $ = _getAuctionStorage();
        return $.bidPriceReturns[auctionId][bidder];
    }

    /** 获取某合约某token是否已创建拍卖
     * @param nftContract NFT合约地址
     * @param tokenId NFT tokenId
     */
    function getNtfToken2AuctionId(address nftContract, uint256 tokenId) public view returns (uint256) {
        AuctionStorage storage $ = _getAuctionStorage();
        return $.ntfToken2AuctionId[nftContract][tokenId];
    }

    /**
     * 获取拍卖数量
     */
    function getAuctionCount() public view returns (uint256) {
        AuctionStorage storage $ = _getAuctionStorage();
        return $.auctionId;
    }

    /**
     * @dev 创建拍卖
     * @param nftContract 待拍卖NFT所在的合约地址：地址不能为address(0)
     * @param tokenId 待拍卖NFT所在的合约里的tokenId
     * @param startPrice 拍卖的起始价：必须大于0
     * @param startTime 拍卖的开始时间：必须大于当前时间,并且小于当前时间+1weeks
     * @param durationHours 拍卖的持续时间（小时）：必须大于等于24，并且小于168
     */
    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 startTime,
        uint256 durationHours
    ) public returns (uint256) {
        // 检查：开始价格必须大于0
        if(startPrice == 0) revert StartPriceMustGtZero();

        // 检查：持续时间必须在24-168小时之间
        if(durationHours < 24 || durationHours > 168) revert DurationHoursOutOfRange();
        
        uint256 _currTs = block.timestamp;
        console.log("_currTs of contract:", _currTs);  
        // 检查：开始时间必须大于当前时间
        if(startTime <= _currTs) revert StartTimeMustGtCurrTime();

        // 检查：开始时间必须在当前时间一周内
        if(startTime > _currTs + 1 weeks) revert StartTimeOverMaxValue();

        // 检查：待创建拍卖的NF所在的合约地址不能为0
        if(nftContract == address(0)) revert InvalidNftContractAddr();

        // 检查：该合约下的NFT没有已创建拍卖
        AuctionStorage storage $ = _getAuctionStorage();
        uint256 _auctionId = $.ntfToken2AuctionId[nftContract][tokenId];
        if(_auctionId > 0) revert AuctionAlreadyExists(_auctionId);       

        // 检查：调用者必须是tokenId的所有者
        IERC721 nft = IERC721(nftContract);
        if(msg.sender != nft.ownerOf(tokenId)) revert NotNftOwner(msg.sender);

        // 检查：待拍卖的NFT必须已授权给此合约
        if(!(address(this) == nft.getApproved(tokenId) || nft.isApprovedForAll(msg.sender, address(this)))) revert NftNotApproved();

        _auctionId = ++$.auctionId;
        uint256 _endTime = startTime + (durationHours * 1 hours);
        $.auctions[_auctionId] = AuctionInfo({
            auctionId: _auctionId,
            tokenId: tokenId,
            startPrice: startPrice,
            startTime: startTime,
            durationHours: durationHours,
            endTime: _endTime,
            currHighestPrice: startPrice,
            highestBidder: address(0),
            nftContract: nftContract,
            seller: msg.sender,
            isCreated: true,
            isEnded: false
        });
        $.ntfToken2AuctionId[nftContract][tokenId] = _auctionId;

        emit AuctionCreated(_auctionId, msg.sender, nftContract, tokenId, startPrice, startTime, _endTime);

        return _auctionId;
    }

    /**
     * 拍卖没有开始之前，可取消拍卖
     * @param auctionId 拍卖ID
     */
    function cancelAuction(uint256 auctionId) public {
        AuctionStorage storage $ = _getAuctionStorage();
        AuctionInfo storage auction = $.auctions[auctionId];

        // 检查：拍卖已创建
        if(!auction.isCreated) revert AuctionNotExists(auctionId);
        
        // 检查：当前时间必须小于拍卖开始时间
        if(block.timestamp >= auction.startTime) revert AuctionAlreadyStarted(auctionId);

        // 检查：调用者是卖家
        if(auction.seller != msg.sender) revert NotAuctionSeller(msg.sender);
        
        // 更新拍卖信息
        auction.isCreated = false;
        // 移除此拍卖ID
        $.ntfToken2AuctionId[auction.nftContract][auction.tokenId] = 0;

        emit AuctionCancel(auctionId, msg.sender);
    }

    /**
     * 拍卖出价
     * 注意：卖者不能对自己的拍卖出价
     * @param auctionId 拍卖ID
     */
    function bidAuction(uint256 auctionId) public payable {
        AuctionStorage storage $ = _getAuctionStorage();
        AuctionInfo storage auction = $.auctions[auctionId];
        // 检查:拍卖已创建
        if(!auction.isCreated) revert AuctionNotExists(auctionId);

        // 检查：出价者不能是卖方
        if(auction.seller == msg.sender) revert SellerCannotBid();

        uint256 _currTime = block.timestamp;
        // 检查：当前时间必须大于等于拍卖开始时间
        if(auction.startTime > _currTime) revert AuctionNotStarted(auctionId);

        // 检查：当前时间必须小于拍卖结束时间
        if(auction.endTime <= _currTime) revert AuctionExpired(auctionId);

        // 检查：当前出价必须高于当前最高出价       
        if(auction.currHighestPrice >= msg.value) revert NotOverCurrHighestPrice(auction.currHighestPrice);

        // 检查：出价人的出价+待退款<uint256.max
        // msg.value + $.bidPriceReturns[auctionId][msg.sender] <= type(uint256).max这样写会出现a+b超过uint256最大值而报错的风险，所以改为如下写法        
        // 由于合约里可以接收累计的最大金额为uint256的最大值，同时拍卖每次出价都需高于前一次出价，因此任何出价人累计的金额永远都不可能超过uint256的最大值，所以此检查为了节约gas可以省略。也可为了安全性使用。
        if(msg.value > type(uint256).max - $.bidPriceReturns[auctionId][msg.sender]) revert refundAfterBid();

        // 记录某拍卖某出价者需要退回的金额
        if (auction.highestBidder != address(0)) {
            $.bidPriceReturns[auctionId][auction.highestBidder] += auction.currHighestPrice;
        }

        // 更新最新最高出价、出价者
        auction.currHighestPrice = msg.value;
        auction.highestBidder = msg.sender;       

        emit BidInfo(auctionId, msg.sender, _currTime, msg.value);
    }    

    /**
     * 退款
     * @param auctionId 拍卖ID
     */
    function refund(uint256 auctionId) public {
        AuctionStorage storage $ = _getAuctionStorage();       
        uint256 _price = $.bidPriceReturns[auctionId][msg.sender];
        if(_price == 0) revert NotRefund(); 

        $.bidPriceReturns[auctionId][msg.sender] = 0;
        (bool success,) = payable(msg.sender).call{value: _price}("");
        if(!success) revert RefundTransferFailed(msg.sender, _price);

        emit Refund(auctionId, msg.sender, _price);
    }

    /**
     * 拍卖到期后，拍卖获胜者或者卖者可以结束拍卖
     * @param auctionId 拍卖ID
     */
    function endAuction(uint256 auctionId) public {
        AuctionInfo storage auction = _getAuctionInfo(auctionId);
        // 检查:拍卖已创建
        if(!auction.isCreated) revert AuctionNotExists(auctionId);

        // 检查：拍卖已到期
        if(auction.endTime > block.timestamp) revert AuctionNotExpired(auctionId);

        // 检查：拍卖没有结束
        if(auction.isEnded == true) revert AuctionEnded(auctionId);

        // 拍卖已结束!检查 调用者是否是当前最高出价者 或者 调用者是否是卖家  
        address _sellerAddr = auction.seller;
        address _bidderAddr = auction.highestBidder;
        if(_bidderAddr != msg.sender && _sellerAddr != msg.sender) revert NotHighestBidderOrSeller();

        auction.isEnded = true;
        uint256 currTs = block.timestamp;
        if (_bidderAddr == address(0)) {
            // 没有人竞拍
            emit AuctionEnd(auctionId, msg.sender, _bidderAddr, 0, currTs);
        } else {
            // 有人竞拍
            /// 1. 卖者转移NFT给拍卖获胜者
            IERC721(auction.nftContract).safeTransferFrom(_sellerAddr, _bidderAddr, auction.tokenId);
            /// 2. 此合约把钱转给卖者
            uint256 _price = auction.currHighestPrice;
            (bool success,) = payable(_sellerAddr).call{value: _price}("");
            if(!success) revert EndAuctionTransferFailed(_sellerAddr, _price);

            emit AuctionEnd(auctionId, msg.sender, _bidderAddr, _price, currTs);
        }
    }
}
