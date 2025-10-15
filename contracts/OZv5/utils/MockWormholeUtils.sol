// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockWormholeUtils {
    // Returns a fixed wormhole cost of 0.01 ETH (10^16 wei) for testing.
    function getNFTREE_TransferCost(uint256, uint256) external pure returns (uint256, uint256) {
        return (10**16, 0);
    }
}
