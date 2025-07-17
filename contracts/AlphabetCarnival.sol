// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/IVRFCoordinatorV2Plus.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract AlphabetCarnival is VRFConsumerBaseV2Plus, ReentrancyGuard {
    struct WinnerClaim {
        address player;
        uint8[3] chosenLetters;
        uint8 prizeLevel;
        uint256 prizeAmount;
        uint256 round;
    }

    event TicketBought(uint256 indexed round, address indexed player, uint8[3] chosenLetters);
    event DrawTriggeredAndRandomnessRequested(uint256 indexed round, uint256 ticketsSold, uint256 indexed requestId);
    event WinningLettersDrawn(uint256 indexed round, uint8[] winningLetters);
    event MerkleRootSubmitted(uint256 indexed round, bytes32 indexed merkleRoot);
    event OperationalFeesDistributed(uint256 indexed round, address indexed receiver, uint256 amount);
    event PrizeClaimed(address indexed player, uint256 indexed round, uint8 prizeLevel, uint256 amount);
    event TicketPriceUpdated(uint256 newPrice);
    event TicketsPerRoundThresholdUpdated(uint256 newThreshold);
    event OperationalFeeReceiversUpdated(address indexed receiver1, address indexed receiver2, uint8 share1);

    uint256 public constant OPERATIONAL_FEE_PERCENTAGE = 6;

    IVRFCoordinatorV2Plus internal immutable i_vrfCoordinator;
    bytes32 private immutable i_keyHash;
    uint32 private immutable i_callbackGasLimit;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1; 
    uint64 private s_subscriptionId;

    mapping(uint256 => address) public s_requestToAddress;
    mapping(uint256 => uint256) public s_requestToRound; 
    bool public s_isRequestPending;

    uint256 public currentRound;
    uint256 public ticketsSoldInCurrentRound;
    uint256 public prizePool;
    uint256 public ticketPrice;
    uint256 public ticketsPerRoundThreshold;

    address public operationalFeeReceiver1;
    address public operationalFeeReceiver2;
    uint8 public operationalFeeShare1; 
    uint256 public accumulatedOperationalFees;

    mapping(uint256 => bytes32) public roundMerkleRoots;
    mapping(bytes32 => bool) public claimedLeaves;
    mapping(uint256 => uint8[]) private s_roundWinningLetters;

    constructor(
        address _vrfCoordinatorAddress,
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        uint64 _subscriptionId,
        address _initialOperationalFeeReceiver1,
        address _initialOperationalFeeReceiver2,
        uint8 _initialOperationalFeeShare1,
        uint256 _initialTicketPrice,
        uint256 _initialTicketsPerRoundThreshold
    )
        VRFConsumerBaseV2Plus(_vrfCoordinatorAddress)
    {
        i_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinatorAddress);
        i_keyHash = _keyHash;
        i_callbackGasLimit = _callbackGasLimit;
        s_subscriptionId = _subscriptionId;
        operationalFeeReceiver1 = _initialOperationalFeeReceiver1;
        operationalFeeReceiver2 = _initialOperationalFeeReceiver2;
        operationalFeeShare1 = _initialOperationalFeeShare1;
        ticketPrice = _initialTicketPrice;
        ticketsPerRoundThreshold = _initialTicketsPerRoundThreshold;
        currentRound = 1;
    }

    function buyTicket(uint8[3] calldata _chosenLetters) external payable {
        require(msg.value == ticketPrice, "Incorrect ticket price.");
        require(!s_isRequestPending, "Draw in progress, please wait.");
        require(_chosenLetters.length == 3, "Must choose 3 letters.");

        ticketsSoldInCurrentRound++;
        prizePool += msg.value;

        emit TicketBought(currentRound, msg.sender, _chosenLetters);

        if (ticketsSoldInCurrentRound >= ticketsPerRoundThreshold) {
            _triggerDraw();
        }
    }

    function submitWinnersMerkleRoot(
        uint256 _round,
        bytes32 _merkleRoot,
        uint256 _finalPrizePoolForRound
    ) external onlyOwner { 
        require(roundMerkleRoots[_round] == bytes32(0), "Merkle root already submitted for this round.");
        require(s_roundWinningLetters[_round].length > 0, "Draw for this round has not been completed yet.");

        roundMerkleRoots[_round] = _merkleRoot;
        _distributeOperationalFees(_round, _finalPrizePoolForRound);
        emit MerkleRootSubmitted(_round, _merkleRoot);
    }

    function claimPrize(
        WinnerClaim calldata _claim,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        require(_claim.player == msg.sender, "You can only claim for yourself.");
        require(roundMerkleRoots[_claim.round] != bytes32(0), "Prizes for this round are not claimable yet.");

        bytes32 leaf = keccak256(abi.encode(_claim.player, _claim.chosenLetters, _claim.prizeLevel, _claim.prizeAmount, _claim.round));

        require(!claimedLeaves[leaf], "Prize already claimed.");

        require(
            MerkleProof.verify(_merkleProof, roundMerkleRoots[_claim.round], leaf),
            "Invalid Merkle Proof."
        );

        claimedLeaves[leaf] = true;
        (bool success, ) = payable(msg.sender).call{value: _claim.prizeAmount}("");
        require(success, "Failed to send prize money.");

        emit PrizeClaimed(msg.sender, _claim.round, _claim.prizeLevel, _claim.prizeAmount);
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        require(s_requestToAddress[_requestId] != address(0), "Invalid request ID.");

        uint256 round = s_requestToRound[_requestId];
        uint256 randomValue = _randomWords[0];

        uint8[] memory winningLetters = new uint8[](8);
        uint256 remainingValue = randomValue;
        uint256 alphabetSize = 26;
        bool[27] memory used; 

        for (uint i = 0; i < 8; i++) {
            uint8 letter = uint8((remainingValue % alphabetSize) + 1);
            remainingValue /= alphabetSize;
            if (used[letter]) {
                for (uint j = 1; j < 27; j++) {
                    uint8 nextLetter = (letter + uint8(j));
                    if(nextLetter > 26) nextLetter -= 26;
                    if (!used[nextLetter]) {
                        letter = nextLetter;
                        break;
                    }
                }
            }
            used[letter] = true;
            winningLetters[i] = letter;
        }

        s_roundWinningLetters[round] = winningLetters;
        delete s_requestToAddress[_requestId];
        delete s_requestToRound[_requestId];
        s_isRequestPending = false;
        currentRound++;
        ticketsSoldInCurrentRound = 0;
        prizePool = 0; 
        emit WinningLettersDrawn(round, winningLetters);
    }

    function _triggerDraw() internal {
        s_isRequestPending = true;

        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            IVRFCoordinatorV2Plus.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: i_callbackGasLimit,
                numWords: NUM_WORDS
            })
        );

        s_requestToAddress[requestId] = address(this);
        s_requestToRound[requestId] = currentRound;
        emit DrawTriggeredAndRandomnessRequested(currentRound, ticketsSoldInCurrentRound, requestId);
    }

    function _distributeOperationalFees(uint256 _round, uint256 _prizePoolForRound) internal {
        uint256 feeAmount = (_prizePoolForRound * OPERATIONAL_FEE_PERCENTAGE) / 100;
        accumulatedOperationalFees += feeAmount;
        uint256 share1 = (feeAmount * operationalFeeShare1) / 100;
        uint256 share2 = feeAmount - share1;

        if (share1 > 0) {
            (bool success, ) = payable(operationalFeeReceiver1).call{value: share1}("");
            if (success) emit OperationalFeesDistributed(_round, operationalFeeReceiver1, share1);
        }
        if (share2 > 0) {
            (bool success, ) = payable(operationalFeeReceiver2).call{value: share2}("");
            if (success) emit OperationalFeesDistributed(_round, operationalFeeReceiver2, share2);
        }
    }

    function setTicketPrice(uint256 _newPrice) external onlyOwner {
        require(_newPrice > 0, "Price must be positive.");
        ticketPrice = _newPrice;
        emit TicketPriceUpdated(_newPrice);
    }

    function setTicketsPerRoundThreshold(uint256 _newThreshold) external onlyOwner {
        require(_newThreshold > 0, "Threshold must be positive.");
        ticketsPerRoundThreshold = _newThreshold;
        emit TicketsPerRoundThresholdUpdated(_newThreshold);
    }

    function setOperationalFeeDistribution(address _receiver1, address _receiver2, uint8 _share1) external onlyOwner {
        require(_share1 <= 100, "Share cannot exceed 100.");
        operationalFeeReceiver1 = _receiver1;
        operationalFeeReceiver2 = _receiver2;
        operationalFeeShare1 = _share1;
        emit OperationalFeeReceiversUpdated(_receiver1, _receiver2, _share1);
    }

    function setSubscriptionId(uint64 _subId) external onlyOwner {
        s_subscriptionId = _subId;
    }

    function getWinningLetters(uint256 _round) external view returns (uint8[] memory) {
        return s_roundWinningLetters[_round];
    }

    receive() external payable {}
    fallback() external payable {}
}