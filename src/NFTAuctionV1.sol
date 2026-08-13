// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {console} from "forge-std/console.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";


contract NFTAuctionV1 is Initializable, OwnableUpgradeable, UUPSUpgradeable, ERC721Upgradeable {
    using SafeERC20 for IERC20;

    AggregatorV3Interface public dataFeed;

    // 出价币种类型
    //enum BidToken {ETH, USDT, USDC, DAI} //底层是uint，所以调用者可以随意输入其它数字，所以参数是它需要校验

    mapping(uint256 token => bool) enabledTokens;
    mapping(uint256 token => address tokenAddr) tokenAddrs;
    mapping(uint256 token => address feedAddr) feedAddrs;    
    uint256 public tokenCount;
    struct TokenInitConfig {
        uint256 token;
        address tokenAddr;
        address feedAddr;
    }
    
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
        bool isToken; // 是否允许Token出价
        uint256[] allowedTokens; // 默认使用ETH,但允许至少一种Token出价则使用USD做对比
        uint256 highestBidToken; // 当前最高价的token类型
        uint256 currHighestTokenAmount; // 当前最高价的token数量
        uint8 currHighestDecimals; // 当前最高价的Decimals
    }

    /// @custom:storage-location erc7201:nftauction.storage.auction.v1
    struct AuctionStorage {
        uint256 auctionId; // 是拍卖ID，同时也是拍卖个数
        mapping(address ntfContract => mapping(uint256 tokenId => uint256 auctionId)) ntfToken2AuctionId; // 已创建的拍卖
        mapping(uint256 auctionId => AuctionInfo) auctions; // 拍卖的详情
        mapping(uint256 auctionId => mapping(address bidder => mapping(uint256 token => uint256 bidPrice))) bidPriceReturns; // 出价退回
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
        uint256 endTime,
        bool isToken,
        uint256[] allowedTokens,
        uint8 startDecimals,
        uint256 startTokenAmount
    );

    event AuctionCancel(uint256 indexed auctionId, address indexed operator);

    event BidInfo(uint256 indexed auctionId, address indexed bidder, uint256 bidTime, uint256 bidPrice, uint256 token, uint256 tokenAmount, uint8 bidDecimals);

    event AuctionEnd(
        uint256 indexed auctionId, address indexed operator, address indexed winner, uint256 price, uint256 endTime, uint256 token, uint256 tokenAmount
    );

    event Refund(uint256 indexed auctionId, address indexed withdrawee, uint256 indexed token, uint256 price);

    event GetUSDByToken(uint256 indexed currTime, uint256 indexed token, uint8 tokenDecimals, uint256 updateTime, int256 rawPrice, uint8 feedDecimals, uint8 decimals, uint256 usd18Value);


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

    // 无效的ERC20代币类型
    error InvalidBidToken();

    // 代币列表为空
    error TokenListEmpty();

    // 无效的实际价格
    error InvalidRawPrice(int256 rawPrice);

    // 旧的实际价格
    //error StaleRawPrice(int256 rawPrice, uint256 updateTime, uint256 runTime);

    // 无效的出价数量
    error InvalidBidAmount();

    // 无效的喂价地址
    error InvalidFeedAddr();

    // 无效的代币地址
    error InvalidTokenAddr();

    // 无效的允许token
    error InvalidAllowedToken(uint256 token);

    // 允许的token数量超标了
    error AllowedTokenSizeOver();

    // token配置存在
    error TokenCfgExists();

    // token配置不存在
    error TokenCfgNotExists();

    modifier tokenCfgNotExists(uint256 token) {
        if(!enabledTokens[token]) revert TokenCfgNotExists();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, string memory nftName, string memory nftSymbol, TokenInitConfig[] memory tokenInitList) public initializer {
        __Ownable_init(initialOwner);
        __ERC721_init(nftName, nftSymbol);

        tokenCount = tokenInitList.length;
        if(tokenCount > 10) revert AllowedTokenSizeOver();
        for(uint256 i = 0; i < tokenCount; i++){
            TokenInitConfig memory cfg = tokenInitList[i];
            if(cfg.token > 0){
                 if(cfg.tokenAddr == address(0)) revert InvalidTokenAddr();
            }           
            if(cfg.feedAddr == address(0)) revert InvalidFeedAddr();
            enabledTokens[cfg.token] = true;
            tokenAddrs[cfg.token] = cfg.tokenAddr;
            feedAddrs[cfg.token] = cfg.feedAddr;
        }
    }

    // 强制开发者自定义谁才能升级合约
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        //require(newImplementation != address(0), "New implementation is not zero address!"); // 可省略，因为UUPSUpgradeable里已校验
    }    

    /**
     * 仅管理员：添加新token配置
     * @param token ID
     * @param tokenAddr 代币合约地址
     * @param feedAddr 代币/USD地址
     */
    function addTokenCfg(uint256 token, address tokenAddr, address feedAddr) public onlyOwner {
        if(enabledTokens[token]) revert TokenCfgExists();
        if(tokenAddr == address(0)) revert InvalidTokenAddr();
        if(feedAddr == address(0)) revert InvalidFeedAddr();
        tokenCount++;
        enabledTokens[token] = true;
        tokenAddrs[token] = tokenAddr;
        feedAddrs[token] = feedAddr;        
    }

    /**
     * 仅管理员：修改指定token配置
     * @param token ID
     * @param tokenAddr 代币合约地址
     * @param feedAddr 代币/USD地址
     */
    function updTokenCfg(uint256 token, address tokenAddr, address feedAddr) public onlyOwner tokenCfgNotExists(token){
        if(tokenAddr != address(0)) tokenAddrs[token] = tokenAddr;
        if(feedAddr != address(0)) feedAddrs[token] = feedAddr;
    }

    /**
     * 仅管理员：删除指定token配置
     * @param token ID
     */
    function delTokenCfg(uint256 token) public onlyOwner tokenCfgNotExists(token){
        enabledTokens[token] = false;
        tokenAddrs[token] = address(0);
        feedAddrs[token] = address(0);
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

    /**
     * 获取某拍卖某出价人某代币该退回的总金额
     * @param auctionId 拍卖Id
     * @param bidder 出价人地址
     */
    function getBidPriceReturns(uint256 auctionId, address bidder, uint256 token) public view returns (uint256) {
        AuctionStorage storage $ = _getAuctionStorage();
        return $.bidPriceReturns[auctionId][bidder][token];
    }

    /**
     * 获取某合约某token是否已创建拍卖
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
     * 返回是否按照ETH竞价还是USD竞价
     * 返回false：按ETH竞价
     * 返回true：按USD竞价
     */
    function _getIsToken(uint256[] calldata allowedTokens) internal view returns (bool) {        
        bool _isToken = false;
        uint256 _token;
        for(uint256 i = 0 ; i < allowedTokens.length ; i++){
            _token = allowedTokens[i];
            if(!enabledTokens[_token]) revert InvalidAllowedToken(_token);
            if(!_isToken) {
                if(_token > 0) _isToken = true;
            }            
        }
        return _isToken;
    }

    /**
     * @dev 创建拍卖
     * @param nftContract 待拍卖NFT所在的合约地址：地址不能为address(0)
     * @param tokenId 待拍卖NFT所在的合约里的tokenId
     * @param startPrice 拍卖的起始价：必须大于0，并且默认以ETH wei单位
     * @param startTime 拍卖的开始时间：必须大于当前时间,并且小于当前时间+1weeks
     * @param durationHours 拍卖的持续时间（小时）：必须大于等于24，并且小于168
     */
    function createAuction(
        address nftContract,
        uint256 tokenId,
        uint256 startPrice,
        uint256 startTime,
        uint256 durationHours,
        uint256[] calldata allowedTokens
    ) public returns (uint256) {
        // 检查：开始价格必须大于0
        if (startPrice == 0) revert StartPriceMustGtZero();

        // 检查：持续时间必须在24-168小时之间
        if (durationHours < 24 || durationHours > 168) revert DurationHoursOutOfRange();

        uint256 _currTs = block.timestamp;
        console.log("_currTs of contract:", _currTs);
        // 检查：开始时间必须大于当前时间
        if (startTime <= _currTs) revert StartTimeMustGtCurrTime();

        // 检查：开始时间必须在当前时间一周内
        if (startTime > _currTs + 1 weeks) revert StartTimeOverMaxValue();

        // 检查：待创建拍卖的NF所在的合约地址不能为0
        if (nftContract == address(0)) revert InvalidNftContractAddr();

        // 检查：该合约下的NFT没有已创建拍卖
        AuctionStorage storage $ = _getAuctionStorage();
        uint256 _auctionId = $.ntfToken2AuctionId[nftContract][tokenId];
        if (_auctionId > 0) revert AuctionAlreadyExists(_auctionId);

        // 检查：调用者必须是tokenId的所有者
        IERC721 nft = IERC721(nftContract);
        if (msg.sender != nft.ownerOf(tokenId)) revert NotNftOwner(msg.sender);

        // 检查：待拍卖的NFT必须已授权给此合约
        if (!(address(this) == nft.getApproved(tokenId) || nft.isApprovedForAll(msg.sender, address(this)))) {
            revert NftNotApproved();
        }

        // 检查：allowedTokens长度不能超过可允许的token配置的最大长度
        if(allowedTokens.length > tokenCount) revert AllowedTokenSizeOver();

        bool _isToken = _getIsToken(allowedTokens);

        //以USD竞价，需将ETH的开始价格转成对应的USD作为起拍价
        uint8 _decimals = 18;
        uint256 _startTokenAmount = startPrice;    
        if(_isToken) {
            uint256 _usd18Value;
            ( , , , , _decimals, _usd18Value) = getUSDByToken(0, startPrice);
            startPrice = _usd18Value;
        } 
       
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
            isEnded: false,
            isToken: _isToken,
            allowedTokens: allowedTokens,
            highestBidToken: 0,
            currHighestTokenAmount: _startTokenAmount,
            currHighestDecimals: _decimals
        });
        $.ntfToken2AuctionId[nftContract][tokenId] = _auctionId;

        emit AuctionCreated(_auctionId, msg.sender, nftContract, tokenId, startPrice, startTime, _endTime, _isToken, allowedTokens, _decimals, _startTokenAmount);

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
        if (!auction.isCreated) revert AuctionNotExists(auctionId);

        // 检查：当前时间必须小于拍卖开始时间
        if (block.timestamp >= auction.startTime) revert AuctionAlreadyStarted(auctionId);

        // 检查：调用者是卖家
        if (auction.seller != msg.sender) revert NotAuctionSeller(msg.sender);

        // 更新拍卖信息
        auction.isCreated = false;
        // 移除此拍卖ID
        $.ntfToken2AuctionId[auction.nftContract][auction.tokenId] = 0;

        emit AuctionCancel(auctionId, msg.sender);
    }    

    /**
     * 各种代币转成对应的USD价格
     * @param token 出价代币类型
     */
    function getUSDByToken(uint256 token, uint256 tokenAmount) public virtual returns (uint8 tokenDecimals, int256 rawPrice, uint256 updateTime, uint8 feedDecimals, uint8 decimals, uint256 usd18Value) {
        //测试网
        address feedAddr = feedAddrs[token];
        if(feedAddr == address(0)) revert InvalidFeedAddr();

        //获取代币的代币精度
        address tokenAddr = tokenAddrs[token];
        if(token == 0) {
            tokenDecimals = 18;
        } else {
            if(tokenAddr == address(0)) revert InvalidTokenAddr();
            tokenDecimals = IERC20Metadata(tokenAddr).decimals();
        }                

        dataFeed = AggregatorV3Interface(feedAddr);
        uint256 _currTs = block.timestamp;
        (, rawPrice, , updateTime, ) = dataFeed.latestRoundData();        
        feedDecimals = dataFeed.decimals();

        // 安全校验（非常重要，上线必须保留）
        if(rawPrice < 0) revert InvalidRawPrice(rawPrice);
        // 价格超过1小时未更新，判定失效       
        // if(_currTs - updateTime > 3600) revert StaleRawPrice(rawPrice, updateTime, _currTs);

        // 算出统一18位的usdValue（用于事件、存储）
        usd18Value = tokenAmount * uint256(rawPrice) * (10 ** uint256(tokenDecimals));
        //console.log("tokenAmount * uint256(rawPrice):", (tokenAmount * uint256(rawPrice)));
        decimals = tokenDecimals + feedDecimals;

        emit GetUSDByToken(_currTs, token, tokenDecimals, updateTime, rawPrice, feedDecimals, decimals, usd18Value);
    }

    function _isTokenAllowed(uint256[] storage allowedTokens, uint256 token) internal view returns (bool) {
        for(uint8 i = 0 ; i < allowedTokens.length ; i++){
            if(allowedTokens[i] == token) return true;
        }
        return false;
    }

    function _bidLogic(
        uint256 auctionId,
        AuctionStorage storage $,
        AuctionInfo storage auction,
        address bidder,
        uint256 bidPrice,
        uint256 bidToken,
        uint256 bidAmount,
        uint256 currTime,
        uint8 bidDecimals
    ) internal {
        // 检查：当前出价必须高于当前最高出价
        if (auction.currHighestPrice >= bidPrice) revert NotOverCurrHighestPrice(auction.currHighestPrice);

        // 检查：出价人的出价+待退款<uint256.max
        // msg.value + $.bidPriceReturns[auctionId][msg.sender] <= type(uint256).max这样写会出现a+b超过uint256最大值而报错的风险，所以改为如下写法
        // 由于合约里可以接收累计的最大金额为uint256的最大值，同时拍卖每次出价都需高于前一次出价，因此任何出价人累计的金额永远都不可能超过uint256的最大值，所以此检查为了节约gas可以省略。也可为了安全性使用。        
        if (bidAmount > type(uint256).max - $.bidPriceReturns[auctionId][msg.sender][bidToken]) revert refundAfterBid();       

        // 记录某拍卖某出价者需要退回的金额
        if (auction.highestBidder != address(0)) {            
            $.bidPriceReturns[auctionId][auction.highestBidder][auction.highestBidToken] += auction.currHighestTokenAmount;            
        }       

        // 更新最新最高出价、出价者
        auction.currHighestPrice = bidPrice;
        auction.highestBidder = bidder;        
        auction.highestBidToken = bidToken;
        auction.currHighestTokenAmount = bidAmount;

        emit BidInfo(auctionId, bidder, currTime, bidPrice, bidToken, bidAmount, bidDecimals);
    }
    

    /**
     * 拍卖出价
     * 注意：卖者不能对自己的拍卖出价
     * @param auctionId 拍卖ID
     */
    function bidAuction(uint256 auctionId, uint256 token, uint256 amount) public payable {
        AuctionStorage storage $ = _getAuctionStorage();
        AuctionInfo storage auction = $.auctions[auctionId];
        // 检查:拍卖已创建
        if (!auction.isCreated) revert AuctionNotExists(auctionId);

        // 检查：出价者不能是卖方
        if (auction.seller == msg.sender) revert SellerCannotBid();

        uint256 _currTime = block.timestamp;
        // 检查：当前时间必须大于等于拍卖开始时间
        if (auction.startTime > _currTime) revert AuctionNotStarted(auctionId);

        // 检查：当前时间必须小于拍卖结束时间
        if (auction.endTime <= _currTime) revert AuctionExpired(auctionId);

        uint256 _price;
        uint8 _decimals = 18;
        if(auction.isToken) {
            // 可以Token出价，则使用USD比大小
            if(msg.value > 0) {
                // ETH出价=================================
                ( , , , , _decimals, _price) = getUSDByToken(0, msg.value);
                _bidLogic(auctionId, $, auction, msg.sender, _price, 0, msg.value, _currTime, _decimals);
               
            } else {
                // Token出价==============================
                if(amount == 0) revert InvalidBidAmount();
                if(!_isTokenAllowed(auction.allowedTokens, token)) revert InvalidBidToken();
                // Token转账到此合约
                IERC20(tokenAddrs[token]).safeTransferFrom(msg.sender, address(this), amount);
                ( , , , , _decimals, _price) = getUSDByToken(token, amount);
                _bidLogic(auctionId, $, auction, msg.sender, _price, token, amount, _currTime, _decimals);
            }

        } else {
            // 仅ETH出价，使用ETH比大小=====================
            _bidLogic(auctionId, $, auction, msg.sender, msg.value, 0, msg.value, _currTime, _decimals);            
        }        
    }

    /**
     * 退款
     * @param auctionId 拍卖ID
     */
    function refund(uint256 auctionId, uint256 token) public {
        AuctionStorage storage $ = _getAuctionStorage();
        uint256 _price = $.bidPriceReturns[auctionId][msg.sender][token];
        if (_price == 0) revert NotRefund();

        $.bidPriceReturns[auctionId][msg.sender][token] = 0;

        if(token == 0) {
            (bool success,) = payable(msg.sender).call{value: _price}("");
            if (!success) revert RefundTransferFailed(msg.sender, _price);
        } else {
            IERC20(tokenAddrs[token]).safeTransferFrom(address(this), msg.sender, _price);
        }

        emit Refund(auctionId, msg.sender, token, _price);
    }

    /**
     * 拍卖到期后，拍卖获胜者或者卖者可以结束拍卖
     * @param auctionId 拍卖ID
     */
    function endAuction(uint256 auctionId) public {
        AuctionInfo storage auction = _getAuctionInfo(auctionId);
        // 检查:拍卖已创建
        if (!auction.isCreated) revert AuctionNotExists(auctionId);

        // 检查：拍卖已到期
        if (auction.endTime > block.timestamp) revert AuctionNotExpired(auctionId);

        // 检查：拍卖没有结束
        if (auction.isEnded == true) revert AuctionEnded(auctionId);

        // 拍卖已结束!检查 调用者是否是当前最高出价者 或者 调用者是否是卖家
        address _sellerAddr = auction.seller;
        address _bidderAddr = auction.highestBidder;
        if (_bidderAddr != msg.sender && _sellerAddr != msg.sender) revert NotHighestBidderOrSeller();

        auction.isEnded = true;
        uint256 currTs = block.timestamp;
        if (_bidderAddr == address(0)) {
            // 没有人竞拍
            emit AuctionEnd(auctionId, msg.sender, _bidderAddr, 0, currTs, 0, 0);
        } else {
            // 有人竞拍
            /// 1. 卖者转移NFT给拍卖获胜者
            IERC721(auction.nftContract).safeTransferFrom(_sellerAddr, _bidderAddr, auction.tokenId);
            /// 2. 此合约把钱转给卖者
            uint256 _price = auction.currHighestPrice;
            uint256 _token = auction.highestBidToken;
            uint256 _amount = auction.currHighestTokenAmount;
            if(_token == 0) {
                (bool success,) = payable(_sellerAddr).call{value: _amount}("");
                if (!success) revert EndAuctionTransferFailed(_sellerAddr, _amount);
            } else {
                IERC20(tokenAddrs[_token]).safeTransferFrom(address(this), _sellerAddr, _amount);
            }            

            emit AuctionEnd(auctionId, msg.sender, _bidderAddr, _price, currTs, _token, _amount);
        }
    }
}
