// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OpenOracle
 * @notice A trust-free price oracle that uses an escalating auction mechanism
 * @dev This contract enables price discovery through economic incentives where
 *      expiration serves as evidence of a good price with appropriate parameters
 * @author OpenOracle Team
 * @custom:version 0.1.6
 * @custom:documentation https://openprices.gitbook.io/openoracle-docs
 */
contract OpenOracle is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Custom errors for gas optimization
    error InvalidInput(string parameter);
    error InsufficientAmount(string resource);
    error AlreadyProcessed(string action);
    error InvalidTiming(string action);
    error OutOfBounds(string parameter);
    error TokensCannotBeSame();
    error NoReportToDispute();
    error DisputeAlreadyInBlock();
    error EthTransferFailed();
    error CallToArbSysFailed();

    // Constants
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant PERCENTAGE_PRECISION = 1e7;
    uint256 public constant MULTIPLIER_PRECISION = 100;
    uint256 public constant SETTLEMENT_WINDOW = 60; // 60 seconds for testing

    // State variables
    uint256 public nextReportId = 1;
    address public protocolFeeRecipient;

    mapping(uint256 => ReportMeta) public reportMeta;
    mapping(uint256 => ReportStatus) public reportStatus;
    mapping(address => uint256) public protocolFees;

    // Type declarations
    struct ReportMeta {
        address token1;
        address token2;
        uint256 feePercentage;
        uint256 multiplier;
        uint256 settlementTime;
        uint256 exactToken1Report;
        uint256 fee;
        uint256 escalationHalt;
        uint256 disputeDelay;
        uint256 protocolFee;
        uint256 settlerReward;
        uint256 requestBlock;
    }

    struct ReportStatus {
        uint256 currentAmount1;
        uint256 currentAmount2;
        address payable currentReporter;
        address payable initialReporter;
        uint256 reportTimestamp;
        uint256 settlementTimestamp;
        uint256 price;
        uint256 lastDisputeBlock;
        bool isSettled;
        bool disputeOccurred;
        bool isDistributed;
    }

    // Events
    event ReportInstanceCreated(
        uint256 indexed reportId,
        address indexed token1Address,
        address indexed token2Address,
        uint256 feePercentage,
        uint256 multiplier,
        uint256 exactToken1Report,
        uint256 ethFee,
        address creator,
        uint256 settlementTime,
        uint256 escalationHalt,
        uint256 disputeDelay,
        uint256 protocolFee,
        uint256 settlerReward
    );

    event InitialReportSubmitted(
        uint256 indexed reportId,
        address reporter,
        uint256 amount1,
        uint256 amount2,
        address indexed token1Address,
        address indexed token2Address,
        uint256 swapFee,
        uint256 protocolFee,
        uint256 settlementTime,
        uint256 disputeDelay,
        uint256 escalationHalt
    );

    event ReportDisputed(
        uint256 indexed reportId,
        address disputer,
        uint256 newAmount1,
        uint256 newAmount2,
        address indexed token1Address,
        address indexed token2Address,
        uint256 swapFee,
        uint256 protocolFee,
        uint256 settlementTime,
        uint256 disputeDelay,
        uint256 escalationHalt
    );

    event ReportSettled(uint256 indexed reportId, uint256 price, uint256 settlementTimestamp);

    event ProtocolFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    constructor() ReentrancyGuard() Ownable(msg.sender) {
        protocolFeeRecipient = 0x043c740dB5d907aa7604c2E8E9E0fffF435fa0e4;
    }

    /**
     * @notice Updates the protocol fee recipient address
     * @param newRecipient The new protocol fee recipient address
     */
    function updateProtocolFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient address");
        address oldRecipient = protocolFeeRecipient;
        protocolFeeRecipient = newRecipient;
        emit ProtocolFeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Withdraws accumulated protocol fees for a specific token
     * @param tokenToGet The token address to withdraw fees for
     */
    function getProtocolFees(address tokenToGet) external nonReentrant {
        uint256 amount = protocolFees[tokenToGet];
        if (amount > 0) {
            protocolFees[tokenToGet] = 0;
            _transferTokens(tokenToGet, address(this), payable(protocolFeeRecipient), amount);
        }
    }

    /**
     * @notice Settles a report after the settlement time has elapsed
     * @param reportId The unique identifier for the report to settle
     * @return price The final settled price
     * @return settlementTimestamp The timestamp when the report was settled
     */
    function settle(uint256 reportId) external nonReentrant returns (uint256 price, uint256 settlementTimestamp) {
        ReportStatus storage status = reportStatus[reportId];
        ReportMeta storage meta = reportMeta[reportId];

        if (status.isSettled || status.isDistributed) {
            return status.isSettled ? (status.price, status.settlementTimestamp) : (0, 0);
        }

        if (block.timestamp < status.reportTimestamp + meta.settlementTime) {
            revert InvalidTiming("settlement");
        }

        uint256 settlerReward = meta.settlerReward;
        uint256 reporterReward = meta.fee;
        bool isWithinWindow = block.timestamp <= status.reportTimestamp + meta.settlementTime + SETTLEMENT_WINDOW;

        if (isWithinWindow) {
            status.isSettled = true;
            status.settlementTimestamp = block.timestamp;
            emit ReportSettled(reportId, status.price, status.settlementTimestamp);
        }

        _sendEth(payable(msg.sender), settlerReward);

        if (status.disputeOccurred) {
            _sendEth(payable(protocolFeeRecipient), reporterReward);
        } else {
            _sendEth(status.initialReporter, reporterReward);
        }

        _transferTokens(meta.token1, address(this), status.currentReporter, status.currentAmount1);
        _transferTokens(meta.token2, address(this), status.currentReporter, status.currentAmount2);

        status.isDistributed = true;

        return status.isSettled ? (status.price, status.settlementTimestamp) : (0, 0);
    }

    /**
     * @notice Gets the settlement data for a settled report
     * @param reportId The unique identifier for the report
     * @return price The settled price
     * @return settlementTimestamp The timestamp when the report was settled
     */
    function getSettlementData(uint256 reportId) external view returns (uint256 price, uint256 settlementTimestamp) {
        ReportStatus storage status = reportStatus[reportId];
        if (!status.isSettled) revert AlreadyProcessed("not settled");
        return (status.price, status.settlementTimestamp);
    }

    /**
     * @notice Creates a new report instance for price discovery
     * @param token1Address Address of the first token
     * @param token2Address Address of the second token
     * @param exactToken1Report Exact amount of token1 required for reports
     * @param feePercentage Fee in thousandths of basis points (3000 = 3bps)
     * @param multiplier Multiplier in percentage points (110 = 1.1x)
     * @param settlementTime Time in seconds before report can be settled
     * @param escalationHalt Threshold where multiplier drops to 100
     * @param disputeDelay Delay in seconds before disputes are allowed
     * @param protocolFee Protocol fee in thousandths of basis points
     * @param settlerReward Reward for settling the report in wei
     * @return reportId The unique identifier for the created report
     */
    function createReportInstance(
        address token1Address,
        address token2Address,
        uint256 exactToken1Report,
        uint256 feePercentage,
        uint256 multiplier,
        uint256 settlementTime,
        uint256 escalationHalt,
        uint256 disputeDelay,
        uint256 protocolFee,
        uint256 settlerReward
    ) external payable returns (uint256 reportId) {
        if (msg.value <= 100) revert InsufficientAmount("fee");
        if (exactToken1Report == 0) revert InvalidInput("token amount");
        if (token1Address == token2Address) revert TokensCannotBeSame();
        if (settlementTime <= disputeDelay) revert InvalidTiming("settlement vs dispute delay");
        if (msg.value <= settlerReward) revert InsufficientAmount("settler reward fee");

        reportId = nextReportId++;

        ReportMeta storage meta = reportMeta[reportId];
        meta.token1 = token1Address;
        meta.token2 = token2Address;
        meta.exactToken1Report = exactToken1Report;
        meta.feePercentage = feePercentage;
        meta.multiplier = multiplier;
        meta.settlementTime = settlementTime;
        meta.fee = msg.value - settlerReward;
        meta.escalationHalt = escalationHalt;
        meta.disputeDelay = disputeDelay;
        meta.protocolFee = protocolFee;
        meta.settlerReward = settlerReward;
        meta.requestBlock = block.number;

        emit ReportInstanceCreated(
            reportId,
            token1Address,
            token2Address,
            feePercentage,
            multiplier,
            exactToken1Report,
            msg.value,
            msg.sender,
            settlementTime,
            escalationHalt,
            disputeDelay,
            protocolFee,
            settlerReward
        );
    }

    /**
     * @notice Submits the initial price report for a given report ID
     * @param reportId The unique identifier for the report
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Amount of token2 for the price ratio
     */
    function submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2) external nonReentrant {
        ReportMeta storage meta = reportMeta[reportId];
        ReportStatus storage status = reportStatus[reportId];

        if (reportId > nextReportId) revert InvalidInput("report id");
        if (status.currentReporter != address(0)) revert AlreadyProcessed("report submitted");
        if (amount1 != meta.exactToken1Report) revert InvalidInput("token1 amount");
        if (amount2 == 0) revert InvalidInput("token2 amount");

        _transferTokens(meta.token1, msg.sender, address(this), amount1);
        _transferTokens(meta.token2, msg.sender, address(this), amount2);

        status.currentAmount1 = amount1;
        status.currentAmount2 = amount2;
        status.currentReporter = payable(msg.sender);
        status.initialReporter = payable(msg.sender);
        status.reportTimestamp = block.timestamp;
        status.price = (amount1 * PRICE_PRECISION) / amount2;

        emit InitialReportSubmitted(
            reportId,
            msg.sender,
            amount1,
            amount2,
            meta.token1,
            meta.token2,
            meta.feePercentage,
            meta.protocolFee,
            meta.settlementTime,
            meta.disputeDelay,
            meta.escalationHalt
        );
    }

    /**
     * @notice Disputes an existing report and swaps tokens to update the price
     * @param reportId The unique identifier for the report to dispute
     * @param tokenToSwap The token being swapped (token1 or token2)
     * @param newAmount1 New amount of token1 after the dispute
     * @param newAmount2 New amount of token2 after the dispute
     */
    function disputeAndSwap(uint256 reportId, address tokenToSwap, uint256 newAmount1, uint256 newAmount2)
        external
        nonReentrant
    {
        ReportMeta storage meta = reportMeta[reportId];
        ReportStatus storage status = reportStatus[reportId];

        _validateDispute(reportId, tokenToSwap, newAmount1, newAmount2, meta, status);

        if (tokenToSwap == meta.token1) {
            _handleToken1Swap(meta, status, newAmount2);
        } else if (tokenToSwap == meta.token2) {
            _handleToken2Swap(meta, status, newAmount2);
        } else {
            revert InvalidInput("token to swap");
        }

        // Update the report status after the dispute and swap
        status.currentAmount1 = newAmount1;
        status.currentAmount2 = newAmount2;
        status.currentReporter = payable(msg.sender);
        status.reportTimestamp = block.timestamp;
        status.price = (newAmount1 * PRICE_PRECISION) / newAmount2;
        status.disputeOccurred = true;
        status.lastDisputeBlock = _getBlockNumber();

        emit ReportDisputed(
            reportId,
            msg.sender,
            newAmount1,
            newAmount2,
            meta.token1,
            meta.token2,
            meta.feePercentage,
            meta.protocolFee,
            meta.settlementTime,
            meta.disputeDelay,
            meta.escalationHalt
        );
    }

    /**
     * @dev Validates that a dispute is valid according to the oracle rules
     */
    function _validateDispute(
        uint256 reportId,
        address tokenToSwap,
        uint256 newAmount1,
        uint256 newAmount2,
        ReportMeta storage meta,
        ReportStatus storage status
    ) internal view {
        if (reportId > nextReportId) revert InvalidInput("report id");
        if (newAmount1 == 0 || newAmount2 == 0) revert InvalidInput("token amounts");
        if (status.currentReporter == address(0)) revert NoReportToDispute();
        if (block.timestamp > status.reportTimestamp + meta.settlementTime) {
            revert InvalidTiming("dispute period expired");
        }
        if (status.isSettled) revert AlreadyProcessed("report settled");
        if (status.isDistributed) revert AlreadyProcessed("report distributed");
        if (tokenToSwap != meta.token1 && tokenToSwap != meta.token2) revert InvalidInput("token to swap");
        if (status.lastDisputeBlock == _getBlockNumber()) revert DisputeAlreadyInBlock();
        if (block.timestamp < status.reportTimestamp + meta.disputeDelay) revert InvalidTiming("dispute too early");

        uint256 oldAmount1 = status.currentAmount1;
        uint256 expectedAmount1;

        if (meta.escalationHalt > oldAmount1) {
            expectedAmount1 = (oldAmount1 * meta.multiplier) / MULTIPLIER_PRECISION;
        } else {
            expectedAmount1 = oldAmount1;
        }

        if (newAmount1 != expectedAmount1) {
            if (meta.escalationHalt <= oldAmount1) {
                revert OutOfBounds("escalation halted");
            } else {
                revert InvalidInput("new amount");
            }
        }

        uint256 oldPrice = (oldAmount1 * PRICE_PRECISION) / status.currentAmount2;
        uint256 feeBoundary = (oldPrice * meta.feePercentage) / PERCENTAGE_PRECISION;
        uint256 lowerBoundary = oldPrice > feeBoundary ? oldPrice - feeBoundary : 0;
        uint256 upperBoundary = oldPrice + feeBoundary;
        uint256 newPrice = (newAmount1 * PRICE_PRECISION) / newAmount2;

        if (newPrice >= lowerBoundary && newPrice <= upperBoundary) {
            revert OutOfBounds("price within boundaries");
        }
    }

    /**
     * @dev Handles token swaps when token1 is being swapped during a dispute
     */
    function _handleToken1Swap(ReportMeta storage meta, ReportStatus storage status, uint256 newAmount2) internal {
        uint256 oldAmount1 = status.currentAmount1;
        uint256 oldAmount2 = status.currentAmount2;
        uint256 fee = (oldAmount1 * meta.feePercentage) / PERCENTAGE_PRECISION;
        uint256 protocolFee = (oldAmount1 * meta.protocolFee) / PERCENTAGE_PRECISION;

        protocolFees[meta.token1] += protocolFee;

        IERC20(meta.token1).safeTransferFrom(msg.sender, address(this), oldAmount1 + fee + protocolFee);
        IERC20(meta.token1).safeTransfer(status.currentReporter, 2 * oldAmount1 + fee);

        uint256 requiredToken1Contribution =
            meta.escalationHalt > oldAmount1 ? (oldAmount1 * meta.multiplier) / MULTIPLIER_PRECISION : oldAmount1;

        uint256 netToken2Contribution = newAmount2 >= oldAmount2 ? newAmount2 - oldAmount2 : 0;
        uint256 netToken2Receive = newAmount2 < oldAmount2 ? oldAmount2 - newAmount2 : 0;

        if (netToken2Contribution > 0) {
            IERC20(meta.token2).safeTransferFrom(msg.sender, address(this), netToken2Contribution);
        }

        if (netToken2Receive > 0) {
            IERC20(meta.token2).safeTransfer(msg.sender, netToken2Receive);
        }

        IERC20(meta.token1).safeTransferFrom(msg.sender, address(this), requiredToken1Contribution);
    }

    /**
     * @dev Handles token swaps when token2 is being swapped during a dispute
     */
    function _handleToken2Swap(ReportMeta storage meta, ReportStatus storage status, uint256 newAmount2) internal {
        uint256 oldAmount1 = status.currentAmount1;
        uint256 oldAmount2 = status.currentAmount2;
        uint256 fee = (oldAmount2 * meta.feePercentage) / PERCENTAGE_PRECISION;
        uint256 protocolFee = (oldAmount2 * meta.protocolFee) / PERCENTAGE_PRECISION;

        protocolFees[meta.token2] += protocolFee;

        IERC20(meta.token2).safeTransferFrom(msg.sender, address(this), oldAmount2 + fee + protocolFee);
        IERC20(meta.token2).safeTransfer(status.currentReporter, 2 * oldAmount2 + fee);

        uint256 requiredToken1Contribution =
            meta.escalationHalt > oldAmount1 ? (oldAmount1 * meta.multiplier) / MULTIPLIER_PRECISION : oldAmount1;

        uint256 netToken1Contribution =
            requiredToken1Contribution > oldAmount1 ? requiredToken1Contribution - oldAmount1 : 0;

        if (netToken1Contribution > 0) {
            IERC20(meta.token1).safeTransferFrom(msg.sender, address(this), netToken1Contribution);
        }

        IERC20(meta.token2).safeTransferFrom(msg.sender, address(this), newAmount2);
    }

    /**
     * @dev Internal function to handle token transfers
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (from == address(this)) {
            IERC20(token).safeTransfer(to, amount);
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    /**
     * @dev Internal function to send ETH to a recipient
     */
    function _sendEth(address payable recipient, uint256 amount) internal {
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert EthTransferFailed();
    }

    /**
     * @dev Gets the current block number (returns L1 block number for L1 deployment)
     */
    function _getBlockNumber() internal view returns (uint256) {
        uint256 id;
        assembly {
            id := chainid()
        }

        if (
            id == 0xa4b1 // Arbitrum One chain ID
        ) {
            address ARB_SYS_ADDRESS = 0x0000000000000000000000000000000000000064;
            (bool success, bytes memory data) = ARB_SYS_ADDRESS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
            if (!success) revert CallToArbSysFailed();
            return abi.decode(data, (uint256));
        }

        return block.number;
    }
}
