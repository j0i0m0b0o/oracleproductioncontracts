// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOpenOracle {
    // For public state variables, Solidity auto-generates getter functions
    function nextReportId() external view returns (uint256);
    function settle(uint256 reportId) external returns (uint256 price, uint256 settlementTimestamp);
    function reportStatus(uint256 reportId) external view returns (
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
    function reportMeta(uint256 reportId) external view returns (
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

contract AutoBeacon {
    IOpenOracle public immutable oracle;
    bool private _locked;
    
    constructor(address oracleAddress) {
        oracle = IOpenOracle(oracleAddress);
    }
    
    // Check if a report is ready to be settled
    function isSettleable(uint256 reportId) internal view returns (bool) {
        // Skip if report doesn't exist or ID is 0
        if (reportId == 0 || reportId >= oracle.nextReportId()) {
            return false;
        }
        
        (
            ,
            ,
            ,
            ,
            uint256 reportTimestamp,
            ,
            ,
            bool isSettled,
            ,
            bool isDistributed,
            
        ) = oracle.reportStatus(reportId);
        
        // Skip if already settled or distributed
        if (isSettled || isDistributed) {
            return false;
        }
        
        (
            ,
            ,
            ,
            ,
            uint256 settlementTime,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = oracle.reportMeta(reportId);
        
        // Check if settlement time has been reached
        return block.timestamp >= reportTimestamp + settlementTime;
    }
    
    // Completely parameter-free function that automatically finds and settles reports
    function freeMoney() external {
        require(!_locked, "Reentrant call");
        _locked = true;
        
        uint256 startBalance = address(this).balance;
        uint256 nextId = oracle.nextReportId();
        bool settled = false;
        
        // Check the last 3 reports (or fewer if not enough exist)
        uint256 startId = nextId > 3 ? nextId - 3 : 1;
        
        // Try to settle the first available report
        for (uint256 i = nextId - 1; i >= startId; i--) {
            if (isSettleable(i)) {
                oracle.settle(i);
                settled = true;
                break;
            }
            
            // Prevent underflow when i = 0
            if (i == 0) break;
        }
        
        // If we settled something, forward the rewards
        if (settled) {
            uint256 received = address(this).balance - startBalance;
            if (received > 0) {
                (bool success, ) = payable(msg.sender).call{value: received}("");
                require(success, "ETH transfer failed");
            }
        }

        _locked = false;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
