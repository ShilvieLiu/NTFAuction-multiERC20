// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
//import {console} from "forge-std/console.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract NFTAuctionV1 is Initializable, OwnableUpgradeable, UUPSUpgradeable, ERC721Upgradeable {
    // #region 1. define enum

    // 出价币种类型
    //enum BidToken {ETH, USDT, USDC, DAI} //底层是uint，所以调用者可以随意输入其它数字，所以参数是它需要校验

    // #endregion 1. define enum

    // #region 2. define struct

    struct TokenInitConfig {
        uint256 token;
        address tokenAddr;
        address feedAddr;
    }

    struct CreateAuctionParams {
        address nftContract;
        uint256 tokenId;
        uint256 startPrice;
        uint256 startTime;
        uint256 durationHours;
        uint256[] allowedTokens;
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

    struct FeedResult {
        uint8 tokenDecimals; // token代币精度
        int256 rawPrice; // feed返回的价格
        uint256 updateTime; // feed返回的更新时间
        uint8 feedDecimals; // feed精度
        uint8 decimals; // 最终值的精度
        uint256 usd18Value; // 最终值
    }

    /// @custom:storage-location erc7201:nftauction.storage.auction.v1
    struct AuctionStorage {
        uint256 auctionId; // 拍卖ID
        mapping(address nftContract => mapping(uint256 tokenId => uint256 auctionId)) ntfToken2AuctionId; // 已创建的拍卖
        mapping(uint256 auctionId => AuctionInfo) auctions; // 拍卖的详情
        mapping(uint256 auctionId => mapping(address bidder => mapping(uint256 token => uint256 bidPrice)))
            bidPriceReturns; // 出价退回
        uint256 auctionCount; // 拍卖个数

        uint256 tokenCount;
        mapping(uint256 token => bool) enabledTokens;
        mapping(uint256 token => address tokenAddr) tokenAddrs;
        mapping(address tokenAddr => bool) enabledTokenAddrs;
        mapping(uint256 token => address feedAddr) feedAddrs;
        mapping(address feedAddr => bool) enabledFeedAddrs;
        AggregatorV3Interface dataFeed;
    }

    // #endregion 2. define struct

    // #region 3. define state variables

    // keccak256(abi.encode(uint256(keccak256("nftauction.storage.auction.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AUCTION_STORAGE_LOCATION =
        0x4c48d9668da3b85d45dd9d4fe97ed0e93efd4218c47ce0da3f0ab7fa4d259a00;

    using SafeERC20 for IERC20;

    // #endregion 3. define state variables

    // #region 4. define events

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

    event BidInfo(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 bidTime,
        uint256 bidPrice,
        uint256 token,
        uint256 tokenAmount,
        uint8 bidDecimals
    );

    event AuctionEnd(
        uint256 indexed auctionId,
        address indexed operator,
        address indexed winner,
        uint256 price,
        uint256 endTime,
        uint256 token,
        uint256 tokenAmount
    );

    event Refund(uint256 indexed auctionId, address indexed withdrawee, uint256 indexed token, uint256 price);

    event GetUSDByToken(
        uint256 indexed currTime,
        uint256 indexed token,
        uint8 tokenDecimals,
        uint256 updateTime,
        int256 rawPrice,
        uint8 feedDecimals,
        uint8 decimals,
        uint256 usd18Value
    );

    // #endregion 4. define events

    // #region 5. define errors

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
    //error TokenListEmpty();

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

    // tokenAddr已存在
    error TokenAddrExists();

    // feedAddr已存在
    error FeedAddrExists();

    // tokenAddr与之前的一样
    error TokenAddrSameBefore();

    // feedAddr与之前的一样
    error FeedAddrSameBefore();

    // 无效的检查类型
    error InvalidCheckType();

    // #endregion 5. define erros

    // #region 6. define modifiers

    function _checkValidAddr(uint256 checkType, address addr) internal pure {
        if (addr == address(0)) {
            if (checkType == 0) {
                revert InvalidNftContractAddr();
            } else if (checkType == 1) {
                revert InvalidTokenAddr();
            } else if (checkType == 2) {
                revert InvalidFeedAddr();
            } else {
                revert InvalidCheckType();
            }
        }
    }

    modifier validAddr(uint256 checkType, address addr) {
        _checkValidAddr(checkType, addr);
        _;
    }

    // #region 6. define modifiers

    // #region 7. define constructor

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // #endregion 7. define constructor

    // #region 8. external functions

    // #endregion 8. external functions

    // #region 9. public functions

    function initialize(
        address initialOwner,
        string memory nftName,
        string memory nftSymbol,
        TokenInitConfig[] memory tokenInitList
    ) public initializer {
        __Ownable_init(initialOwner);
        __ERC721_init(nftName, nftSymbol);
        batchAddTokenCfg(tokenInitList);
    }

    /**
     * 根据auctionId获取某个拍卖详情
     * @param auctionId 拍卖ID
     */
    function getAuctionInfo(uint256 auctionId) public view returns (AuctionInfo memory) {
        AuctionStorage storage $ = _getAuctionStorage();
        return $.auctions[auctionId];
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
        return $.auctionCount;
    }

    /**
     * 配置中，token是否存在
     */
    function getTokenIsExists(uint256 token) public view returns (bool) {
        return _getAuctionStorage().enabledTokens[token];
    }

    /**
     * 配置中，tokenAddr是否存在
     */
    function getTokenAddrIsExists(address addr) public view returns (bool) {
        return _getAuctionStorage().enabledTokenAddrs[addr];
    }

    /**
     * 配置中，feedAddr是否存在
     */
    function getFeedAddrIsExists(address addr) public view returns (bool) {
        return _getAuctionStorage().enabledFeedAddrs[addr];
    }

    /**
     * 根据token获取配置的对应tokenAddr
     */
    function getTokenAddr(uint256 token) public view returns (address) {
        return _getAuctionStorage().tokenAddrs[token];
    }

    /**
     * 根据token获取配置的对应feedAddr
     */
    function getFeedAddr(uint256 token) public view returns (address) {
        return _getAuctionStorage().feedAddrs[token];
    }

    /**
     * 获取tokenCount
     */
    function getTokenCount() public view returns (uint256) {
        return _getAuctionStorage().tokenCount;
    }

    /**
     * 仅管理员：批量添加token配置
     */
    function batchAddTokenCfg(TokenInitConfig[] memory tokenInitList) public onlyOwner {
        uint256 len = tokenInitList.length;
        if (len > 10) revert AllowedTokenSizeOver();
        TokenInitConfig memory cfg;
        AuctionStorage storage $ = _getAuctionStorage();
        for (uint256 i = 0; i < len; i++) {
            cfg = tokenInitList[i];
            if ($.enabledTokens[cfg.token]) revert TokenCfgExists();
            if ($.enabledTokenAddrs[cfg.tokenAddr]) revert TokenAddrExists();
            if ($.enabledFeedAddrs[cfg.feedAddr]) revert FeedAddrExists();
            // 默认cfg.token==0是ETH,并且cfg.tokenAddr==address(0)
            if (cfg.token > 0) {
                if (cfg.tokenAddr == address(0)) revert InvalidTokenAddr();
            }
            if (cfg.feedAddr == address(0)) revert InvalidFeedAddr();
            $.enabledTokens[cfg.token] = true;
            $.enabledTokenAddrs[cfg.tokenAddr] = true;
            $.enabledFeedAddrs[cfg.feedAddr] = true;
            $.tokenAddrs[cfg.token] = cfg.tokenAddr;
            $.feedAddrs[cfg.token] = cfg.feedAddr;
            $.tokenCount++;
        }
    }

    /**
     * 仅管理员：添加新token配置
     * @param token ID
     * @param tokenAddr 代币合约地址
     * @param feedAddr 代币/USD地址
     */
    function addTokenCfg(uint256 token, address tokenAddr, address feedAddr)
        public
        onlyOwner
        validAddr(1, tokenAddr)
        validAddr(2, feedAddr)
    {
        AuctionStorage storage $ = _getAuctionStorage();
        if ($.enabledTokens[token]) revert TokenCfgExists();
        if ($.enabledTokenAddrs[tokenAddr]) revert TokenAddrExists();
        if ($.enabledFeedAddrs[feedAddr]) revert FeedAddrExists();

        $.enabledTokens[token] = true;
        $.enabledTokenAddrs[tokenAddr] = true;
        $.enabledFeedAddrs[feedAddr] = true;
        $.tokenAddrs[token] = tokenAddr;
        $.feedAddrs[token] = feedAddr;
        $.tokenCount++;
    }

    /**
     * 仅管理员：修改指定token配置的tokenAddr
     * @param token ID
     * @param tokenAddr 代币合约地址
     */
    function updCfgTokenAddr(uint256 token, address tokenAddr) public onlyOwner validAddr(1, tokenAddr) {
        AuctionStorage storage $ = _getAuctionStorage();
        if (!$.enabledTokens[token]) revert TokenCfgNotExists();
        address beforeTokenAddr = $.tokenAddrs[token];
        if ($.enabledTokenAddrs[tokenAddr]) {
            if (beforeTokenAddr == tokenAddr) {
                // tokenAddr跟原先的一样
                revert TokenAddrSameBefore();
            } else {
                // 别的token已存在tokenAddr
                revert TokenAddrExists();
            }
        }

        $.enabledTokenAddrs[tokenAddr] = true;
        $.tokenAddrs[token] = tokenAddr;
        $.enabledTokenAddrs[beforeTokenAddr] = false;
    }

    /**
     * 仅管理员：修改指定token配置的feedAddr
     * @param token ID
     * @param feedAddr 代币/USD地址
     */
    function updCfgFeedAddr(uint256 token, address feedAddr) public onlyOwner validAddr(2, feedAddr) {
        AuctionStorage storage $ = _getAuctionStorage();
        if (!$.enabledTokens[token]) revert TokenCfgNotExists();
        address beforeFeedAddr = $.feedAddrs[token];
        if ($.enabledFeedAddrs[feedAddr]) {
            if (beforeFeedAddr == feedAddr) {
                // tokenAddr跟原先的一样
                revert FeedAddrSameBefore();
            } else {
                // 别的token已存在tokenAddr
                revert FeedAddrExists();
            }
        }

        $.enabledFeedAddrs[feedAddr] = true;
        $.feedAddrs[token] = feedAddr;
        $.enabledFeedAddrs[beforeFeedAddr] = false;
    }

    /**
     * 仅管理员：删除指定token配置
     * @param token ID
     */
    function delTokenCfg(uint256 token) public onlyOwner {
        AuctionStorage storage $ = _getAuctionStorage();
        if (!$.enabledTokens[token]) revert TokenCfgNotExists();
        $.enabledTokens[token] = false;
        $.enabledTokenAddrs[$.tokenAddrs[token]] = false;
        $.enabledFeedAddrs[$.feedAddrs[token]] = false;
        $.tokenAddrs[token] = address(0);
        $.feedAddrs[token] = address(0);
        $.tokenCount--;
    }

    /**
     * @dev 创建拍卖
     * @param params 参数
     *  nftContract 待拍卖NFT所在的合约地址：地址不能为address(0)
     *  tokenId 待拍卖NFT所在的合约里的tokenId
     *  startPrice 拍卖的起始价：必须大于0，并且默认以ETH wei单位
     *  startTime 拍卖的开始时间：必须大于当前时间,并且小于当前时间+1weeks
     *  durationHours 拍卖的持续时间（小时）：必须大于等于24，并且小于168
     */
    function createAuction(CreateAuctionParams calldata params) public returns (uint256) {
        AuctionStorage storage $ = _getAuctionStorage();
        _createAuctionCheck($, params);

        // 检查是否是允许的Tokens，并且判断是否按Token代币竞价
        bool _isToken = _getIsToken($, params.allowedTokens);

        // 检查：该合约下的NFT没有已创建拍卖
        uint256 _auctionId = $.ntfToken2AuctionId[params.nftContract][params.tokenId];
        if (_auctionId > 0) {
            // 此NFT已创建过拍卖
            AuctionInfo storage _auction = $.auctions[_auctionId];
            if (_auction.isCreated) revert AuctionAlreadyExists(_auctionId);
            // 此NFT已创建过拍卖，但创建拍卖取消了(_auction.isCreated = false)，现在重新创建但auctionId用原来的值
        } else {
            // 此NFT没有创建过拍卖
            _auctionId = ++$.auctionId;
            $.ntfToken2AuctionId[params.nftContract][params.tokenId] = _auctionId;
        }

        //以USD竞价，需将ETH的开始价格转成对应的USD作为起拍价
        uint8 _decimals = 18;
        uint256 _startTokenAmount = params.startPrice;
        uint256 _startPrice = params.startPrice;
        if (_isToken) {
            FeedResult memory feedRt = getUSDByToken(0, params.startPrice);
            _startPrice = feedRt.usd18Value;
            _decimals = feedRt.decimals;
        }

        $.auctionCount++;
        uint256 _endTime = params.startTime + (params.durationHours * 1 hours);

        _storeNewAuction({
            $: $,
            params: params,
            _auctionId: _auctionId,
            _startPrice: _startPrice,
            _endTime: _endTime,
            _isToken: _isToken,
            _startTokenAmount: _startTokenAmount,
            _decimals: _decimals
        });

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
        // @audit-info block validators can manipulate block.timestamp within a small window of several seconds. This check is for auction expiry, short‑range timestamp manipulation does not break auction business logic.
        // forge-lint:disable-next-line(block-timestamp)
        if (block.timestamp >= auction.startTime) revert AuctionAlreadyStarted(auctionId);

        // 检查：调用者是卖家
        if (auction.seller != msg.sender) revert NotAuctionSeller(msg.sender);

        // 更新拍卖信息
        $.auctionCount--;
        auction.isCreated = false;

        emit AuctionCancel(auctionId, msg.sender);
    }

    /**
     * 各种代币转成对应的USD价格
     * @param token 出价代币类型
     */
    function getUSDByToken(uint256 token, uint256 tokenAmount) public virtual returns (FeedResult memory feedRt) {
        AuctionStorage storage $ = _getAuctionStorage();
        address feedAddr = $.feedAddrs[token];
        if (feedAddr == address(0)) revert InvalidFeedAddr();

        //获取代币的代币精度
        address tokenAddr = $.tokenAddrs[token];
        if (token == 0) {
            feedRt.tokenDecimals = 18;
        } else {
            if (tokenAddr == address(0)) revert InvalidTokenAddr();
            feedRt.tokenDecimals = IERC20Metadata(tokenAddr).decimals();
        }

        $.dataFeed = AggregatorV3Interface(feedAddr);
        (, feedRt.rawPrice,, feedRt.updateTime,) = $.dataFeed.latestRoundData();
        feedRt.feedDecimals = $.dataFeed.decimals();

        // 安全校验（非常重要，上线必须保留）
        if (feedRt.rawPrice < 0) revert InvalidRawPrice(feedRt.rawPrice);
        // 价格超过1小时未更新，判定失效
        // if(block.timestamp - updateTime > 3600) revert StaleRawPrice(rawPrice, updateTime, block.timestamp);

        // 算出统一8位的usdValue（用于事件、存储）
        // casting to 'uint256' is safe because prior check ensures rawPrice is non-negative
        // forge-lint: disable-next-line(unsafe-typecast)
        feedRt.usd18Value = (tokenAmount * uint256(feedRt.rawPrice) * 10 ** 8)
            / ((10 ** uint256(feedRt.tokenDecimals)) * (10 ** uint256(feedRt.feedDecimals)));
        feedRt.decimals = 8;

        emit GetUSDByToken(
            block.timestamp,
            token,
            feedRt.tokenDecimals,
            feedRt.updateTime,
            feedRt.rawPrice,
            feedRt.feedDecimals,
            feedRt.decimals,
            feedRt.usd18Value
        );
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

        // 检查：当前时间必须大于等于拍卖开始时间
        // @audit-info block validators can manipulate block.timestamp within a small window of several seconds. This check is for auction expiry, short‑range timestamp manipulation does not break auction business logic.
        // forge-lint:disable-next-line(block-timestamp)
        if (auction.startTime > block.timestamp) revert AuctionNotStarted(auctionId);

        // 检查：当前时间必须小于拍卖结束时间
        // @audit-info block validators can manipulate block.timestamp within a small window of several seconds. This check is for auction expiry, short‑range timestamp manipulation does not break auction business logic.
        // forge-lint:disable-next-line(block-timestamp)
        if (auction.endTime <= block.timestamp) revert AuctionExpired(auctionId);

        FeedResult memory _feedRt;
        if (auction.isToken) {
            // 可以Token出价，则使用USD比大小
            if (msg.value > 0) {
                // ETH出价=================================
                _feedRt = getUSDByToken(0, msg.value);
                _bidLogic(
                    auctionId,
                    $,
                    auction,
                    msg.sender,
                    _feedRt.usd18Value,
                    0,
                    msg.value,
                    block.timestamp,
                    _feedRt.decimals
                );
            } else {
                // Token出价==============================
                if (amount == 0) revert InvalidBidAmount();
                if (!_isTokenAllowed(auction.allowedTokens, token)) revert InvalidBidToken();
                // Token转账到此合约
                IERC20($.tokenAddrs[token]).safeTransferFrom(msg.sender, address(this), amount);
                _feedRt = getUSDByToken(token, amount);
                _bidLogic(
                    auctionId,
                    $,
                    auction,
                    msg.sender,
                    _feedRt.usd18Value,
                    token,
                    amount,
                    block.timestamp,
                    _feedRt.decimals
                );
            }
        } else {
            // 仅ETH出价，使用ETH比大小=====================
            _bidLogic(auctionId, $, auction, msg.sender, msg.value, 0, msg.value, block.timestamp, 18);
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

        if (token == 0) {
            (bool success,) = payable(msg.sender).call{value: _price}("");
            if (!success) revert RefundTransferFailed(msg.sender, _price);
        } else {
            IERC20($.tokenAddrs[token]).safeTransfer(msg.sender, _price);
        }

        emit Refund(auctionId, msg.sender, token, _price);
    }

    /**
     * 拍卖到期后，拍卖获胜者或者卖者可以结束拍卖
     * @param auctionId 拍卖ID
     */
    function endAuction(uint256 auctionId) public {
        AuctionStorage storage $ = _getAuctionStorage();
        AuctionInfo storage auction = $.auctions[auctionId];
        // 检查:拍卖已创建
        if (!auction.isCreated) revert AuctionNotExists(auctionId);

        // 检查：拍卖已到期
        // @audit-info block validators can manipulate block.timestamp within a small window of several seconds. This check is for auction expiry, short‑range timestamp manipulation does not break auction business logic.
        // forge-lint:disable-next-line(block-timestamp)
        if (auction.endTime > block.timestamp) revert AuctionNotExpired(auctionId);

        // 检查：拍卖没有结束
        if (auction.isEnded == true) revert AuctionEnded(auctionId);

        // 拍卖已结束!检查 调用者是否是当前最高出价者 或者 调用者是否是卖家
        address _sellerAddr = auction.seller;
        address _bidderAddr = auction.highestBidder;
        if (_bidderAddr != msg.sender && _sellerAddr != msg.sender) revert NotHighestBidderOrSeller();

        auction.isEnded = true;
        //uint256 currTs = block.timestamp;
        if (_bidderAddr == address(0)) {
            // 没有人竞拍
            emit AuctionEnd(auctionId, msg.sender, _bidderAddr, 0, block.timestamp, 0, 0);
        } else {
            // 有人竞拍
            /// 1. 卖者转移NFT给拍卖获胜者
            IERC721(auction.nftContract).safeTransferFrom(_sellerAddr, _bidderAddr, auction.tokenId);
            /// 2. 此合约把钱转给卖者
            uint256 _price = auction.currHighestPrice;
            uint256 _token = auction.highestBidToken;
            uint256 _amount = auction.currHighestTokenAmount;
            if (_token == 0) {
                (bool success,) = payable(_sellerAddr).call{value: _amount}("");
                if (!success) revert EndAuctionTransferFailed(_sellerAddr, _amount);
            } else {
                IERC20($.tokenAddrs[_token]).safeTransfer(_sellerAddr, _amount);
            }

            emit AuctionEnd(auctionId, msg.sender, _bidderAddr, _price, block.timestamp, _token, _amount);
        }
    }

    // #endregion 9. public functions

    // #region 10. internal functions

    // 强制开发者自定义谁才能升级合约
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        //require(newImplementation != address(0), "New implementation is not zero address!"); // 可省略，因为UUPSUpgradeable里已校验
    }

    /**
     * 返回是否按照ETH竞价还是USD竞价
     * 返回false：按ETH竞价
     * 返回true：按USD竞价
     */
    function _getIsToken(AuctionStorage storage $, uint256[] calldata allowedTokens) internal view returns (bool) {
        bool _isToken = false;
        uint256 _token;
        for (uint256 i = 0; i < allowedTokens.length; i++) {
            _token = allowedTokens[i];
            if (!$.enabledTokens[_token]) revert InvalidAllowedToken(_token);
            if (!_isToken) {
                if (_token > 0) _isToken = true;
            }
        }
        return _isToken;
    }

    function _createAuctionCheck(AuctionStorage storage $, CreateAuctionParams calldata params)
        internal
        view
        validAddr(0, params.nftContract)
    {
        // 检查：开始价格必须大于0
        if (params.startPrice == 0) revert StartPriceMustGtZero();

        // 检查：allowedTokens长度不能超过可允许的token配置的最大长度
        if (params.allowedTokens.length > $.tokenCount) revert AllowedTokenSizeOver();

        // 检查：持续时间必须在24-168小时之间
        if (params.durationHours < 24 || params.durationHours > 168) revert DurationHoursOutOfRange();

        //uint256 _currTs = block.timestamp;
        //console.log("_currTs of contract:", _currTs);
        // 检查：开始时间必须大于当前时间
        // @audit-info block validators can manipulate block.timestamp within a small window of several seconds. This check is for auction expiry, short‑range timestamp manipulation does not break auction business logic.
        // forge-lint:disable-next-line(block-timestamp)
        if (params.startTime <= block.timestamp) revert StartTimeMustGtCurrTime();

        // 检查：开始时间必须在当前时间一周内
        // @audit-info block validators can manipulate block.timestamp within a small window of several seconds. This check is for auction expiry, short‑range timestamp manipulation does not break auction business logic.
        // forge-lint:disable-next-line(block-timestamp)
        if (params.startTime > block.timestamp + 1 weeks) revert StartTimeOverMaxValue();

        // 检查：待创建拍卖的NFT所在的合约地址不能为0
        //if (params.nftContract == address(0)) revert InvalidNftContractAddr();

        // 检查：调用者必须是tokenId的所有者
        IERC721 nft = IERC721(params.nftContract);
        if (msg.sender != nft.ownerOf(params.tokenId)) revert NotNftOwner(msg.sender);

        // 检查：待拍卖的NFT必须已授权给此合约
        if (!(address(this) == nft.getApproved(params.tokenId) || nft.isApprovedForAll(msg.sender, address(this)))) {
            revert NftNotApproved();
        }
    }

    function _storeNewAuction(
        AuctionStorage storage $,
        CreateAuctionParams calldata params,
        uint256 _auctionId,
        uint256 _startPrice,
        uint256 _endTime,
        bool _isToken,
        uint256 _startTokenAmount,
        uint8 _decimals
    ) internal {
        $.auctions[_auctionId] = AuctionInfo({
            auctionId: _auctionId,
            tokenId: params.tokenId,
            startPrice: _startPrice,
            startTime: params.startTime,
            durationHours: params.durationHours,
            endTime: _endTime,
            currHighestPrice: _startPrice,
            highestBidder: address(0),
            nftContract: params.nftContract,
            seller: msg.sender,
            isCreated: true,
            isEnded: false,
            isToken: _isToken,
            allowedTokens: params.allowedTokens,
            highestBidToken: 0,
            currHighestTokenAmount: _startTokenAmount,
            currHighestDecimals: _decimals
        });

        emit AuctionCreated(
            _auctionId,
            msg.sender,
            params.nftContract,
            params.tokenId,
            _startPrice,
            params.startTime,
            _endTime,
            _isToken,
            params.allowedTokens,
            _decimals,
            _startTokenAmount
        );
    }

    function _isTokenAllowed(uint256[] storage allowedTokens, uint256 token) internal view returns (bool) {
        for (uint8 i = 0; i < allowedTokens.length; i++) {
            if (allowedTokens[i] == token) return true;
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
        if (bidAmount > type(uint256).max - $.bidPriceReturns[auctionId][msg.sender][bidToken]) {
            revert refundAfterBid();
        }

        // 记录某拍卖某出价者需要退回的金额
        if (auction.highestBidder != address(0)) {
            $.bidPriceReturns[
                auctionId
            ][auction.highestBidder][auction.highestBidToken] += auction.currHighestTokenAmount;
        }

        // 更新最新最高出价、出价者
        auction.currHighestPrice = bidPrice;
        auction.highestBidder = bidder;
        auction.highestBidToken = bidToken;
        auction.currHighestTokenAmount = bidAmount;

        emit BidInfo(auctionId, bidder, currTime, bidPrice, bidToken, bidAmount, bidDecimals);
    }

    // #endregion 10. internal functions

    // #region 11. private functions

    function _getAuctionStorage() private pure returns (AuctionStorage storage $) {
        assembly {
            $.slot := AUCTION_STORAGE_LOCATION
        }
    }

    // #endregion 11. private functions
}
