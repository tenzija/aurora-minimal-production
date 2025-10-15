// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "./aCO2Token.sol";

contract StakingPoolV2 is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IERC1155Receiver, ReentrancyGuardUpgradeable {
    aCO2Token public aco2Token;

    struct Package {
        uint256[] aco2_ids;
        uint256[] aco2_amounts;
        uint256 internal_pointer;
    }

    mapping(uint256 => Package) public packages;

    uint256 public packagePointer;
    uint256 public totalaCO2;
    uint256 public totalPackages;
    uint256 public MAX_TOKEN_IDS_PER_TX;
    uint256 public oldestNonEmptyPackage;

    bytes32 public constant STAKING_CONTRACT_ROLE = keccak256("STAKING_CONTRACT_ROLE");

    event ClaimedTokens(address recipient, uint256 aco2Id, uint256 transferAmount, uint256 remainingInPackage, uint256 totalTransferredAmount);
    event PartialClaimed(address recipient, uint256 requestedAmount, uint256 transferredAmount);
    event ClaimedTokensBatch(
        address indexed recipient,
        uint256[] aco2Ids,
        uint256[] amounts,
        uint256 totalTransferred
    );

    bytes32 public constant PACKAGE_ADD_ROLE = keccak256("PACKAGE_ADD_ROLE");

    function initialize(address _aco2TokenAddress) public initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(STAKING_CONTRACT_ROLE, msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init(); // <---
        aco2Token = aCO2Token(_aco2TokenAddress);
        oldestNonEmptyPackage = 0;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function setaCO2TokenAddress(address _aco2TokenAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_aco2TokenAddress != address(0), "aCO2 token address cannot be the zero address");
        require(isContract(_aco2TokenAddress), "aCO2 token address must be a contract");
        aco2Token = aCO2Token(_aco2TokenAddress);
    }

    function setMaxaCO2TokenIds(uint256 _maxTokenIds) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxTokenIds > 0, "Max token IDs per transaction must be greater than 0");
        MAX_TOKEN_IDS_PER_TX = _maxTokenIds;
    }

    function grantStakingContractRole(address _address) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_address != address(0), "Address cannot be the zero address");
        require(isContract(_address), "Address must be a contract");
        _grantRole(STAKING_CONTRACT_ROLE, _address);
    }

    function revokeStakingContractRole(address _address) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(STAKING_CONTRACT_ROLE, _address);
    }

    function grantPackageAddRole(address _address) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_address != address(0), "Address cannot be the zero address");
        _grantRole(PACKAGE_ADD_ROLE, _address);
    }

    function revokePackageAddRole(address _address) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(PACKAGE_ADD_ROLE, _address);
    }

    function addPackage(Package memory package) public onlyRole(PACKAGE_ADD_ROLE) {
        require(package.internal_pointer == 0, "ptr!=0");
        require(package.aco2_ids.length == package.aco2_amounts.length, "len");
        require(package.aco2_ids.length > 0, "empty");

        // amounts must be > 0 and sum amounts
        uint256 sum;
        for (uint256 i = 0; i < package.aco2_amounts.length; ) {
            uint256 amt = package.aco2_amounts[i];
            require(amt > 0, "amt=0");
            sum += amt;
            unchecked { ++i; }
        }

        aco2Token.safeBatchTransferFrom(
            msg.sender,
            address(this),
            package.aco2_ids,
            package.aco2_amounts,
            ""
        );

        packages[packagePointer] = package;
        totalaCO2 += sum;
        unchecked { ++packagePointer; ++totalPackages; }
    }

    function claimStakingaCO2(address recipient, uint256 amount)
        public
        onlyRole(STAKING_CONTRACT_ROLE)
        nonReentrant
        returns (uint256 claimed)
    {
        return _claimStakingaCO2(recipient, amount);
    }

    // BATCHED + RETURNS CLAIMED
    function _claimStakingaCO2(address recipient, uint256 amount)
        internal
        returns (uint256 claimed)
    {
        uint256 available = totalaCO2;
        if (amount == 0 || available == 0) {
            if (amount > 0) emit PartialClaimed(recipient, amount, 0);
            return 0;
        }

        uint256 amountToClaim = amount > available ? available : amount;
        uint256 maxIds = MAX_TOKEN_IDS_PER_TX;
        uint256 startPkg = oldestNonEmptyPackage;

        // -------- pass 1: count how many ids we will touch --------
        uint256 remaining = amountToClaim;
        uint256 idxCount = 0;
        uint256 pkgIdx = startPkg;

        while (remaining > 0 && pkgIdx < totalPackages && idxCount < maxIds) {
            Package storage p = packages[pkgIdx];
            uint256 ptr = p.internal_pointer;
            uint256 len = p.aco2_ids.length;
            while (ptr < len && remaining > 0 && idxCount < maxIds) {
                uint256 avail = p.aco2_amounts[ptr];
                if (avail == 0) { unchecked { ++ptr; } continue; }
                uint256 xfer = avail > remaining ? remaining : avail;
                remaining -= xfer;
                unchecked { ++idxCount; }
                if (avail == xfer) { unchecked { ++ptr; } }
            }
            unchecked { ++pkgIdx; }
        }

        if (idxCount == 0) {
            emit PartialClaimed(recipient, amount, 0);
            return 0;
        }

        // -------- allocate arrays once --------
        uint256[] memory ids = new uint256[](idxCount);
        uint256[] memory amts = new uint256[](idxCount);

        // -------- pass 2: fill arrays & update storage pointers/amounts --------
        remaining = amountToClaim;
        pkgIdx = startPkg;
        uint256 out = 0;
        uint256 outN = 0;

        while (remaining > 0 && pkgIdx < totalPackages && outN < idxCount) {
            Package storage p = packages[pkgIdx];
            uint256 ptr = p.internal_pointer;
            uint256 len = p.aco2_ids.length;

            while (ptr < len && remaining > 0 && outN < idxCount) {
                uint256 avail = p.aco2_amounts[ptr];
                if (avail == 0) { unchecked { ++ptr; } continue; }

                uint256 xfer = avail > remaining ? remaining : avail;

                // build batch arrays
                ids[outN]  = p.aco2_ids[ptr];
                amts[outN] = xfer;
                unchecked { ++outN; }

                // update storage
                avail -= xfer;
                p.aco2_amounts[ptr] = avail;
                if (avail == 0) { unchecked { ++ptr; } }

                remaining -= xfer;
                out += xfer;
            }

            // write back pointer once per package
            p.internal_pointer = ptr;
            unchecked { ++pkgIdx; }
        }

        // transfer once
        aco2Token.safeBatchTransferFrom(address(this), recipient, ids, amts, "");

        // update global accounting
        totalaCO2 -= out;
        claimed = out;

        // advance oldestNonEmptyPackage past any fully-consumed packages we just closed
        uint256 onn = oldestNonEmptyPackage;
        while (onn < totalPackages) {
            Package storage q = packages[onn];
            if (q.internal_pointer < q.aco2_ids.length) break;
            unchecked { ++onn; }
        }
        oldestNonEmptyPackage = onn;

        emit ClaimedTokensBatch(recipient, ids, amts, claimed);
        if (claimed < amount) emit PartialClaimed(recipient, amount, claimed);
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function getaCO2Balance() public view returns (uint256) {
        return totalaCO2;
    }

    // Function to get package details by ID
    function getPackage(uint256 packageId) public view returns (uint256[] memory, uint256[] memory, uint256) {
        require(packageId < packagePointer, "Package does not exist");
        Package storage package = packages[packageId];
        return (package.aco2_ids, package.aco2_amounts, package.internal_pointer);
    }

    // Adjust the internal pointer of a package
    function adjustPackagePointer(uint256 packageId, uint256 newPointer) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(packageId < packagePointer, "Package does not exist");
        packages[packageId].internal_pointer = newPointer;
    }

    // Function to see if an address is a contract
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(account) }
        return size > 0;
    }

    // Function to set the oldest non-empty package
    function setOldestNonEmptyPackage(uint256 newOldestNonEmptyPackage) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOldestNonEmptyPackage <= totalPackages, "New oldest non-empty package must be less than total packages");
        oldestNonEmptyPackage = newOldestNonEmptyPackage;
    }

    // Function to set the total aCO2
    function setTotalaCO2(uint256 newTotalaCO2) public onlyRole(DEFAULT_ADMIN_ROLE) {
        totalaCO2 = newTotalaCO2;
    }
}
