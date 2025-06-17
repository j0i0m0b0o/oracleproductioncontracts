// SPDX-License-Identifier: MIT
// openOracle is an attempt at a trust-free price oracle that uses an escalating auction.
// This contract is for researching if the economic incentives in the design work.
// With appropriate oracle parameters, expiration is evidence of a good price.
// https://openprices.gitbook.io/openoracle-docs
// v0.1.6

pragma solidity ^0.8.26;
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
using SafeERC20 for IERC20;

contract openOracle is ReentrancyGuard {

    constructor() ReentrancyGuard() {
        //
    }

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
        uint256 price; // price scaled by 1e18
        bool isSettled;
        bool disputeOccurred;

        bool isDistributed;
        uint256 lastDisputeBlock; // Added to track block of last dispute

    }

    uint256 public nextReportId = 1;
//    address constant arbSysAddress = 0x0000000000000000000000000000000000000064;

    mapping(uint256 => ReportMeta) public reportMeta;
    mapping(uint256 => ReportStatus) public reportStatus;

    mapping(address => uint256) public protocolFees;

    event ReportInstanceCreated(uint256 indexed reportId, address indexed token1Address, address indexed token2Address, uint256 feePercentage, uint256 multiplier, uint256 exactToken1Report, uint256 ethFee, address creator, uint256 settlementTime, uint256 escalationHalt, uint256 disputeDelay, uint256 protocolFee, uint256 settlerReward);
    event InitialReportSubmitted(uint256 indexed reportId, address reporter, uint256 amount1, uint256 amount2, address indexed token1Address, address indexed token2Address, uint256 swapFee, uint256 protocolFee, uint256 settlementTime, uint256 disputeDelay, uint256 escalationHalt);
    event ReportDisputed(uint256 indexed reportId, address disputer, uint256 newAmount1, uint256 newAmount2, address indexed token1Address, address indexed token2Address, uint256 swapFee, uint256 protocolFee, uint256 settlementTime, uint256 disputeDelay, uint256 escalationHalt);
    event ReportSettled(uint256 indexed reportId, uint256 price, uint256 settlementTimestamp);

    function createReportInstance(
        address token1Address,
        address token2Address,
        uint256 exactToken1Report,
        uint256 feePercentage, // in thousandths of a basis point i.e. 3000 means 3bps.
        uint256 multiplier, //in percentage points i.e. 110 means multiplier of 1.1x
        uint256 settlementTime,
        uint256 escalationHalt, // when exactToken1Report passes this, the multiplier drops to 100 after
        uint256 disputeDelay, // seconds, increase free option cost for self dispute games
        uint256 protocolFee, //in thousandths of a basis point
        uint256 settlerReward // in wei
    ) external payable returns (uint256 reportId) {
        require(msg.value > 100, "Fee must be greater than 100 wei");
        require(exactToken1Report > 0, "exactToken1Report must be greater than zero");
        require(token1Address != token2Address, "Tokens must be different");
        require(settlementTime > disputeDelay);
        require(msg.value > settlerReward);

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

        emit ReportInstanceCreated(reportId, token1Address, token2Address, feePercentage, multiplier, exactToken1Report, msg.value, msg.sender, settlementTime, escalationHalt, disputeDelay, protocolFee, settlerReward);

    }

    function submitInitialReport(uint256 reportId, uint256 amount1, uint256 amount2) external nonReentrant {
        ReportMeta storage meta = reportMeta[reportId];
        ReportStatus storage status = reportStatus[reportId];

        require(reportId <= nextReportId);
        require(status.currentReporter == address(0), "Report already submitted");
        require(amount1 == meta.exactToken1Report, "Amount1 equals exact amount");
        require(amount2 > 0);

        _transferTokens(meta.token1, msg.sender, address(this), amount1);
        _transferTokens(meta.token2, msg.sender, address(this), amount2);

        status.currentAmount1 = amount1;
        status.currentAmount2 = amount2;
        status.currentReporter = payable(msg.sender);
        status.initialReporter = payable(msg.sender);
        status.reportTimestamp = block.timestamp;
        status.price = (amount1 * 1e18) / amount2;

        emit InitialReportSubmitted(reportId, msg.sender, amount1, amount2, meta.token1, meta.token2, meta.feePercentage, meta.protocolFee, meta.settlementTime, meta.disputeDelay, meta.escalationHalt);
    }

