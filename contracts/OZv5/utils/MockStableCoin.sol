// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockStableCoin is ERC20 {
    // We'll use 6 decimals to mimic USDT and USDC.
    uint8 private constant DECIMALS = 6;

    /**
     * @notice Constructor mints 10,000,000 tokens (full units) to both deployer and dev addresses.
     * @param name The token name.
     * @param symbol The token symbol.
     * @param deployer The address of the deployer (owner).
     * @param dev The secondary address (e.g. for development or testing).
     */
    constructor(
        string memory name,
        string memory symbol,
        address deployer,
        address dev
    ) ERC20(name, symbol) {
        // Mint amount: 10,000,000 * 10⁶ (since decimals = 6)
        uint256 mintAmount = 10000000 * (10 ** uint256(DECIMALS));
        _mint(deployer, mintAmount);
        _mint(dev, mintAmount);
    }

    /// @notice Overriding decimals to return 6.
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
