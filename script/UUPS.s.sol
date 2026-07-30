// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {NFTAuctionV1} from "../src/NFTAuctionV1.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title 项目首次部署脚本
 * @author Shilvie
 * @notice UUPS部署 -> 验证逻辑合约地址 -> 验证say()函数
 */
contract UUPS is Script {
    // ERC1976标准存放逻辑合约地址的槽位
    bytes32 public constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() public {
        vm.startBroadcast();

        // -----------------------开始部署--------------------------
        // 1. 部署V1逻辑合约
        NFTAuctionV1 v1 = new NFTAuctionV1();
        address logicAddr = address(v1);
        console.log("V1 Logic Contract Address:", logicAddr);

        // 2. 拼接初始化调用数据
        // abi、msg都是solidity内置全局函数和变量
        bytes memory initData = abi.encodeWithSignature("initialize(address)", msg.sender);

        // 3. 部署UUPS代理, 同时执行V1逻辑合约初始函数
        ERC1967Proxy proxy = new ERC1967Proxy(address(v1), initData);
        address proxyAddr = address(proxy);
        console.log("Proxy Address:", proxyAddr);
        // -----------------------部署完成-----------------------------

        // 4. 验证ERC1976固定槽位存放逻辑合约地址是否与实际逻辑合约地址一致
        // 4.1 获取代理合约存储的逻辑合约地址
        bytes32 storedLogicAddrOfBytes32 = vm.load(proxyAddr, IMPLEMENTATION_SLOT);
        console.log("Proxy stored logic address(bytes32):");
        console.logBytes32(storedLogicAddrOfBytes32);
        // 4.2 bytes32转为address
        address storedLogicAddr = address(uint160(uint256(storedLogicAddrOfBytes32)));
        console.log("Proxy stored logic address:");
        console.log(storedLogicAddr);
        //4.3 比较地址是否一致
        vm.assertEq(storedLogicAddr, logicAddr, "storedLogicAddr is not equal to logicAddr!");

        // ---------------------测试V1逻辑合约-----------------------------
        // 5. 测试V1逻辑合约是否达到预期

        vm.stopBroadcast();
    }
}