function disputeAndSwap(uint256 reportId, address tokenToSwap, uint256 newAmount1, uint256 newAmount2) external nonReentrant {
    ReportMeta storage meta = reportMeta[reportId];
    ReportStatus storage status = reportStatus[reportId];

    _validateDispute(reportId, tokenToSwap, newAmount1, newAmount2, meta, status);

    if (tokenToSwap == meta.token1) {
        _handleToken1Swap(meta, status, newAmount2);
    } else if (tokenToSwap == meta.token2) {
        _handleToken2Swap(meta, status, newAmount2);
    } else {
        revert("Invalid tokenToSwap");
    }

    // Update the report status after the dispute and swap
    status.currentAmount1 = newAmount1;
    status.currentAmount2 = newAmount2;
    status.currentReporter = payable(msg.sender);
    status.reportTimestamp = block.timestamp;
    status.price = (newAmount1 * 1e18) / newAmount2;
    status.disputeOccurred = true;

    // Set the last dispute block to prevent multiple disputes in one block
    status.lastDisputeBlock = getL2BlockNumber();
    
    emit ReportDisputed(reportId, msg.sender, newAmount1, newAmount2, meta.token1, meta.token2, meta.feePercentage, meta.protocolFee, meta.settlementTime, meta.disputeDelay, meta.escalationHalt);
}

function _validateDispute(
    uint256 reportId,
    address tokenToSwap,
    uint256 newAmount1,
    uint256 newAmount2,
    ReportMeta storage meta,
    ReportStatus storage status
) internal view {
    require(reportId <= nextReportId);
    require(newAmount1 > 0 && newAmount2 > 0);
    require(status.currentReporter != address(0), "No report to dispute");
    require(block.timestamp <= status.reportTimestamp + meta.settlementTime, "Dispute period over");
    require(!status.isSettled, "Report already settled");
    require(!status.isDistributed, "Report is already distributed");
    require(tokenToSwap == meta.token1 || tokenToSwap == meta.token2, "Invalid token to swap");

    require(status.lastDisputeBlock != getL2BlockNumber(), "Dispute already occurred in this block");
    require(block.timestamp >= status.reportTimestamp + meta.disputeDelay, "Dispute too early");

    uint256 oldAmount1 = status.currentAmount1;

    if(meta.escalationHalt > oldAmount1){
    require(newAmount1 == (oldAmount1 * meta.multiplier) / 100, "Invalid newAmount1: does not match multiplier on old amount");
    }else{
    require(newAmount1 == oldAmount1, "Invalid newAmount1: does not match old amount. Escalation halted.");
    }

    uint256 oldPrice = (oldAmount1 * 1e18) / status.currentAmount2;
    uint256 feeBoundary = (oldPrice * meta.feePercentage) / 1e7;
    uint256 lowerBoundary = oldPrice > feeBoundary ? oldPrice - feeBoundary : 0;
    uint256 upperBoundary = oldPrice + feeBoundary;
    uint256 newPrice = (newAmount1 * 1e18) / newAmount2;
    require(newPrice < lowerBoundary || newPrice > upperBoundary, "New price not outside fee boundaries");
}

