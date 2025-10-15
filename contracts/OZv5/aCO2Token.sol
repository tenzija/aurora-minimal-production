// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
// import "./CarbonCertificate.sol"; // Assumed to be a UUPS upgradeable contract

contract aCO2Token is Initializable, ERC1155Upgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    string public baseURI; // Base URI for token metadata

    uint256 internal constant GLOBAL_TOKENS_PER_DAY = 0.4794520548 * 10**18; // approximately 0.48 aCO2 per day which is 175 per 365 days!

    uint256 public startTime; // Timestamp of contract deployment

    bytes32 public merkleRoot; // Merkle root for the aCO2 claims

    address[] public batchAddresses; // Array of batch addresses

    mapping(address => uint256) public batchMaxSupply; // Max supply for each batch

    mapping(address => uint256) public batchStartTimes; // Start time for each batch

    mapping(address => uint256) public batchIndexes; // Index of each batch

    mapping(address => uint256) public batchStartId; // Start ID for each batch

    mapping(address => mapping(uint256 => bool)) public tokenGenerationDisabled; // Whether token generation is disabled for an NFTree

    mapping(address => mapping(uint256 => uint256)) public lastClaimTime; // Last time tokens were claimed for an NFTree

    mapping(address => uint256) public tokenEarnRates; // Token earn rate for each batch

    mapping(bytes32 => bool) public claimed; // Whether a merkle reward has been claimed

    // Define a new role identifier for the batch role
    bytes32 public constant NFTREE_BATCH_ROLE = keccak256("NFTREE_BATCH_ROLE");

    // Define a new role identifier for the claimer role
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");

    // Event to track token claim
    event ClaimedTokens(address indexed nftreeAddress, uint256 indexed nftreeId, uint256 amount, address recipient, uint256 indexed timestamp);

    // Event to track merkle claim
    event ClaimedNormalMerkle(address indexed user, address indexed nftreeAddress, uint256 indexed tokenId, uint256 amount);

    // Event to track token earn rate change
    event TokenEarnRateChanged(address indexed batchAddress, uint256 indexed newEarnRate, uint256 indexed timestamp);

    // Batch initialized
    event BatchInitialized(address indexed batchAddress, uint256 indexed batchId, uint256 maxSupply, uint256 indexed startTime);

    // Initializer instead of constructor
    function initialize(string memory _baseURI) public initializer {
        __ERC1155_init(_baseURI);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        baseURI = _baseURI;
        // carbonCertificateContract = CarbonCertificate(_carbonCertificateAddress);

        // Grant the deployer the default admin role: they can grant and revoke any roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(NFTREE_BATCH_ROLE, msg.sender);
        _grantRole(CLAIMER_ROLE, msg.sender);

        startTime = block.timestamp;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Admin function to grant access to an NFTree contract
    function grantAuthorizeRole(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(NFTREE_BATCH_ROLE, account);
    }

    // Admin function to revoke access from an NFTree contract
    function revokeAuthorizeRole(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(NFTREE_BATCH_ROLE, account);
    }

    // Admin function to grant access to a claimer
    function grantClaimerRole(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(CLAIMER_ROLE, account);
    }

    // Admin function to revoke access from a claimer
    function revokeClaimerRole(address account) public onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(CLAIMER_ROLE, account);
    }

    // @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return ERC1155Upgradeable.supportsInterface(interfaceId) || AccessControlUpgradeable.supportsInterface(interfaceId);
    }

    // Override for uri
    function uri(uint256 tokenId) override public view returns (string memory) {
        return string(abi.encodePacked(baseURI, Strings.toString(tokenId), ".json"));
    }

    function setBaseURI(string memory _baseURI) public onlyRole(DEFAULT_ADMIN_ROLE) {
        baseURI = _baseURI;
    }

    // Function to calculate the unique token ID for an NFTree
    function getTokenId(address batchAddress, uint256 nftreeId) public view returns (uint256) {
        require(nftreeId <= batchMaxSupply[batchAddress], "NFTree ID exceeds batch max supply");
        return batchStartId[batchAddress] + nftreeId;
    }

    // Admin function to set the token earn rate for a batch
    function setTokenEarnRate(address batchAddress, uint256 earnRate) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(batchAddress != address(0), "Invalid batch address");
        tokenEarnRates[batchAddress] = earnRate;

        emit TokenEarnRateChanged(batchAddress, earnRate, block.timestamp);
    }

    // Function to get the earn rates for a list of NFTrees
    function getTokenEarnRates(address[] memory nftreeAddresses, uint256[] memory nftreeIds) public view returns (uint256[] memory) {
        require(nftreeAddresses.length == nftreeIds.length, "Addresses and IDs length mismatch");

        uint256[] memory earnRates = new uint256[](nftreeAddresses.length);

        for (uint256 i = 0; i < nftreeAddresses.length; i++) {
            uint256 batchRate = getTokenEarnRate(nftreeAddresses[i]);

            if (batchRate != 0) {
                // Use batch earn rate if it exists and there's no token earn rate
                earnRates[i] = batchRate;
            } else {
                // Default to the global earn rate if no specific or batch rate is found
                earnRates[i] = GLOBAL_TOKENS_PER_DAY;
            }
        }

        return earnRates;
    }

    // Function to set the batch max supply
    function setBatchMaxSupply(address batchAddress, uint256 maxSupply) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(batchAddress != address(0), "Invalid batch address");
        require(maxSupply > 0, "Max supply must be greater than 0");

        batchMaxSupply[batchAddress] = maxSupply;
    }

    // Admin function to set the start time for a batch
    function setBatchStartTime(address batchAddress, uint256 _startTime) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(batchAddress != address(0), "Invalid batch address");
        require(_startTime >= startTime, "Batch start time cannot be before contract start time");
        batchStartTimes[batchAddress] = _startTime;
    }

    // Function to set the batch index
    function setBatchIndex(address batchAddress, uint256 index) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(batchAddress != address(0), "Invalid batch address");

        // Add batch address to array if it's a new batch
        if (index >= batchAddresses.length) {
            batchAddresses.push(batchAddress);
        }

        // Calculate and set the start ID for the batch
        if (index == 0) {
            batchStartId[batchAddress] = 0;
        } else {
            address previousBatchAddress = batchAddresses[index - 1];
            batchStartId[batchAddress] = batchStartId[previousBatchAddress] + batchMaxSupply[previousBatchAddress];
        }

        batchIndexes[batchAddress] = index;
    }

    // Function to get the index of a batch
    function getBatchIndex(address batchAddress) public view returns (uint256) {
        require(batchIndexes[batchAddress] != 0, "Batch address not recognized");
        return batchIndexes[batchAddress];
    }

    // Function to get the start ID of a batch
    function getBatchStartTime(address batchAddress) public view returns (uint256) {
        return batchStartTimes[batchAddress];
    }

    // Get last claim time
    function getLastClaimTime(address nftreeAddress, uint256 nftreeId) public view returns (uint256) {
        return lastClaimTime[nftreeAddress][nftreeId];
    }
    
    // Function to get the token earn rate for a batch
    function getTokenEarnRate(address batchAddress) public view returns (uint256) {
        return tokenEarnRates[batchAddress];
    }

    // Function to get the last claimed times for a list of NFTrees
    function getLastClaimedTimes(address[] memory nftreeAddresses, uint256[] memory nftreeIds) public view returns (uint256[] memory) {
        require(nftreeAddresses.length == nftreeIds.length, "Addresses and IDs length mismatch");

        uint256[] memory lastClaimedTimes = new uint256[](nftreeAddresses.length);

        for (uint256 i = 0; i < nftreeAddresses.length; i++) {
            uint256 lastClaimed = lastClaimTime[nftreeAddresses[i]][nftreeIds[i]];
            if (lastClaimed == 0) {
                // Use batch-specific start time if set, otherwise use global start time
                lastClaimedTimes[i] = batchStartTimes[nftreeAddresses[i]] > 0 ? batchStartTimes[nftreeAddresses[i]] : startTime;
            } else {
                lastClaimedTimes[i] = lastClaimed;
            }
        }

        return lastClaimedTimes;
    }

    // Function to burn multiple aCO2 tokens
    function _batchBurn(address owner, uint256[] memory tokenIds, uint256[] memory amounts) internal {
        require(tokenIds.length == amounts.length, "Token IDs and amounts length mismatch");
        _burnBatch(owner, tokenIds, amounts);
    }

    function batchBurn(uint256[] memory tokenIds, uint256[] memory amounts) public {
        _batchBurn(msg.sender, tokenIds, amounts);
    }

    function batchBurnDelegate(address owner, uint256[] memory tokenIds, uint256[] memory amounts) public {
        require(isApprovedForAll(owner, msg.sender), "Not approved to burn");
        _batchBurn(owner, tokenIds, amounts);
    }

    function batchBurnDelegateAdmin(address owner, uint256[] memory tokenIds, uint256[] memory amounts) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _batchBurn(owner, tokenIds, amounts);
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) public override {
        super.safeTransferFrom(from, to, id, amount, data);
    }

    // Internal function to handle the logic of claiming tokens
    function _claimTokens(address[] memory nftreeAddresses, uint256[] memory nftreeIds, address recipient) internal {
        require(nftreeAddresses.length == nftreeIds.length, "Arrays length mismatch");

        uint256[] memory idsToMint = new uint256[](nftreeAddresses.length);
        uint256[] memory amountsToMint = new uint256[](nftreeIds.length);
        bool shouldMint = false;

        for (uint256 i = 0; i < nftreeAddresses.length; i++) {
            require(!tokenGenerationDisabled[nftreeAddresses[i]][nftreeIds[i]], "Token generation disabled");

            uint256 tokenId = getTokenId(nftreeAddresses[i], nftreeIds[i]);
            uint256 batchSpecificStartTime = getBatchStartTime(nftreeAddresses[i]) > 0 
                ? getBatchStartTime(nftreeAddresses[i]) 
                : startTime;
            uint256 lastClaimed = getLastClaimTime(nftreeAddresses[i], nftreeIds[i]) == 0 
                ? batchSpecificStartTime 
                : getLastClaimTime(nftreeAddresses[i], nftreeIds[i]);
            uint256 currentTime = block.timestamp;
            uint256 earnRate = getTokenEarnRate(nftreeAddresses[i]) > 0 
                ? getTokenEarnRate(nftreeAddresses[i]) 
                : GLOBAL_TOKENS_PER_DAY;
            uint256 tokenAmount = ((currentTime - lastClaimed) * earnRate) / 86400;

            if (tokenAmount > 0) {
                idsToMint[i] = tokenId;
                amountsToMint[i] = tokenAmount;
                lastClaimTime[nftreeAddresses[i]][nftreeIds[i]] = currentTime;
                shouldMint = true;
            }
        }

        if (shouldMint) {
            _mintBatch(recipient, idsToMint, amountsToMint, "");
            for (uint256 i = 0; i < nftreeAddresses.length; i++) {
                emit ClaimedTokens(nftreeAddresses[i], nftreeIds[i], amountsToMint[i], recipient, block.timestamp);
            }
        }
    }

    // Function to claim aCO2 tokens on transfer for a single NFTree
    function claimTokens(address[] memory nftreeAddresses, uint256[] memory nftreeIds) public {
        require(nftreeAddresses.length == nftreeIds.length, "Arrays length mismatch");
        for (uint256 i = 0; i < nftreeAddresses.length; i++) {
            require(msg.sender == IERC721(nftreeAddresses[i]).ownerOf(nftreeIds[i]) && hasRole(NFTREE_BATCH_ROLE, nftreeAddresses[i]), "Not authorized to claim");
            require(!tokenGenerationDisabled[nftreeAddresses[i]][nftreeIds[i]], "Token generation disabled");
        }
        _claimTokens(nftreeAddresses, nftreeIds, msg.sender);
    }

    // Function to claim aCO2 tokens on transfer for multiple NFTrees
    function claimTokensForUsers(address[] memory nftreeAddresses, uint256[] memory nftreeIds, address recipient) public onlyRole(CLAIMER_ROLE) {
        require(nftreeAddresses.length == nftreeIds.length, "Arrays length mismatch");

        for (uint256 i = 0; i < nftreeAddresses.length; i++) {
            require(
                IERC721(nftreeAddresses[i]).ownerOf(nftreeIds[i]) == recipient && 
                hasRole(NFTREE_BATCH_ROLE, nftreeAddresses[i]) &&
                hasRole(CLAIMER_ROLE, msg.sender), 
                "Not authorized to claim"
            );
            require(!tokenGenerationDisabled[nftreeAddresses[i]][nftreeIds[i]], "Token generation disabled");
        }

        _claimTokens(nftreeAddresses, nftreeIds, recipient);
    }

    // Function to claim aCO2 tokens on transfer for multiple NFTrees for an approved user
    function claimTokensForUsersApproved(address[] memory nftreeAddresses, uint256[] memory nftreeIds, address owner) public {
        require(nftreeAddresses.length == nftreeIds.length, "Arrays length mismatch");

        for (uint256 i = 0; i < nftreeAddresses.length; i++) {
            require(
                isApprovedForAll(owner, msg.sender)  &&
                IERC721(nftreeAddresses[i]).ownerOf(nftreeIds[i]) == owner &&
                hasRole(NFTREE_BATCH_ROLE, nftreeAddresses[i]),
                "Not authorized to claim on behalf of owner"
            );
            require(!tokenGenerationDisabled[nftreeAddresses[i]][nftreeIds[i]], "Token generation disabled");
        }

        _claimTokens(nftreeAddresses, nftreeIds, owner);
    }

    function _claimMerkleRewards(
        address owner,
        uint256[] calldata nftreeIds, 
        uint256[] calldata amounts, 
        address[] calldata nftreeAddresses, 
        bytes32[][] calldata merkleProofs
    ) internal {
        require(nftreeIds.length == amounts.length, "Mismatched nftreeIds and amounts length");
        require(nftreeIds.length == nftreeAddresses.length, "Mismatched nftreeIds and nftreeAddresses length");
        require(nftreeIds.length == merkleProofs.length, "Mismatched nftreeIds and merkleProofs length");

        uint256[] memory aco2TokenIds = new uint256[](nftreeIds.length);
        uint256[] memory mintAmounts = new uint256[](amounts.length);

        for (uint256 i = 0; i < nftreeIds.length; i++) {
            require(!tokenGenerationDisabled[nftreeAddresses[i]][nftreeIds[i]], "Token generation disabled");

            bytes32 leaf = keccak256(abi.encodePacked(owner, nftreeAddresses[i], nftreeIds[i], amounts[i]));
            bytes32 claimKey = leaf;

            require(!claimed[claimKey], "Reward already claimed");
            require(verify(merkleProofs[i], merkleRoot, leaf), "Invalid proof");

            aco2TokenIds[i] = getTokenId(nftreeAddresses[i], nftreeIds[i]);
            mintAmounts[i] = amounts[i];

            claimed[claimKey] = true;
            emit ClaimedNormalMerkle(owner, nftreeAddresses[i], nftreeIds[i], amounts[i]);
        }

        _mintBatch(owner, aco2TokenIds, mintAmounts, "");
    }

    function claimRegularMerkleReward(uint256[] calldata nftreeIds, uint256[] calldata amounts, address[] calldata nftreeAddresses, bytes32[][] calldata merkleProofs) public {
        _claimMerkleRewards(msg.sender, nftreeIds, amounts, nftreeAddresses, merkleProofs);
    }

    function claimRegularMerkleRewardDelegate(address owner, uint256[] calldata nftreeIds, uint256[] calldata amounts, address[] calldata nftreeAddresses, bytes32[][] calldata merkleProofs) public {
        require(isApprovedForAll(owner, msg.sender), "Not approved to claim");
        _claimMerkleRewards(owner, nftreeIds, amounts, nftreeAddresses, merkleProofs);
    }

    // Function to see if a leaf has been claimed
    function _isClaimed(address claimer, uint256 nftreeId, address nftreeAddress, uint256 amount) internal view returns (bool) {
        // Create a composite key from aCO2TokenId and nftreeAddress
        bytes32 claimKey = keccak256(abi.encodePacked(claimer, nftreeAddress, nftreeId, amount));

        return claimed[claimKey];
    }

    // Batch function to see if a list of leaves have been claimed
    function isClaimedBatch(address claimer, uint256[] memory nftreeIds, address[] memory nftreeAddresses, uint256[] memory amounts) public view returns (bool[] memory) {
        require(nftreeIds.length == nftreeAddresses.length, "Arrays length mismatch");
        require(nftreeIds.length == amounts.length, "Arrays length mismatch");

        bool[] memory claimedStatuses = new bool[](nftreeIds.length);

        for (uint256 i = 0; i < nftreeIds.length; i++) {
            claimedStatuses[i] = _isClaimed(claimer, nftreeIds[i], nftreeAddresses[i], amounts[i]);
        }

        return claimedStatuses;
    }

    // Function to update the Merkle root (callable by owner or admin)
    function setMerkleRoot(bytes32 _merkleRoot) external onlyRole(DEFAULT_ADMIN_ROLE)  {
        // require(admin or owner)
        merkleRoot = _merkleRoot;
    }

    // Function to get the Merkle root
    function getMerkleRoot() external view returns (bytes32) {
        return merkleRoot;
    }

    // Function to verify Merkle proof
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                // Hash(current computed hash + current element of the proof)
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                // Hash(current element of the proof + current computed hash)
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        return computedHash == root;
    }

    // Function to disable token generation for an NFTree
    function disableTokenGeneration(address nftreeAddress, uint256 nftreeId) public onlyRole(DEFAULT_ADMIN_ROLE) {
        address[] memory addresses = new address[](1);
        uint256[] memory ids = new uint256[](1);

        addresses[0] = nftreeAddress;
        ids[0] = nftreeId;

        claimTokensForUsers(addresses, ids, IERC721(nftreeAddress).ownerOf(nftreeId)); // Claim tokens for the NFTree and send them to the owner
        tokenGenerationDisabled[nftreeAddress][nftreeId] = true;
    }

    // Function to enable token generation for an NFTree
    function enableTokenGeneration(address nftreeAddress, uint256 nftreeId) public onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenGenerationDisabled[nftreeAddress][nftreeId] = false;
        lastClaimTime[nftreeAddress][nftreeId] = block.timestamp; // Reset last claim time
    }

    // Function to calculate the pending token amount for an NFTree
    function getPendingTokenAmount(address nftreeAddress, uint256 nftreeId) public view returns (uint256) {
        uint256 batchSpecificStartTime = getBatchStartTime(nftreeAddress) > 0 
            ? getBatchStartTime(nftreeAddress) 
            : startTime;
        uint256 lastClaimed = getLastClaimTime(nftreeAddress, nftreeId) == 0 
            ? batchSpecificStartTime 
            : getLastClaimTime(nftreeAddress, nftreeId);
        uint256 currentTime = block.timestamp;
        uint256 earnRate = getTokenEarnRate(nftreeAddress) > 0 
            ? getTokenEarnRate(nftreeAddress) 
            : GLOBAL_TOKENS_PER_DAY;
        uint256 tokenAmount = ((currentTime - lastClaimed) * earnRate) / 86400;
        return tokenAmount;
    }

    // Initialize batch details
    function initializeBatchDetails(
        address batchAddress,
        uint256 index,
        uint256 maxSupply,
        uint256 startTimeValue
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(batchAddress != address(0), "Invalid batch address");
        require(maxSupply > 0, "Max supply must be greater than 0");

        // Ensure contiguous indices and allow setting existing slot
        if (index == batchAddresses.length) {
            batchAddresses.push(batchAddress);
        } else {
            require(index < batchAddresses.length, "Index gap");
            address current = batchAddresses[index];
            require(current == address(0) || current == batchAddress, "Index already assigned");
            batchAddresses[index] = batchAddress;
        }

        // Compute startId from previous batch (requires ascending order)
        if (index == 0) {
            batchStartId[batchAddress] = 0;
        } else {
            address prev = batchAddresses[index - 1];
            require(prev != address(0), "Prev batch not set");
            uint256 prevMax = batchMaxSupply[prev];
            require(prevMax > 0, "Prev batch maxSupply not set");
            batchStartId[batchAddress] = batchStartId[prev] + prevMax;
        }

        batchIndexes[batchAddress] = index;
        batchMaxSupply[batchAddress] = maxSupply;
        batchStartTimes[batchAddress] = startTimeValue;

        _grantRole(NFTREE_BATCH_ROLE, batchAddress);
        _grantRole(CLAIMER_ROLE, batchAddress);

        emit BatchInitialized(batchAddress, index, maxSupply, startTimeValue);
    }

    function name() external pure returns (string memory) {
        return "Absorbed CO2";
    }

    function symbol() external pure returns (string memory) {
        return "aCO2";
    }
}
