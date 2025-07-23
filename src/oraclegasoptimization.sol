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
    error EthTransferFailed();
    error CallToArbSysFailed();
    error InvalidAmount2(string parameter);
    error InvalidStateHash(string parameter);
    error InvalidGasLimit();

    // Constants
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 public constant PERCENTAGE_PRECISION = 1e7;
    uint256 public constant MULTIPLIER_PRECISION = 100;
    uint256 public constant SETTLEMENT_WINDOW = 60; // 60 seconds for testing
    uint256 public constant SETTLEMENT_WINDOW_BLOCKS = 1350; // 5 minutes @ 4.5 blocks per second on Arbitrum
    uint256 internal constant ARBITRUM_CHAIN_ID = 0xa4b1;
    address internal constant ARB_SYS_ADDRESS = 0x0000000000000000000000000000000000000064;

    // State variables
    uint256 public nextReportId = 1;
    uint256 public accruedProtocolFees;
    address public protocolFeeRecipient;

    mapping(uint256 => ReportMeta) public reportMeta;
    mapping(uint256 => ReportStatus) public reportStatus;
    mapping(address => uint256) public protocolFees;
    mapping(uint256 => extraReportData) public extraData;
    mapping(uint256 => mapping(uint256 => disputeRecord)) public disputeHistory;

    struct disputeRecord{
        uint256 amount1;
        uint256 amount2;
        address tokenToSwap;
        uint48 reportTimestamp;
    }

    struct extraReportData {
        bytes32 stateHash;         
        address creator;           
        uint48 requestTrueTime;    
        uint32 numReports;         
        address callbackContract;  
        uint32 callbackGasLimit;   
        bytes4 callbackSelector;   
        bool trackDisputes;        
        bool keepFee;              
    }

    // Type declarations
    struct ReportMeta {
        uint256 exactToken1Report;   
        uint256 escalationHalt;      
        uint256 fee;                 
        uint256 settlerReward;       
        address token1;              
        uint48 requestBlock;         
        uint48 settlementTime;       
        address token2;              
        bool timeType;               
        uint24 feePercentage;
        uint24 protocolFee;
        uint16 multiplier;           
        uint24 disputeDelay;
    }

    struct ReportStatus {
        uint256 currentAmount1;         
        uint256 currentAmount2;         
        uint256 price;                  
        address payable currentReporter;
        uint48 reportTimestamp;         
        uint48 settlementTimestamp;     
        address payable initialReporter;
        uint48 initialReportTimestamp;  
        uint48 lastReportTrueTime;      
        bool isSettled;                 
        bool disputeOccurred;           
        bool isDistributed;             
    }

    struct CreateReportParams {
        uint256 exactToken1Report;  
        uint256 escalationHalt;     
        uint256 settlerReward;      
        address token1Address;      
        uint48 settlementTime;      
        uint24 disputeDelay;    
        uint24 protocolFee;         
        address token2Address;      
        uint32 callbackGasLimit;    
        uint24 feePercentage;       
        uint16 multiplier;          
        bool timeType;                  
        bool trackDisputes;         
        bool keepFee;               
        address callbackContract;   
        bytes4 callbackSelector;    
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
        uint256 settlerReward,
        bool timeType,
        address callbackContract,
        bytes4 callbackSelector,
        bool trackDisputes,
        uint256 callbackGasLimit,
        bool keepFee, // if initial reporter loses reward when swapped against
        bytes32 stateHash
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
        uint256 escalationHalt,
        bool timeType,
        address callbackContract,
        bytes4 callbackSelector,
        bool trackDisputes,
        uint256 callbackGasLimit,
        bytes32 stateHash
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
        uint256 escalationHalt,
        bool timeType,
        address callbackContract,
        bytes4 callbackSelector,
        bool trackDisputes,
        uint256 callbackGasLimit,
        bytes32 stateHash
    );

    event ReportSettled(uint256 indexed reportId, uint256 price, uint256 settlementTimestamp);

    event ProtocolFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    event SettlementCallbackExecuted(uint256 indexed reportId, address indexed callbackContract, bool success);

    constructor() ReentrancyGuard() Ownable(msg.sender) {
        protocolFeeRecipient = 0x043c740dB5d907aa7604c2E8E9E0fffF435fa0e4;
    }

    /**
     * @notice Updates the protocol fee recipient address
     * @param newRecipient The new protocol fee recipient address
     */
    function updateProtocolFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidInput("recipient address");
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

    function getETHProtocolFees() external nonReentrant {
        uint256 amount = accruedProtocolFees;
        if (amount > 0) {
            accruedProtocolFees = 0;
            (bool success, ) = protocolFeeRecipient.call{value: amount}("");
            if (!success) revert EthTransferFailed();
        }
    }

    /**
     * @notice Settles a report after the settlement time has elapsed
     * @param reportId The unique identifier for the report to settle
     * @return price The final settled price
     * @return settlementTimestamp The timestamp when the report was settled
     */
    function settle(uint256 reportId) external nonReentrant returns (uint256 price, uint256 settlementTimestamp) {
        // moved this back above reverts because we read the storage variable in the if statement anyway
        ReportStatus storage status = reportStatus[reportId];
        ReportMeta storage meta = reportMeta[reportId];

        if (meta.timeType) {
            if (block.timestamp < status.reportTimestamp + meta.settlementTime) {
                revert InvalidTiming("settlement");
            }
        } else {
            if (_getBlockNumber() < status.reportTimestamp + meta.settlementTime) {
                revert InvalidTiming("settlement");
            }
        }

        if (status.isSettled || status.isDistributed) {
            return status.isSettled ? (status.price, status.settlementTimestamp) : (0, 0);
        }

        uint256 settlerReward = meta.settlerReward;
        uint256 reporterReward = meta.fee;
        bool isWithinWindow;

        if (meta.timeType) {
            isWithinWindow = block.timestamp <= status.reportTimestamp + meta.settlementTime + SETTLEMENT_WINDOW;
        } else {
            isWithinWindow = _getBlockNumber() <= status.reportTimestamp + meta.settlementTime + SETTLEMENT_WINDOW_BLOCKS;
        }

        if (isWithinWindow) {
            status.isSettled = true;
            status.settlementTimestamp = meta.timeType ? uint48(block.timestamp) : _getBlockNumber();
            emit ReportSettled(reportId, status.price, status.settlementTimestamp);
        }

        // this is moved above all external calls (Check effect interaction pattern)
        status.isDistributed = true;

        extraReportData storage extra = extraData[reportId];

        if (extra.callbackContract != address(0) && extra.callbackSelector != bytes4(0)) {
            // Prepare callback data
            bytes memory callbackData = abi.encodeWithSelector(
                extra.callbackSelector,
                reportId,
                status.price,
                status.settlementTimestamp,
                meta.token1,
                meta.token2
            );
            
            // Execute callback with gas limit. Revert if not enough gas supplied to attempt callback fully.
            // Using low-level call to handle failures gracefully
            if (gasleft() < ((64 * extra.callbackGasLimit + 62) / 63) + 100000) revert InvalidGasLimit();
            (bool success, ) = extra.callbackContract.call{gas: extra.callbackGasLimit}(callbackData);
            
            // Emit event regardless of bool success
            emit SettlementCallbackExecuted(reportId, extra.callbackContract, success);
        }

        // other external calls moved below (check-effect-interaction pattern)

        if (status.disputeOccurred) {
            if (extraData[reportId].keepFee){
                _sendEth(status.initialReporter, reporterReward); 
            }else{
                accruedProtocolFees += reporterReward;
            }
        } else {
            _sendEth(status.initialReporter, reporterReward);
        }
        
        _transferTokens(meta.token1, address(this), status.currentReporter, status.currentAmount1);
        _transferTokens(meta.token2, address(this), status.currentReporter, status.currentAmount2);
        
        _sendEth(payable(msg.sender), settlerReward);

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
     * @notice Creates a new report instance for price discovery. Backwards-compatible (timeType true)
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
        uint24 feePercentage,
        uint16 multiplier,
        uint48 settlementTime,
        uint256 escalationHalt,
        uint24 disputeDelay,
        uint24 protocolFee,
        uint256 settlerReward
    ) external payable returns (uint256 reportId) {
        CreateReportParams memory params = CreateReportParams({
            token1Address: token1Address,
            token2Address: token2Address,
            exactToken1Report: exactToken1Report,
            feePercentage: feePercentage,
            multiplier: multiplier,
            settlementTime: settlementTime,
            escalationHalt: escalationHalt,
            disputeDelay: disputeDelay,
            protocolFee: protocolFee,
            settlerReward: settlerReward,
            timeType: true,
            callbackContract: address(0),
            callbackSelector: bytes4(0),
            trackDisputes: false,
            callbackGasLimit: 0,
            keepFee: false
        });
        return _createReportInstance(params);
    }

    //new function. full control over timeType. true = seconds, false = blocks
    // not backwards compatible to previous createReportInstance (different function argument order!!)
    function createReportInstance(
        CreateReportParams calldata params
    ) external payable returns (uint256 reportId) {
        return _createReportInstance(params);
    }

    function _createReportInstance(
        CreateReportParams memory params
    ) internal returns (uint256 reportId) {
        if (msg.value <= 100) revert InsufficientAmount("fee");
        if (params.exactToken1Report == 0) revert InvalidInput("token amount");
        if (params.token1Address == params.token2Address) revert TokensCannotBeSame();
        if (params.settlementTime < params.disputeDelay) revert InvalidTiming("settlement vs dispute delay");
        if (msg.value <= params.settlerReward) revert InsufficientAmount("settler reward fee");

        reportId = nextReportId++;

        ReportMeta storage meta = reportMeta[reportId];
        meta.token1 = params.token1Address;
        meta.token2 = params.token2Address;
        meta.exactToken1Report = params.exactToken1Report;
        meta.feePercentage = params.feePercentage;
        meta.multiplier = params.multiplier;
        meta.settlementTime = params.settlementTime;
        meta.fee = msg.value - params.settlerReward;
        meta.escalationHalt = params.escalationHalt;
        meta.disputeDelay = params.disputeDelay;
        meta.protocolFee = params.protocolFee;
        meta.settlerReward = params.settlerReward;
        meta.requestBlock = _getBlockNumber();
        meta.timeType = params.timeType;

        // cache storage variable to avoid multiple storage reads
        extraReportData storage extra = extraData[reportId];
        extra.creator = msg.sender;
        extra.requestTrueTime = uint48(block.timestamp);
        extra.callbackContract = params.callbackContract;
        extra.callbackSelector = params.callbackSelector;
        extra.trackDisputes = params.trackDisputes;
        extra.callbackGasLimit = params.callbackGasLimit;
        extra.keepFee = params.keepFee;

        bytes32 stateHash = keccak256(abi.encodePacked(
            keccak256(abi.encodePacked(params.timeType)),
            keccak256(abi.encodePacked(params.settlementTime)),
            keccak256(abi.encodePacked(params.disputeDelay)),
            keccak256(abi.encodePacked(params.callbackContract)),
            keccak256(abi.encodePacked(params.callbackSelector)),
            keccak256(abi.encodePacked(params.callbackGasLimit)),
            keccak256(abi.encodePacked(params.keepFee)),
            keccak256(abi.encodePacked(params.feePercentage)),
            keccak256(abi.encodePacked(params.protocolFee)),
            keccak256(abi.encodePacked(params.settlerReward)),
            keccak256(abi.encodePacked(meta.fee)),
            keccak256(abi.encodePacked(params.trackDisputes)),
            keccak256(abi.encodePacked(msg.sender))
        ));

        extra.stateHash = stateHash;
        
        emit ReportInstanceCreated(
            reportId,
            params.token1Address,
            params.token2Address,
            params.feePercentage,
            params.multiplier,
            params.exactToken1Report,
            msg.value,
            msg.sender,
            params.settlementTime,
            params.escalationHalt,
            params.disputeDelay,
            params.protocolFee,
            params.settlerReward,
            params.timeType,
            params.callbackContract,
            params.callbackSelector,
            params.trackDisputes,
            params.callbackGasLimit,
            params.keepFee,
            stateHash
        );
        return reportId;
    }

    /**
     * @notice Submits the initial price report for a given report ID
     * @param reportId The unique identifier for the report
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Amount of token2 for the price ratio
     * @dev Tokens are pulled from msg.sender and will be returned to msg.sender when settled
     */
    function submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash) external {
        _submitInitialReport(reportId, amount1, amount2, stateHash, msg.sender);
    }

    /**
     * @notice Submits the initial price report with a custom reporter address
     * @param reportId The unique identifier for the report
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Amount of token2 for the price ratio
     * @param reporter The address that will receive tokens back when settled
     * @dev Tokens are pulled from msg.sender but will be returned to reporter address
     * @dev This overload enables contracts to submit reports on behalf of users
     */
    function submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash, address reporter) external {
        _submitInitialReport(reportId, amount1, amount2, stateHash, reporter);
    }

    /**
     * @notice Submits the initial price report for a given report ID
     * @param reportId The unique identifier for the report
     * @param amount1 Amount of token1 (must equal exactToken1Report)
     * @param amount2 Amount of token2 for the price ratio
     * @param reporter The address that will receive tokens back when settled
     */
    function _submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2, bytes32 stateHash, address reporter) internal {

        if (reportStatus[reportId].currentReporter != address(0)) revert AlreadyProcessed("report submitted");

        ReportMeta storage meta = reportMeta[reportId];
        ReportStatus storage status = reportStatus[reportId];
        extraReportData storage extra = extraData[reportId];

        if (reportId > nextReportId) revert InvalidInput("report id");
        if (amount1 != meta.exactToken1Report) revert InvalidInput("token1 amount");
        if (amount2 == 0) revert InvalidInput("token2 amount");
        if (extra.stateHash != stateHash) revert InvalidStateHash("state hash");

        _transferTokens(meta.token1, msg.sender, address(this), amount1);
        _transferTokens(meta.token2, msg.sender, address(this), amount2);

        status.currentAmount1 = amount1;
        status.currentAmount2 = amount2;
        status.currentReporter = payable(reporter);
        status.initialReporter = payable(reporter);
        status.reportTimestamp = meta.timeType ? uint48(block.timestamp) : _getBlockNumber();
        status.initialReportTimestamp = status.reportTimestamp;
        status.price = (amount1 * PRICE_PRECISION) / amount2;
        status.lastReportTrueTime = uint48(block.timestamp);

        if (extra.trackDisputes) {
            disputeHistory[reportId][0].amount1 = amount1;
            disputeHistory[reportId][0].amount2 = amount2;
            disputeHistory[reportId][0].reportTimestamp = status.reportTimestamp;
            extra.numReports = 1;
        }

        emit InitialReportSubmitted(
            reportId,
            reporter,
            amount1,
            amount2,
            meta.token1,
            meta.token2,
            meta.feePercentage,
            meta.protocolFee,
            meta.settlementTime,
            meta.disputeDelay,
            meta.escalationHalt,
            meta.timeType,
            extra.callbackContract,
            extra.callbackSelector,
            extra.trackDisputes,
            extra.callbackGasLimit,
            stateHash
        );
    }

