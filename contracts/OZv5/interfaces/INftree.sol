// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface INftree {
  function totalSupply() external view returns (uint256);
  function ownerOf(uint256 tokenId) external view returns (address);
}