function _handleToken1Swap(
    ReportMeta storage meta,
    ReportStatus storage status,
    uint256 newAmount2
) internal {
    uint256 oldAmount1 = status.currentAmount1;
    uint256 oldAmount2 = status.currentAmount2;
    uint256 fee = (oldAmount1 * meta.feePercentage) / 1e7;
    
    uint256 protocolFee = (oldAmount1 * meta.protocolFee) / 1e7;
    protocolFees[meta.token1] += protocolFee;

    IERC20(meta.token1).safeTransferFrom(msg.sender, address(this), oldAmount1 + fee + protocolFee);
    IERC20(meta.token1).safeTransfer(status.currentReporter, 2 * oldAmount1 + fee);

    uint256 requiredToken1Contribution;
    if(meta.escalationHalt > oldAmount1){
        requiredToken1Contribution = (oldAmount1 * meta.multiplier) / 100;
    }else{
        requiredToken1Contribution = oldAmount1;
    }

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

function _handleToken2Swap(
    ReportMeta storage meta,
    ReportStatus storage status,
    uint256 newAmount2
) internal {
    uint256 oldAmount1 = status.currentAmount1;
    uint256 oldAmount2 = status.currentAmount2;
    uint256 fee = (oldAmount2 * meta.feePercentage) / 1e7;

    uint256 protocolFee = (oldAmount2 * meta.protocolFee) / 1e7;
    protocolFees[meta.token2] += protocolFee;

    IERC20(meta.token2).safeTransferFrom(msg.sender, address(this), oldAmount2 + fee + protocolFee);
    IERC20(meta.token2).safeTransfer(status.currentReporter, 2 * oldAmount2 + fee);

    uint256 requiredToken1Contribution;
    if(meta.escalationHalt > oldAmount1){
        requiredToken1Contribution = (oldAmount1 * meta.multiplier) / 100;
    }else{
        requiredToken1Contribution = oldAmount1;
    }

    uint256 netToken1Contribution = requiredToken1Contribution > oldAmount1 ? requiredToken1Contribution - oldAmount1 : 0;

    if (netToken1Contribution > 0) {
        IERC20(meta.token1).safeTransferFrom(msg.sender, address(this), netToken1Contribution);
    }

    IERC20(meta.token2).safeTransferFrom(msg.sender, address(this), newAmount2);
}

function settle(uint256 reportId)
    external
    nonReentrant
    returns (uint256 price, uint256 settlementTimestamp)
{
    ReportStatus storage status = reportStatus[reportId];
    ReportMeta storage meta = reportMeta[reportId];

    uint256 settlerReward = meta.settlerReward;
    uint256 reporterReward = meta.fee;

    if (!status.isSettled && !status.isDistributed) {
        // Settlement time window checks
        require(
            block.timestamp >= status.reportTimestamp + meta.settlementTime,
            "Settlement time not reached"
        );

        //60 for testing, should normally be 4
        if (block.timestamp <= status.reportTimestamp + meta.settlementTime + 60) {
            // Settlement window is still open, modify state
            status.isSettled = true;
            status.settlementTimestamp = block.timestamp;

            if (!status.disputeOccurred) {
                _sendEth(status.initialReporter, reporterReward);
            }else if (status.disputeOccurred){
                _sendEth(payable(0x043c740dB5d907aa7604c2E8E9E0fffF435fa0e4), reporterReward);
            }
            _sendEth(payable(msg.sender), settlerReward);

            _transferTokens(meta.token1, address(this), status.currentReporter, status.currentAmount1);

            _transferTokens(meta.token2, address(this), status.currentReporter, status.currentAmount2);

            status.isDistributed = true;
            emit ReportSettled(reportId, status.price, status.settlementTimestamp);
        } else if (!status.isDistributed){

            _sendEth(payable(msg.sender), settlerReward);

            if (!status.disputeOccurred) {
                _sendEth(status.initialReporter, reporterReward);
            }else if (status.disputeOccurred){
                _sendEth(payable(0x043c740dB5d907aa7604c2E8E9E0fffF435fa0e4), reporterReward);
            }

            _transferTokens(meta.token1, address(this), status.currentReporter, status.currentAmount1);

            _transferTokens(meta.token2, address(this), status.currentReporter, status.currentAmount2);

            status.isDistributed = true;

        }

    }

    // Return the current price and settlement timestamp, if settled
    if (status.isSettled) {
    price = status.price;
    settlementTimestamp = status.settlementTimestamp;
    return (price, settlementTimestamp);
    }else{
        return (0,0);
    }


}

//getter function for users of the oracle
function getSettlementData(uint256 reportId) external view returns (uint256 price, uint256 settlementTimestamp) {
    ReportStatus storage status = reportStatus[reportId];
    require(status.isSettled, "Report not settled yet");
    return (status.price, status.settlementTimestamp);
}

function _transferTokens(address token, address from, address to, uint256 amount) internal {
    if (from == address(this)) {
        // Use safeTransfer when transferring tokens held by the contract
        IERC20(token).safeTransfer(to, amount);
    } else {
        // Use safeTransferFrom when transferring tokens from another address
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}

    function _sendEth(address payable recipient, uint256 amount) internal {
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Failed to send Ether");
    }

    //changed for L1
    function getL2BlockNumber() internal view returns (uint256) {
    //    (bool success, bytes memory data) = arbSysAddress.staticcall(
    //        abi.encodeWithSignature("arbBlockNumber()")
    //    );
    //    require(success, "Call to ArbSys failed");
    //    return abi.decode(data, (uint256));
            return block.number;
    }

    function getProtocolFees(address tokenToGet) external nonReentrant {
        uint256 amount = protocolFees[tokenToGet];
        _transferTokens(tokenToGet, address(this), payable(0x043c740dB5d907aa7604c2E8E9E0fffF435fa0e4), amount);
        protocolFees[tokenToGet] = 0;
    }

}
