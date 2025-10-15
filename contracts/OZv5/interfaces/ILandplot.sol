// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface ILandplot {
  function isPlotAvailable(uint256 tokenId) external view returns (bool);
  function ownerOf(uint256 tokenId) external view returns (address);
  function incrementPlotCapacity(uint256 tokenId) external;
  function decreasePlotCapacity(uint256 tokenId) external;
}