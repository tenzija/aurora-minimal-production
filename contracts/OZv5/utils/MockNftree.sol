// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockNftree is ERC721 {
    mapping(uint256 => address) private _owners;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => address) private _tokenApprovals;

    constructor() ERC721("MockNftree", "MNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    // A payable transferFrom that includes the whValue parameter.
    function transferFrom(
        address from,
        address to,
        uint256 tokenId,
        uint256 whValue
    ) external payable {
        // For testing we require a positive ETH value (the wormhole fee).
        require(msg.value >= 10**16, "Must send at least 0.01 ETH as wormhole fee");
        // Use the inherited ERC721 _transfer logic.
        _transfer(from, to, tokenId);
    }
}
