// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOpenOracle} from "./interfaces/IOpenOracle.sol";

/**
 * @title AutoBeacon
 * @notice Automated settlement beacon for OpenOracle reports
 * @dev This contract automatically finds and settles ready reports, earning settlement rewards
 * @author OpenOracle Team
 */
contract AutoBeacon is ReentrancyGuard {
    // Custom errors for gas optimization
    error InvalidReportId();
    error NoSettleableReports();
    error EthTransferFailed();
    error InvalidOracleAddress();

    // Constants
    uint256 public constant MAX_REPORTS_TO_CHECK = 3;

    // State variables
    IOpenOracle public immutable oracle;

    // Events
    event ReportSettled(uint256 indexed reportId, uint256 reward, address settler);

    /**
     * @notice Constructs the AutoBeacon contract
     * @param oracleAddress Address of the OpenOracle contract
     */
    constructor(address oracleAddress) ReentrancyGuard() {
        if (oracleAddress == address(0)) revert InvalidOracleAddress();
        oracle = IOpenOracle(oracleAddress);
    }

    /**
     * @notice Automatically finds and settles available reports, forwarding rewards to caller
     * @dev Checks the most recent reports and settles the first available one
     *      Forwards any ETH rewards received to the caller
     */
    function freeMoney() external nonReentrant {
        uint256 startBalance = address(this).balance;
        uint256 nextId = oracle.nextReportId();
        bool settled = false;
        uint256 settledReportId;

        // Check the last MAX_REPORTS_TO_CHECK reports (or fewer if not enough exist)
        uint256 startId = nextId > MAX_REPORTS_TO_CHECK ? nextId - MAX_REPORTS_TO_CHECK : 1;

        // Try to settle the first available report (newest first)
        for (uint256 i = nextId - 1; i >= startId; i--) {
            if (_isSettleable(i)) {
                oracle.settle(i);
                settled = true;
                settledReportId = i;
                break;
            }

            // Prevent underflow when i = 0
            if (i == 0) break;
        }

        if (!settled) revert NoSettleableReports();

        // Forward any rewards received to the caller
        uint256 received = address(this).balance - startBalance;
        if (received > 0) {
            (bool success,) = payable(msg.sender).call{value: received}("");
            if (!success) revert EthTransferFailed();

            emit ReportSettled(settledReportId, received, msg.sender);
        }
    }

    /**
     * @dev Checks if a report is ready to be settled
     * @param reportId The ID of the report to check
     * @return bool True if the report can be settled
     */
    function _isSettleable(uint256 reportId) internal view returns (bool) {
        // Skip if report doesn't exist or ID is 0
        if (reportId == 0 || reportId >= oracle.nextReportId()) {
            return false;
        }

        (,,,, uint256 reportTimestamp,,, bool isSettled,, bool isDistributed,) = oracle.reportStatus(reportId);

        // Skip if already settled or distributed
        if (isSettled || isDistributed) {
            return false;
        }

        (,,,, uint256 settlementTime,,,,,,,) = oracle.reportMeta(reportId);

        // Check if settlement time has been reached
        return block.timestamp >= reportTimestamp + settlementTime;
    }

    /**
     * @notice Allows the contract to receive ETH rewards
     */
    receive() external payable {}
}