//backwards-compatible function
function disputeAndSwap(uint256 reportId, address tokenToSwap, uint256 newAmount1, uint256 newAmount2, uint256 amt2Expected, bytes32 stateHash)
    external
    nonReentrant
{
    _disputeAndSwap(reportId, tokenToSwap, newAmount1, newAmount2, msg.sender, amt2Expected, stateHash);
}

//new function. disputer address receives the money back, so you can call dispute with your own tokens through insurance smart contracts or other smart contracts if necessary.
function disputeAndSwap(uint256 reportId, address tokenToSwap, uint256 newAmount1, uint256 newAmount2, address disputer, uint256 amt2Expected, bytes32 stateHash)
    external
    nonReentrant
{
    _disputeAndSwap(reportId, tokenToSwap, newAmount1, newAmount2, disputer, amt2Expected, stateHash);
}

    /**
     * @notice Disputes an existing report and swaps tokens to update the price
     * @param reportId The unique identifier for the report to dispute
     * @param tokenToSwap The token being swapped (token1 or token2)
     * @param newAmount1 New amount of token1 after the dispute
     * @param newAmount2 New amount of token2 after the dispute
     */
    function _disputeAndSwap(uint256 reportId, address tokenToSwap, uint256 newAmount1, uint256 newAmount2, address disputer, uint256 amt2Expected, bytes32 stateHash)
        internal
    {
        _preValidate(newAmount1, reportStatus[reportId].currentAmount1, reportMeta[reportId].multiplier, reportMeta[reportId].escalationHalt);
        
        ReportMeta storage meta = reportMeta[reportId];
        ReportStatus storage status = reportStatus[reportId];

        _validateDispute(reportId, tokenToSwap, newAmount1, newAmount2, meta, status);
        if (status.currentAmount2 != amt2Expected) revert InvalidAmount2("amount2 doesn't match expectation");
        if (stateHash != extraData[reportId].stateHash) revert InvalidStateHash("state hash");

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
        status.currentReporter = payable(disputer);
        status.reportTimestamp = meta.timeType ? uint48(block.timestamp) : _getBlockNumber();
        status.price = (newAmount1 * PRICE_PRECISION) / newAmount2;
        status.disputeOccurred = true;
        status.lastReportTrueTime = uint48(block.timestamp);

        if (extraData[reportId].trackDisputes) {
            uint32 nextIndex = extraData[reportId].numReports;
            disputeHistory[reportId][nextIndex].amount1 = newAmount1;
            disputeHistory[reportId][nextIndex].amount2 = newAmount2;
            disputeHistory[reportId][nextIndex].reportTimestamp = status.reportTimestamp;
            disputeHistory[reportId][nextIndex].tokenToSwap = tokenToSwap;
            extraData[reportId].numReports = nextIndex + 1;
        }

        emit ReportDisputed(
            reportId,
            disputer,
            newAmount1,
            newAmount2,
            meta.token1,
            meta.token2,
            meta.feePercentage,
            meta.protocolFee,
            meta.settlementTime,
            meta.disputeDelay,
            meta.escalationHalt,
            meta.timeType,
            extraData[reportId].callbackContract,
            extraData[reportId].callbackSelector,
            extraData[reportId].trackDisputes,
            extraData[reportId].callbackGasLimit,
            stateHash
        );
    }

    function _preValidate(uint256 newAmount1, uint256 oldAmount1, uint256 multiplier, uint256 escalationHalt) internal pure {

        uint256 expectedAmount1;

        if (escalationHalt > oldAmount1) {
            expectedAmount1 = (oldAmount1 * multiplier) / MULTIPLIER_PRECISION;
        } else {
            expectedAmount1 = oldAmount1 + 1;
        }

        if (newAmount1 != expectedAmount1) {
            if (escalationHalt <= oldAmount1) {
                revert OutOfBounds("escalation halted");
            } else {
                revert InvalidInput("new amount");
            }
        }
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
        if (meta.timeType) {
            if (block.timestamp > status.reportTimestamp + meta.settlementTime) {
                revert InvalidTiming("dispute period expired");
            }
        } else {
            if (_getBlockNumber() > status.reportTimestamp + meta.settlementTime) {
                revert InvalidTiming("dispute period expired");
            }
        }
        if (status.isSettled) revert AlreadyProcessed("report settled");
        if (status.isDistributed) revert AlreadyProcessed("report distributed");
        if (tokenToSwap != meta.token1 && tokenToSwap != meta.token2) revert InvalidInput("token to swap");
        if(meta.timeType == true){
            if (block.timestamp < status.reportTimestamp + meta.disputeDelay) revert InvalidTiming("dispute too early");
        } else {
            if (_getBlockNumber() < status.reportTimestamp + meta.disputeDelay) revert InvalidTiming("dispute too early");
        }

        uint256 oldAmount1 = status.currentAmount1;
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

        uint256 requiredToken1Contribution =
            meta.escalationHalt > oldAmount1 ? (oldAmount1 * meta.multiplier) / MULTIPLIER_PRECISION : oldAmount1 + 1;

        uint256 netToken2Contribution = newAmount2 >= oldAmount2 ? newAmount2 - oldAmount2 : 0;
        uint256 netToken2Receive = newAmount2 < oldAmount2 ? oldAmount2 - newAmount2 : 0;

        if (netToken2Contribution > 0) {
            IERC20(meta.token2).safeTransferFrom(msg.sender, address(this), netToken2Contribution); 
        }

        if (netToken2Receive > 0) {
            IERC20(meta.token2).safeTransfer(msg.sender, netToken2Receive);
        }

        IERC20(meta.token1).safeTransferFrom(msg.sender, address(this), requiredToken1Contribution + oldAmount1 + fee + protocolFee);
        IERC20(meta.token1).safeTransfer(status.currentReporter, 2 * oldAmount1 + fee);
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

        uint256 requiredToken1Contribution =
            meta.escalationHalt > oldAmount1 ? (oldAmount1 * meta.multiplier) / MULTIPLIER_PRECISION : oldAmount1 +1;

        uint256 netToken1Contribution =
            requiredToken1Contribution > (oldAmount1) ? requiredToken1Contribution - (oldAmount1) : 0;

        if (netToken1Contribution > 0) {
            IERC20(meta.token1).safeTransferFrom(msg.sender, address(this), netToken1Contribution);
        }

        IERC20(meta.token2).safeTransferFrom(msg.sender, address(this), newAmount2 + oldAmount2 + fee + protocolFee);
        IERC20(meta.token2).safeTransfer(status.currentReporter, 2 * oldAmount2 + fee);
    }

    /**
     * @dev Internal function to handle token transfers
     */
    function _transferTokens(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization: skip zero transfers

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
        if (amount == 0) return; // Gas optimization: skip zero transfers

        (bool success,) = recipient.call{value: amount}("");
        if (!success){
            (bool success2,) = payable(address(0)).call{value: amount}("");
            if(!success2){
                //do nothing so at least erc20 can move
            }
        }
    }

    /**
     * @dev Gets the current block number (returns L1 block number for L1 deployment)
     */
    function _getBlockNumber() internal view returns (uint48) {
        uint256 id;
        assembly {
            id := chainid()
        }

        if (id == ARBITRUM_CHAIN_ID) {
            (bool success, bytes memory data) = ARB_SYS_ADDRESS.staticcall(abi.encodeWithSignature("arbBlockNumber()"));
            if (!success) revert CallToArbSysFailed();
            return uint48(abi.decode(data, (uint256)));
        }

        return uint48(block.number);
    }
}