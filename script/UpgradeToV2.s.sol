// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {V2} from "../src/V2.sol";

/**
 * @title 部署项目升级至V2版本
 * @author Shilve
 * @notice
 */
contract UpgradeToV2 is Script {
    // 项目的代理合约地址
    address public constant PROXY_ADDR = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    // ERC1976标准存放逻辑合约地址的槽位
    bytes32 public constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() public {
        vm.startBroadcast();

        // 1. 部署V2版本逻辑合约
        V2 v2 = new V2();
        address v2Addr = address(v2);
        console.log("V2 Logic Address:", v2Addr);

        // 2. 拼接V2逻辑合约初始化调用数据
        bytes memory initData = abi.encodeWithSignature("initializeV2()");

        // 3. 将项目升级至V2版本的逻辑合约
        V2(PROXY_ADDR).upgradeToAndCall(v2Addr, initData);

        // 4. 验证ERC1976固定槽位存放逻辑合约地址是否是V2逻辑合约的地址？
        // 4.1 获取代理合约存储的逻辑合约地址
        bytes32 storedLogicAddrOfBytes32 = vm.load(PROXY_ADDR, IMPLEMENTATION_SLOT);
        console.log("Proxy stored logic address(bytes32):");
        console.logBytes32(storedLogicAddrOfBytes32);
        // 4.2 bytes32转为address
        address storedLogicAddr = address(uint160(uint256(storedLogicAddrOfBytes32)));
        console.log("Proxy stored logic address:");
        console.log(storedLogicAddr);
        //4.3 比较地址是否一致
        vm.assertEq(storedLogicAddr, v2Addr, "storedLogicAddr is not equal to v2Addr!");

        // 5. 测试V2合约中的函数是否符合预期？

        vm.stopBroadcast();
    }
}
