// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.33;

import {NFTAuctionV1} from "./NFTAuctionV1.sol";

contract V2 is NFTAuctionV1 {
    // 新增变量
    string public message;

    // V1 -> V2: reinitializer(2)
    // V2 -> V3: reinitializer(3)
    function initializeV2() public reinitializer(2) {
        // Solidity 0.8.18+ 支持 unicode 字符串，专门用来存放中文、emoji 等 Unicode 字符
        message = unicode"成功升级至V2版本";
    }
}
