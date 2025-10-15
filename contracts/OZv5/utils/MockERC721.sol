// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockERC721 is ERC721 {
    uint256 public tokenIdCounter;

    constructor() ERC721("MockNFT", "MNFT") {}

    function mint(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
    }
}
