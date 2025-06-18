// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IOpenOracle
 * @notice Interface for interacting with the OpenOracle contract
 */
interface IOpenOracle {
    /**
     * @notice Gets the next report ID
     * @return The next report ID to be created
     */
    function nextReportId() external view returns (uint256);

    /**
     * @notice Settles a report and returns settlement data
     * @param reportId The ID of the report to settle
     * @return price The settled price
     * @return settlementTimestamp The timestamp when settled
     */
    function settle(uint256 reportId) external returns (uint256 price, uint256 settlementTimestamp);

    /**
     * @notice Gets the status information for a report
     * @param reportId The ID of the report
     * @return currentAmount1 Current amount of token1
     * @return currentAmount2 Current amount of token2
     * @return currentReporter Address of current reporter
     * @return initialReporter Address of initial reporter
     * @return reportTimestamp Timestamp when report was submitted
     * @return settlementTimestamp Timestamp when report was settled
     * @return price The current price
     * @return isSettled Whether the report is settled
     * @return disputeOccurred Whether a dispute occurred
     * @return isDistributed Whether rewards have been distributed
     * @return lastDisputeBlock Block number of last dispute
     */
    function reportStatus(uint256 reportId)
        external
        view
        returns (
            uint256 currentAmount1,
            uint256 currentAmount2,
            address payable currentReporter,
            address payable initialReporter,
            uint256 reportTimestamp,
            uint256 settlementTimestamp,
            uint256 price,
            bool isSettled,
            bool disputeOccurred,
            bool isDistributed,
            uint256 lastDisputeBlock
        );

    /**
     * @notice Gets the metadata for a report
     * @param reportId The ID of the report
     * @return token1 Address of token1
     * @return token2 Address of token2
     * @return feePercentage Fee percentage in basis points
     * @return multiplier Price multiplier for disputes
     * @return settlementTime Time required before settlement
     * @return exactToken1Report Exact amount of token1 required
     * @return fee Settlement fee amount
     * @return escalationHalt Threshold for escalation halt
     * @return disputeDelay Delay before disputes are allowed
     * @return protocolFee Protocol fee percentage
     * @return settlerReward Reward for settling
     * @return requestBlock Block when report was requested
     */
    function reportMeta(uint256 reportId)
        external
        view
        returns (
            address token1,
            address token2,
            uint256 feePercentage,
            uint256 multiplier,
            uint256 settlementTime,
            uint256 exactToken1Report,
            uint256 fee,
            uint256 escalationHalt,
            uint256 disputeDelay,
            uint256 protocolFee,
            uint256 settlerReward,
            uint256 requestBlock
        );
}
