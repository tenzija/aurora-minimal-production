// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@cryptoalgebra/core/contracts/interfaces/pool/IAlgebraPoolState.sol";
import "./interfaces/ILandplot.sol";
import "./interfaces/INftree.sol";
import "./StakingPoolV2.sol";

contract StakingV2 is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    IERC20 public cbyToken; // CBY token contract
    ILandplot public landplots;   // Standard Landplots contract
    ILandplot public landplotsV3; // Genesis Landplots contract
    ILandplot public landplotsV5; // Rare Landplots contract
    StakingPoolV2 public stakingPool; // Staking Pool V2
    IAlgebraPoolState private algebraPool; // Algebra Pool contract

    bytes32 public merkleRoot; // Merkle root for the aCO2 claims

    bytes32 public constant CARBIFY_ADMIN_ROLE = keccak256("CARBIFY_ADMIN_ROLE");
    bytes32 public constant NFTREE_BATCH_ROLE   = keccak256("NFTREE_BATCH_ROLE");
    bytes32 public constant LANDPLOT_ROLE       = keccak256("LANDPLOT_ROLE");

    struct Stake {
        uint256 tokenId;
        address nftreeAddress;
        uint256 stakingTime; // = $CBY lock time
        uint256 lastClaimTime;
        uint256 remainingReward;
        uint256 lockedCBYAmount;
        address owner;
        bool isLocked;
        bool isStaked;
        uint256 plotId;
        address plotAddress;
    }

    mapping(address => mapping(uint256 => Stake)) public stakes;
    mapping(bytes32 => bool) public claimed; // merkle claims bitmap
    mapping(bytes32 => uint256) public merkleClaimRemainingRewards;
    mapping(address => uint256) public userRemainingRewards;

    address public unlockFeeReceiver;

    event Staked(address indexed user, address indexed nftreeAddress, uint256 tokenId, address indexed plotAddress, uint256 plotId, uint256 time);
    event Unstaked(address indexed user, address indexed nftreeAddress, uint256 tokenId, uint256 indexed time, uint256 aco2Reward);
    event Locked(address indexed user, address indexed nftreeAddress, uint256 tokenId, uint256 time, uint256 amount);
    event Unlocked(address indexed user, address indexed nftreeAddress, uint256 tokenId, uint256 feeAmount, uint256 time, uint256 amount);
    event Claimed(address indexed user, address indexed nftreeAddress, uint256 tokenId, address indexed plotAddress, uint256 plotId, uint256 time, uint256 aco2Reward);
    event PartialClaim(address indexed user, address indexed nftreeAddress, uint256 tokenId, uint256 indexed time, uint256 remainingReward);
    event ClaimedStakingMerkle(address indexed user, uint256 amount);
    event PartialClaimStakingMerkle(address indexed user, uint time, uint256 remainingReward);
    event ClaimedRemainingRewards(address indexed user, uint256 time, uint256 amount);

    function initialize(
        address _cbyTokenAddress,
        address _landplotsAddress,
        address _landplotsV3Address,
        address _landplotsV5Address,
        address _algebraPoolAddress,
        address _stakingPoolAddress
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CARBIFY_ADMIN_ROLE, msg.sender);

        cbyToken = IERC20(_cbyTokenAddress);
        landplots = ILandplot(_landplotsAddress);
        landplotsV3 = ILandplot(_landplotsV3Address);
        landplotsV5 = ILandplot(_landplotsV5Address);
        algebraPool = IAlgebraPoolState(_algebraPoolAddress);
        stakingPool = StakingPoolV2(_stakingPoolAddress);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Admin role mgmt
    function grantCarbifyAdminRole(address _user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(CARBIFY_ADMIN_ROLE, _user);
    }
    function revokeCarbifyAdminRole(address _user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(CARBIFY_ADMIN_ROLE, _user);
    }

    function setStakingPoolAddress(address _stakingPoolAddress) external onlyRole(CARBIFY_ADMIN_ROLE) {
        require(_stakingPoolAddress != address(0), "Invalid address");
        require(isContract(_stakingPoolAddress), "Not a contract address");
        stakingPool = StakingPoolV2(_stakingPoolAddress);
    }

    function setAlgebraPoolAddress(address _algebraPoolAddress) external onlyRole(CARBIFY_ADMIN_ROLE) {
        require(_algebraPoolAddress != address(0), "Invalid address");
        require(isContract(_algebraPoolAddress), "Not a contract address");
        algebraPool = IAlgebraPoolState(_algebraPoolAddress);
    }

    function setUnlockFeeReceiver(address _unlockFeeReceiver) external onlyRole(CARBIFY_ADMIN_ROLE) {
        unlockFeeReceiver = _unlockFeeReceiver;
    }

    // -------- price helpers --------
    function getPrice() public view returns (uint256 finalPrice) {
        (uint160 price,,,,,,) = algebraPool.globalState();

        uint256 sqrtPriceX96Pow = uint256(price * 10**12);
        uint256 priceFromSqrtX96 = sqrtPriceX96Pow / 2**96;
        priceFromSqrtX96 = priceFromSqrtX96**2;
        uint256 priceAdj = priceFromSqrtX96 * 10**6;
        finalPrice = (1 * 10**48) / priceAdj;
    }

    function calculateFiveDollarsWorthCBY() public view returns (uint256) {
        uint256 pricePerCBY = getPrice();
        return (5 * 10**6 * 10**18) / pricePerCBY; // $5 in 6dp → CBY 18dp
    }

    // -------- view helpers --------
    function isStaked(uint256 _tokenId, address _nftreeAddress) public view returns (bool) {
        return stakes[_nftreeAddress][_tokenId].isStaked;
    }

    function getTotalLockedAmountPerUser(address _user, address _nftreeAddress, uint256 startTokenId, uint256 endTokenId) public view returns (uint256) {
        require(startTokenId <= endTokenId, "Invalid token ID range");
        require(startTokenId > 0 && endTokenId <= INftree(_nftreeAddress).totalSupply(), "Range OOB");

        uint256 totalStakedAmount = 0;
        for (uint256 i = startTokenId; i <= endTokenId; i++) {
            Stake storage s = stakes[_nftreeAddress][i];
            if (s.owner == _user && s.isLocked) totalStakedAmount += s.lockedCBYAmount;
        }
        return totalStakedAmount;
    }

    function getLockedAmountPerNFTree(uint256 _tokenId, address _nftreeAddress) public view returns (uint256) {
        Stake storage s = stakes[_nftreeAddress][_tokenId];
        return s.isLocked ? s.lockedCBYAmount : 0;
    }

    function getLockedCBYValueInUSD(uint256 _tokenId, address _nftreeAddress) public view returns (uint256) {
        uint256 lockedCBYAmount = getLockedAmountPerNFTree(_tokenId, _nftreeAddress);
        uint256 currentPrice = getPrice();
        return (lockedCBYAmount * currentPrice) / 1e18;
    }

    function calculateRewards(uint256 _tokenId, address _nftreeAddress) public view returns (uint256) {
        Stake storage s = stakes[_nftreeAddress][_tokenId];
        require(s.isStaked, "NFTree is not staked");

        // 175 aCO2/year
        uint256 pendingReward = (block.timestamp - s.lastClaimTime) * uint256(uint256(175 ether) / uint256(365)) / 86400;

        uint256 reward;
        if (s.plotAddress == address(landplots)) {
            reward = (pendingReward * 80) / 100;
        } else if (s.plotAddress == address(landplotsV5)) {
            reward = (pendingReward * 90) / 100;
        } else if (s.plotAddress == address(landplotsV3)) {
            reward = pendingReward;
        } else {
            reward = 0;
        }

        reward += s.remainingReward;
        return reward;
    }

    function calculateRewardsMultiple(uint256[] calldata _tokenIds, address[] calldata _nftreeAddresses) external view returns (uint256[] memory) {
        require(_tokenIds.length == _nftreeAddresses.length, "Mismatched arrays length");
        uint256[] memory rewards = new uint256[](_tokenIds.length);
        for (uint i = 0; i < _tokenIds.length; i++) {
            rewards[i] = calculateRewards(_tokenIds[i], _nftreeAddresses[i]);
        }
        return rewards;
    }

    // -------- lock/unlock --------
    function lock(uint256 _tokenId, address _nftreeAddress) public {
        require(hasRole(NFTREE_BATCH_ROLE, _nftreeAddress), "_nftreeAddress not authorized");

        Stake storage s = stakes[_nftreeAddress][_tokenId];
        uint256 fiveDollarsInCBYTokens = calculateFiveDollarsWorthCBY();

        require(INftree(_nftreeAddress).ownerOf(_tokenId) == msg.sender, "Not the owner");
        require(s.lockedCBYAmount < fiveDollarsInCBYTokens, "Already locked enough");
        require(!s.isStaked, "NFTree is staked");

        uint256 requiredAdditionalLockValue = fiveDollarsInCBYTokens - s.lockedCBYAmount;
        require(cbyToken.transferFrom(msg.sender, address(this), requiredAdditionalLockValue), "CBY transfer failed");

        s.lockedCBYAmount += requiredAdditionalLockValue;
        s.isLocked = true;
        s.owner = INftree(_nftreeAddress).ownerOf(_tokenId);

        emit Locked(msg.sender, _nftreeAddress, _tokenId, block.timestamp, requiredAdditionalLockValue);

        if (s.stakingTime == 0) {
            s.stakingTime = block.timestamp;
        }
    }

    function lockMultiple(uint256[] calldata _tokenIds, address[] calldata _nftreeAddresses) external {
        require(_tokenIds.length == _nftreeAddresses.length, "Mismatched arrays length");
        for (uint i = 0; i < _tokenIds.length; i++) {
            lock(_tokenIds[i], _nftreeAddresses[i]);
        }
    }

    function unlock(uint256 _tokenId, address _nftreeAddress) public {
        require(hasRole(NFTREE_BATCH_ROLE, _nftreeAddress), "_nftreeAddress not authorized");

        Stake storage s = stakes[_nftreeAddress][_tokenId];

        require(INftree(_nftreeAddress).ownerOf(_tokenId) == msg.sender, "Not the owner");
        require(!s.isStaked, "NFTree is staked");
        require(s.isLocked, "Not locked");

        uint256 lockDuration = block.timestamp - s.stakingTime;
        uint256 feePercentage = getUnlockFeePercentage(lockDuration);
        uint256 feeAmount = s.lockedCBYAmount * feePercentage / 10000;
        uint256 returnAmount = s.lockedCBYAmount - feeAmount;

        cbyToken.transfer(unlockFeeReceiver, feeAmount);
        cbyToken.transfer(msg.sender, returnAmount);

        s.isLocked = false;
        s.lockedCBYAmount = 0;
        s.owner = address(0);

        emit Unlocked(msg.sender, _nftreeAddress, _tokenId, feeAmount, block.timestamp, returnAmount);
    }

    function unlockMultiple(uint256[] calldata _tokenIds, address[] calldata _nftreeAddresses) external {
        require(_tokenIds.length == _nftreeAddresses.length, "Mismatched arrays length");
        for (uint i = 0; i < _tokenIds.length; i++) {
            unlock(_tokenIds[i], _nftreeAddresses[i]);
        }
    }

    function unlockMultipleForUser(address _user, uint256[] calldata _tokenIds, address[] calldata _nftreeAddresses) external onlyRole(CARBIFY_ADMIN_ROLE) {
        require(_tokenIds.length == _nftreeAddresses.length, "Mismatched arrays length");

        for (uint i = 0; i < _tokenIds.length; i++) {
            uint256 _tokenId = _tokenIds[i];
            address _nftreeAddress = _nftreeAddresses[i];

            require(hasRole(NFTREE_BATCH_ROLE, _nftreeAddress), "_nftreeAddress not authorized");

            Stake storage s = stakes[_nftreeAddress][_tokenId];

            require(_user == s.owner, "Not the owner");
            require(!s.isStaked, "NFTree is staked");
            require(s.isLocked, "Not locked");

            cbyToken.transfer(msg.sender, s.lockedCBYAmount);
            emit Unlocked(s.owner, _nftreeAddress, _tokenId, 0, block.timestamp, s.lockedCBYAmount);

            s.isLocked = false;
            s.lockedCBYAmount = 0;
            s.owner = address(0);
        }
    }

    // -------- stake/unstake --------
    function stake(uint256 _tokenId, address _nftreeAddress, uint256 _plotId, address _plotAddress) public {
        require(hasRole(NFTREE_BATCH_ROLE, _nftreeAddress), "_nftreeAddress not authorized");
        require(hasRole(LANDPLOT_ROLE, _plotAddress), "_plotAddress not authorized");

        Stake storage prev = stakes[_nftreeAddress][_tokenId];

        if (!prev.isLocked) {
            lock(_tokenId, _nftreeAddress);
        }
        require(prev.isLocked, "NFTree not locked with CBY");

        uint256 correctLockAmount = calculateFiveDollarsWorthCBY();
        require(!prev.isStaked, "NFTree already staked");
        require(INftree(_nftreeAddress).ownerOf(_tokenId) == msg.sender, "Not the owner");
        require(
            _plotAddress == address(landplots) || _plotAddress == address(landplotsV3) || _plotAddress == address(landplotsV5),
            "Invalid plot address"
        );

        if (prev.lockedCBYAmount < correctLockAmount) {
            uint256 additionalLockAmount = correctLockAmount - prev.lockedCBYAmount;
            require(cbyToken.transferFrom(msg.sender, address(this), additionalLockAmount), "CBY transfer failed");
            prev.lockedCBYAmount += additionalLockAmount;
        }

        if (_plotAddress == address(landplots)) {
            require(landplots.isPlotAvailable(_plotId), "Plot unavailable");
            require(landplots.ownerOf(_plotId) == msg.sender, "Not plot owner");
            landplots.incrementPlotCapacity(_plotId);
        } else if (_plotAddress == address(landplotsV3)) {
            require(landplotsV3.isPlotAvailable(_plotId), "Plot unavailable");
            require(landplotsV3.ownerOf(_plotId) == msg.sender, "Not plot owner");
            landplotsV3.incrementPlotCapacity(_plotId);
        } else if (_plotAddress == address(landplotsV5)) {
            require(landplotsV5.isPlotAvailable(_plotId), "Plot unavailable");
            require(landplotsV5.ownerOf(_plotId) == msg.sender, "Not plot owner");
            landplotsV5.incrementPlotCapacity(_plotId);
        }

        stakes[_nftreeAddress][_tokenId] = Stake({
            tokenId: _tokenId,
            nftreeAddress: _nftreeAddress,
            stakingTime: prev.stakingTime,
            lastClaimTime: block.timestamp,
            remainingReward: 0,
            owner: msg.sender,
            lockedCBYAmount: prev.lockedCBYAmount,
            isLocked: true,
            isStaked: true,
            plotId: _plotId,
            plotAddress: _plotAddress
        });

        emit Staked(msg.sender, _nftreeAddress, _tokenId, _plotAddress, _plotId, block.timestamp);
    }

    function stakeMultiple(uint256[] calldata _tokenIds, address[] calldata _nftreeAddresses, uint256[] calldata _plotIds, address[] calldata _plotAddresses) external {
        require(_tokenIds.length == _plotIds.length, "Mismatched arrays length");
        require(_tokenIds.length == _plotAddresses.length, "Mismatched arrays length");
        require(_tokenIds.length == _nftreeAddresses.length, "Mismatched arrays length");
        for (uint i = 0; i < _tokenIds.length; i++) {
            stake(_tokenIds[i], _nftreeAddresses[i], _plotIds[i], _plotAddresses[i]);
        }
    }

    function unstake(uint256 _tokenId, address _nftreeAddress, bool _shouldUnlock) public {
        require(hasRole(NFTREE_BATCH_ROLE, _nftreeAddress), "_nftreeAddress not authorized");

        Stake storage s = stakes[_nftreeAddress][_tokenId];

        require(s.isLocked, "NFTree not locked with CBY");
        require(s.isStaked, "NFTree not staked");
        require(msg.sender == _nftreeAddress || s.owner == msg.sender, "Caller not authorized");

        // update plot capacity
        uint256 plotId = s.plotId;
        if (s.plotAddress == address(landplots)) {
            landplots.decreasePlotCapacity(plotId);
        } else if (s.plotAddress == address(landplotsV3)) {
            landplotsV3.decreasePlotCapacity(plotId);
        } else if (s.plotAddress == address(landplotsV5)) {
            landplotsV5.decreasePlotCapacity(plotId);
        }

        // claim via pool (pool returns actual claimed)
        uint256 totalReward = calculateRewards(_tokenId, _nftreeAddress);
        uint256 claimedAmount = stakingPool.claimStakingaCO2(s.owner, totalReward);
        uint256 leftover = totalReward - claimedAmount;
        userRemainingRewards[s.owner] += leftover;

        s.isStaked = false;
        s.lastClaimTime = 0;
        s.remainingReward = 0;
        s.plotAddress = address(0);
        s.plotId = 0;

        emit Unstaked(s.owner, _nftreeAddress, _tokenId, block.timestamp, claimedAmount);
        if (leftover > 0) {
            emit PartialClaim(s.owner, _nftreeAddress, _tokenId, block.timestamp, leftover);
        }

        if (msg.sender != _nftreeAddress && _shouldUnlock) {
            unlock(_tokenId, _nftreeAddress);
        }
    }

    function unstakeMultiple(uint256[] calldata _tokenIds, address[] calldata _nftreeAddress, bool _shouldUnlock) external {
        require(_tokenIds.length == _nftreeAddress.length, "Mismatched arrays length");
        for (uint i = 0; i < _tokenIds.length; i++) {
            unstake(_tokenIds[i], _nftreeAddress[i], _shouldUnlock);
        }
    }

    function unstakeMultipleForUser(
        address _user,
        uint256[] calldata _tokenIds,
        address[] calldata _nftreeAddress
    ) external onlyRole(CARBIFY_ADMIN_ROLE) {
        require(_tokenIds.length == _nftreeAddress.length, "Mismatched arrays length");

        for (uint i = 0; i < _tokenIds.length; i++) {
            uint256 _tokenId = _tokenIds[i];
            address nftreeAddress = _nftreeAddress[i];

            require(hasRole(NFTREE_BATCH_ROLE, nftreeAddress), "nftreeAddress not authorized");

            Stake storage s = stakes[nftreeAddress][_tokenId];

            require(s.isLocked, "NFTree not locked with CBY");
            require(s.isStaked, "NFTree not staked");
            require(s.owner == _user, "Caller not authorized");

            // update plot capacity
            uint256 plotId = s.plotId;
            if (s.plotAddress == address(landplots)) {
                landplots.decreasePlotCapacity(plotId);
            } else if (s.plotAddress == address(landplotsV3)) {
                landplotsV3.decreasePlotCapacity(plotId);
            } else if (s.plotAddress == address(landplotsV5)) {
                landplotsV5.decreasePlotCapacity(plotId);
            }

            uint256 totalReward = calculateRewards(_tokenId, nftreeAddress);
            uint256 claimedAmount = stakingPool.claimStakingaCO2(s.owner, totalReward);
            uint256 leftover = totalReward - claimedAmount;
            userRemainingRewards[s.owner] += leftover;

            s.isStaked = false;
            s.lastClaimTime = 0;
            s.remainingReward = 0;
            s.plotAddress = address(0);
            s.plotId = 0;

            emit Unstaked(s.owner, nftreeAddress, _tokenId, block.timestamp, claimedAmount);
            if (leftover > 0) {
                emit PartialClaim(s.owner, nftreeAddress, _tokenId, block.timestamp, leftover);
            }
        }
    }

    // -------- claim logic --------
    function _claim(address _user, uint256 _tokenId, address _nftreeAddress) internal {
        require(hasRole(NFTREE_BATCH_ROLE, _nftreeAddress), "_nftreeAddress not authorized");

        Stake storage s = stakes[_nftreeAddress][_tokenId];

        require(s.isStaked, "NFTree is not staked");
        require(s.owner == _user, "Caller is not the NFTree owner");

        // first drain any user-level remaining rewards
        uint256 remainingReward = userRemainingRewards[_user];
        if (remainingReward > 0) {
            uint256 claimedAmount = stakingPool.claimStakingaCO2(_user, remainingReward);
            userRemainingRewards[_user] = remainingReward - claimedAmount;
            emit ClaimedRemainingRewards(_user, block.timestamp, claimedAmount);
        } else {
            require(s.lastClaimTime + 1 days <= block.timestamp, "NFTree has no pending reward");

            uint256 totalReward = calculateRewards(_tokenId, _nftreeAddress);
            uint256 claimedAmount = stakingPool.claimStakingaCO2(_user, totalReward);
            s.remainingReward = totalReward - claimedAmount;
            s.lastClaimTime = block.timestamp;

            emit Claimed(_user, _nftreeAddress, _tokenId, s.plotAddress, s.plotId, block.timestamp, claimedAmount);
            if (s.remainingReward > 0) {
                emit PartialClaim(_user, _nftreeAddress, _tokenId, block.timestamp, s.remainingReward);
            }
        }
    }

    function claim(uint256 _tokenId, address _nftreeAddress) public {
        _claim(msg.sender, _tokenId, _nftreeAddress);
    }

    function claimMultiple(uint256[] calldata _tokenIds, address[] calldata _nftreeAddresses) external {
        require(_tokenIds.length == _nftreeAddresses.length, "Mismatched arrays length");
        for (uint i = 0; i < _tokenIds.length; i++) {
            claim(_tokenIds[i], _nftreeAddresses[i]);
        }
    }

    function claimForUser(address _user, uint256 _tokenId, address _nftreeAddress) external {
        require(hasRole(CARBIFY_ADMIN_ROLE, msg.sender), "Caller is not authorized");
        _claim(_user, _tokenId, _nftreeAddress);
    }

    // -------- merkle claims --------
    function claimStakingMerkleReward(uint256 amount, bytes32[] calldata merkleProof) public {
        require(merkleRoot != bytes32(0), "Merkle root not set");

        bytes32 claimKey = keccak256(abi.encodePacked(msg.sender, amount));
        require(!claimed[claimKey], "Reward already claimed");

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(verify(merkleProof, merkleRoot, leaf), "Invalid proof");

        uint256 remainingReward = (merkleClaimRemainingRewards[claimKey] > 0)
            ? merkleClaimRemainingRewards[claimKey]
            : amount;

        uint256 claimedAmount = stakingPool.claimStakingaCO2(msg.sender, remainingReward);

        if (claimedAmount < remainingReward) {
            merkleClaimRemainingRewards[claimKey] = remainingReward - claimedAmount;
            emit PartialClaimStakingMerkle(msg.sender, block.timestamp, merkleClaimRemainingRewards[claimKey]);
        } else {
            claimed[claimKey] = true;
        }

        emit ClaimedStakingMerkle(msg.sender, claimedAmount);
    }

    function claimMultipleStakingMerkleRewards(uint256[] calldata amounts, bytes32[][] calldata merkleProofs) external {
        require(amounts.length == merkleProofs.length, "Mismatched amounts and merkleProofs length");
        for (uint256 i = 0; i < amounts.length; i++) {
            claimStakingMerkleReward(amounts[i], merkleProofs[i]);
        }
    }

    function isClaimed(address walletAddress, uint256 amount) external view returns (bool) {
        bytes32 claimKey = keccak256(abi.encodePacked(walletAddress, amount));
        return claimed[claimKey];
    }

    function isClaimedBatch(address walletAddress, uint256[] calldata amounts) external view returns (bool[] memory) {
        bool[] memory results = new bool[](amounts.length);
        for (uint256 i = 0; i < amounts.length; i++) {
            bytes32 claimKey = keccak256(abi.encodePacked(walletAddress, amounts[i]));
            results[i] = claimed[claimKey];
        }
        return results;
    }

    function getStakedNFTreesOfUser(address _user, address _nftreeAddress) external view returns (uint256[] memory) {
        uint256 totalNFTrees = INftree(_nftreeAddress).totalSupply();
        uint256[] memory stakedNFTrees;
        uint256 count = 0;

        for (uint256 i = 0; i < totalNFTrees; i++) {
            if (stakes[_nftreeAddress][i].owner == _user && stakes[_nftreeAddress][i].isStaked) {
                count++;
            }
        }

        stakedNFTrees = new uint256[](count);
        count = 0;

        for (uint256 i = 0; i < totalNFTrees; i++) {
            if (stakes[_nftreeAddress][i].owner == _user && stakes[_nftreeAddress][i].isStaked) {
                stakedNFTrees[count] = i;
                count++;
            }
        }

        return stakedNFTrees;
    }

    function getRemainingMerkleReward(address walletAddress, uint256 amount) external view returns (uint256) {
        bytes32 claimKey = keccak256(abi.encodePacked(walletAddress, amount));
        return merkleClaimRemainingRewards[claimKey];
    }

    function getUserStakes(address _user, address _nftreeAddress) external view returns (uint256[] memory, uint256[] memory) {
        uint256 totalNFTrees = INftree(_nftreeAddress).totalSupply();
        uint256 count = 0;

        for (uint256 i = 1; i <= totalNFTrees; i++) {
            if (stakes[_nftreeAddress][i].owner == _user && stakes[_nftreeAddress][i].isStaked) {
                count++;
            }
        }

        uint256[] memory stakedNFTrees = new uint256[](count);
        uint256[] memory plotIds = new uint256[](count);
        count = 0;

        for (uint256 i = 1; i <= totalNFTrees; i++) {
            if (stakes[_nftreeAddress][i].owner == _user && stakes[_nftreeAddress][i].isStaked) {
                stakedNFTrees[count] = i;
                plotIds[count] = stakes[_nftreeAddress][i].plotId;
                count++;
            }
        }

        return (stakedNFTrees, plotIds);
    }

    // -------- utils --------
    function getUnlockFeePercentage(uint256 duration) private pure returns (uint256) {
        if (duration < 365 days) {
            return 750; // 7.5%
        } else if (duration < 2 * 365 days) {
            return 375; // 3.75%
        } else {
            return 175; // 1.75%
        }
    }

    function setMerkleRoot(bytes32 _merkleRoot) external onlyRole(CARBIFY_ADMIN_ROLE) {
        merkleRoot = _merkleRoot;
    }
    function getMerkleRoot() external view returns (bytes32) {
        return merkleRoot;
    }

    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        return computedHash == root;
    }

    function getRemainingRewards(address _user) external view returns (uint256) {
        return userRemainingRewards[_user];
    }

    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(account) }
        return size > 0;
    }
}
