// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {OpenOracle} from "../src/OpenOracleL1.sol";

import {MockERC20} from "./MockERC20.sol";

contract OracleTest is Test {
    OpenOracle public oracle;

    MockERC20 public usdt;
    MockERC20 public weth;

    address public constant INITIAL_FEE_RECIPIENT = 0x043c740dB5d907aa7604c2E8E9E0fffF435fa0e4;
    address public constant NEW_FEE_RECIPIENT = 0x1234567890123456789012345678901234567890;

    function setUp() public {
        oracle = new OpenOracle();

        usdt = new MockERC20("USDT", "USDT");
        weth = new MockERC20("Wrapped Ether", "WETH");

        // mint tokens
        usdt.mint(address(this), 1000_000e18);
        weth.mint(address(this), 100e18);

        // approve openOracle to spend tokens
        usdt.approve(address(oracle), 1000_000e18);
        weth.approve(address(oracle), 100e18);
    }

    function testSettlePrice() public {
        // create a report instance: weth, usdt, 1 eth, feepercentage 400, multiplier 110, settlementTime 60s
        // Need to include all parameters: escalationHalt, disputeDelay, protocolFee, settlerReward
        uint256 reportId = oracle.createReportInstance{value: 0.001 ether}(
            address(weth),
            address(usdt),
            1 ether,
            400,
            110,
            60,
            10 ether, // escalationHalt
            5, // disputeDelay
            100, // protocolFee
            0.0001 ether // settlerReward
        );

        // submit initial report: 1 eth = 3000 usdt
        oracle.submitInitialReport(reportId, 1 ether, 3000e18);

        // fast forward settlementTime + 1s
        skip(61);

        // settle price
        oracle.settle(reportId);
    }

    function testGetBlockNumber() public {
        // Test _getBlockNumber on current chain (should return block.number)
        // We can't directly test the internal function, but we can test its behavior
        // by creating a report and checking the requestBlock field
        uint256 currentBlock = block.number;
        
        uint256 reportId = oracle.createReportInstance{value: 0.001 ether}(
            address(weth),
            address(usdt),
            1 ether,
            400,
            110,
            60,
            10 ether,
            5,
            100,
            0.0001 ether
        );

        (,,,,,,,,,,, uint256 requestBlock) = oracle.reportMeta(reportId);
        assertEq(requestBlock, currentBlock);
    }

    function testOwnerCanChangeFeeRecipient() public {
        // Test initial fee recipient
        assertEq(oracle.protocolFeeRecipient(), INITIAL_FEE_RECIPIENT);

        // Test updating fee recipient
        vm.expectEmit(true, true, false, true);
        emit ProtocolFeeRecipientUpdated(INITIAL_FEE_RECIPIENT, NEW_FEE_RECIPIENT);
        
        oracle.updateProtocolFeeRecipient(NEW_FEE_RECIPIENT);
        assertEq(oracle.protocolFeeRecipient(), NEW_FEE_RECIPIENT);
    }

    function testOnlyOwnerCanChangeFeeRecipient() public {
        // Test non-owner cannot change fee recipient
        vm.prank(address(0x123));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x123)));
        oracle.updateProtocolFeeRecipient(NEW_FEE_RECIPIENT);
    }

    function testCannotSetZeroFeeRecipient() public {
        vm.expectRevert("Invalid recipient address");
        oracle.updateProtocolFeeRecipient(address(0));
    }

    function testSettlementWithinWindow() public {
        uint256 reportId = _createAndSubmitReport();

        // Fast forward to exactly settlement time
        skip(60);

        uint256 balanceBefore = address(this).balance;
        (uint256 price, uint256 settlementTimestamp) = oracle.settle(reportId);

        // Check that settlement was successful
        assertTrue(price > 0);
        assertTrue(settlementTimestamp > 0);
        
        // Check settler reward was paid
        assertGt(address(this).balance, balanceBefore);
        
        // Check report is marked as settled
        (,,,,,, uint256 reportPrice,, bool isSettled,,,) = oracle.reportStatus(reportId);
        assertTrue(isSettled);
        assertEq(reportPrice, price);
    }

    function testSettlementAfterWindow() public {
        uint256 reportId = _createAndSubmitReport();

        // Fast forward past settlement window
        skip(121); // 60 + 60 + 1

        uint256 balanceBefore = address(this).balance;
        (uint256 price, uint256 settlementTimestamp) = oracle.settle(reportId);

        // Settlement should still work but report shouldn't be marked as settled
        // The function returns (0, 0) since isSettled is false
        assertEq(price, 0);
        assertEq(settlementTimestamp, 0);
        
        // Check settler reward was still paid
        assertGt(address(this).balance, balanceBefore);
        
        // Check report is not marked as settled
        (,,,,,, uint256 reportPrice,, bool isSettled,,,) = oracle.reportStatus(reportId);
        assertFalse(isSettled);
        // The price is still stored from the initial report, but the report is not marked as settled
        assertGt(reportPrice, 0);
    }

    function testCannotSettleBeforeTime() public {
        uint256 reportId = _createAndSubmitReport();

        // Try to settle before settlement time
        skip(59);

        vm.expectRevert(abi.encodeWithSignature("InvalidTiming(string)", "settlement"));
        oracle.settle(reportId);
    }

    function testDisputeToken1Swap() public {
        uint256 reportId = _createAndSubmitReport();

        // Fast forward past dispute delay
        skip(10);

        // Prepare for dispute
        uint256 newAmount1 = (1 ether * 110) / 100; // 1.1 ETH (multiplier applied)
        uint256 newAmount2 = 2000e18; // Significantly different price to trigger dispute (higher price per token)

        // Calculate required tokens for dispute - when swapping token1
        uint256 oldAmount1 = 1 ether;
        uint256 oldAmount2 = 3000e18;
        uint256 fee = (oldAmount1 * 400) / 10000000;
        uint256 protocolFee = (oldAmount1 * 100) / 10000000;
        
        // For token1 swap: need oldAmount1 + fee + protocolFee (to pay previous reporter) + newAmount1 (for new position)
        uint256 totalToken1Needed = oldAmount1 + fee + protocolFee + newAmount1;
        weth.mint(address(this), totalToken1Needed);
        weth.approve(address(oracle), totalToken1Needed);
        
        // For token2: need to contribute the difference if newAmount2 > oldAmount2
        if (newAmount2 < oldAmount2) {
            // Will receive some token2 back, no need to mint more
        } else {
            uint256 token2Needed = newAmount2 - oldAmount2;
            usdt.mint(address(this), token2Needed);
            usdt.approve(address(oracle), token2Needed);
        }

        vm.expectEmit(true, false, false, true);
        emit ReportDisputed(reportId, address(this), newAmount1, newAmount2, address(weth), address(usdt), 400, 100, 60, 5, 10 ether);

        oracle.disputeAndSwap(reportId, address(weth), newAmount1, newAmount2);

        // Check dispute was recorded
        (,, address currentReporter,,,,,, bool isSettled, bool disputeOccurred,,) = oracle.reportStatus(reportId);
        assertEq(currentReporter, address(this));
        assertTrue(disputeOccurred);
        assertFalse(isSettled);
    }

    function testDisputeToken2Swap() public {
        uint256 reportId = _createAndSubmitReport();

        // Fast forward past dispute delay
        skip(10);

        uint256 newAmount1 = (1 ether * 110) / 100; // 1.1 ETH
        uint256 newAmount2 = 2700e18; // Different price

        // Calculate required tokens
        uint256 fee = (3000e18 * 400) / 10000000;
        uint256 protocolFee = (3000e18 * 100) / 10000000;
        
        // Mint additional tokens
        usdt.mint(address(this), 3000e18 + fee + protocolFee + newAmount2);
        usdt.approve(address(oracle), 3000e18 + fee + protocolFee + newAmount2);
        
        weth.mint(address(this), newAmount1 - 1 ether);
        weth.approve(address(oracle), newAmount1 - 1 ether);

        oracle.disputeAndSwap(reportId, address(usdt), newAmount1, newAmount2);

        // Check dispute was recorded
        (,,,,,,,, /* bool isSettled */, bool disputeOccurred,,) = oracle.reportStatus(reportId);
        assertTrue(disputeOccurred);
    }

    function testCannotDisputeTooEarly() public {
        uint256 reportId = _createAndSubmitReport();

        // Try to dispute before dispute delay
        skip(4);

        vm.expectRevert(abi.encodeWithSignature("InvalidTiming(string)", "dispute too early"));
        oracle.disputeAndSwap(reportId, address(weth), 1.1 ether, 3300e18);
    }

    function testCannotDisputeAfterSettlement() public {
        uint256 reportId = _createAndSubmitReport();

        // Fast forward past settlement time
        skip(65);

        vm.expectRevert(abi.encodeWithSignature("InvalidTiming(string)", "dispute period expired"));
        oracle.disputeAndSwap(reportId, address(weth), 1.1 ether, 3300e18);
    }

    function testCannotDisputeWithSamePrice() public {
        uint256 reportId = _createAndSubmitReport();

        skip(10);

        // Try to dispute with same price (within fee boundary) - calculate a price that's within boundaries
        uint256 newAmount1 = (1 ether * 110) / 100;
        uint256 newAmount2 = 3300e18; // This should be close enough to original price to be within boundaries
        
        vm.expectRevert(abi.encodeWithSignature("OutOfBounds(string)", "price within boundaries"));
        oracle.disputeAndSwap(reportId, address(weth), newAmount1, newAmount2);
    }

    function testProtocolFeeWithdrawal() public {
        uint256 reportId = _createAndSubmitReport();

        // Create a dispute to generate protocol fees
        skip(10);
        
        uint256 newAmount1 = (1 ether * 110) / 100;
        uint256 newAmount2 = 2700e18; // Different price
        
        uint256 fee = (3000e18 * 400) / 10000000;
        uint256 protocolFee = (3000e18 * 100) / 10000000;
        
        usdt.mint(address(this), 3000e18 + fee + protocolFee + newAmount2);
        usdt.approve(address(oracle), 3000e18 + fee + protocolFee + newAmount2);
        
        weth.mint(address(this), newAmount1 - 1 ether);
        weth.approve(address(oracle), newAmount1 - 1 ether);

        oracle.disputeAndSwap(reportId, address(usdt), newAmount1, newAmount2);

        // Check protocol fees were accumulated
        uint256 protocolFeesAccumulated = oracle.protocolFees(address(usdt));
        assertGt(protocolFeesAccumulated, 0);

        // Withdraw protocol fees
        uint256 feeRecipientBalanceBefore = usdt.balanceOf(oracle.protocolFeeRecipient());
        oracle.getProtocolFees(address(usdt));
        
        uint256 feeRecipientBalanceAfter = usdt.balanceOf(oracle.protocolFeeRecipient());
        assertEq(feeRecipientBalanceAfter, feeRecipientBalanceBefore + protocolFeesAccumulated);
        
        // Check fees were reset
        assertEq(oracle.protocolFees(address(usdt)), 0);
    }

    function testGetSettlementData() public {
        uint256 reportId = _createAndSubmitReport();

        skip(61);
        (uint256 price, uint256 settlementTimestamp) = oracle.settle(reportId);

        // Test getting settlement data
        (uint256 retrievedPrice, uint256 retrievedTimestamp) = oracle.getSettlementData(reportId);
        assertEq(retrievedPrice, price);
        assertEq(retrievedTimestamp, settlementTimestamp);
    }

    function testCannotGetSettlementDataForUnsettledReport() public {
        uint256 reportId = _createAndSubmitReport();

        vm.expectRevert(abi.encodeWithSignature("AlreadyProcessed(string)", "not settled"));
        oracle.getSettlementData(reportId);
    }

    function testCreateReportInstanceValidation() public {
        // Test insufficient fee
        vm.expectRevert(abi.encodeWithSignature("InsufficientAmount(string)", "fee"));
        oracle.createReportInstance{value: 50}(
            address(weth), address(usdt), 1 ether, 400, 110, 60, 10 ether, 5, 100, 0.0001 ether
        );

        // Test same tokens
        vm.expectRevert(abi.encodeWithSignature("TokensCannotBeSame()"));
        oracle.createReportInstance{value: 0.001 ether}(
            address(weth), address(weth), 1 ether, 400, 110, 60, 10 ether, 5, 100, 0.0001 ether
        );

        // Test invalid settlement time
        vm.expectRevert(abi.encodeWithSignature("InvalidTiming(string)", "settlement vs dispute delay"));
        oracle.createReportInstance{value: 0.001 ether}(
            address(weth), address(usdt), 1 ether, 400, 110, 5, 10 ether, 10, 100, 0.0001 ether
        );

        // Test settler reward too high
        vm.expectRevert(abi.encodeWithSignature("InsufficientAmount(string)", "settler reward fee"));
        oracle.createReportInstance{value: 0.001 ether}(
            address(weth), address(usdt), 1 ether, 400, 110, 60, 10 ether, 5, 100, 0.002 ether
        );
    }

    function testSubmitInitialReportValidation() public {
        uint256 reportId = oracle.createReportInstance{value: 0.001 ether}(
            address(weth), address(usdt), 1 ether, 400, 110, 60, 10 ether, 5, 100, 0.0001 ether
        );

        // Test wrong token1 amount
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "token1 amount"));
        oracle.submitInitialReport(reportId, 2 ether, 3000e18);

        // Test zero token2 amount
        vm.expectRevert(abi.encodeWithSignature("InvalidInput(string)", "token2 amount"));
        oracle.submitInitialReport(reportId, 1 ether, 0);

        // Submit valid report
        oracle.submitInitialReport(reportId, 1 ether, 3000e18);

        // Test double submission
        vm.expectRevert(abi.encodeWithSignature("AlreadyProcessed(string)", "report submitted"));
        oracle.submitInitialReport(reportId, 1 ether, 3000e18);
    }

    function testGasOptimization() public {
        // Test that core functions use reasonable gas amounts
        uint256 reportId = oracle.createReportInstance{value: 0.001 ether}(
            address(weth), address(usdt), 1 ether, 400, 110, 60, 10 ether, 5, 100, 0.0001 ether
        );
        
        uint256 gasBefore = gasleft();
        oracle.submitInitialReport(reportId, 1 ether, 3000e18);
        uint256 gasUsed = gasBefore - gasleft();
        
        // submitInitialReport should use reasonable gas (less than 300k)
        assertLt(gasUsed, 300000);
        
        skip(61);
        
        gasBefore = gasleft();
        oracle.settle(reportId);
        gasUsed = gasBefore - gasleft();
        
        // settle should use reasonable gas (less than 200k)
        assertLt(gasUsed, 200000);
    }

    function testEventEmissions() public {
        // Test ReportInstanceCreated event
        vm.expectEmit(true, true, true, true);
        emit ReportInstanceCreated(
            1, address(weth), address(usdt), 400, 110, 1 ether, 0.001 ether, 
            address(this), 60, 10 ether, 5, 100, 0.0001 ether
        );
        
        uint256 reportId = oracle.createReportInstance{value: 0.001 ether}(
            address(weth), address(usdt), 1 ether, 400, 110, 60, 10 ether, 5, 100, 0.0001 ether
        );

        // Test InitialReportSubmitted event
        vm.expectEmit(true, false, false, true);
        emit InitialReportSubmitted(
            reportId, address(this), 1 ether, 3000e18, address(weth), address(usdt), 400, 100, 60, 5, 10 ether
        );
        
        oracle.submitInitialReport(reportId, 1 ether, 3000e18);

        // Test ReportSettled event
        skip(61);
        
        vm.expectEmit(true, false, false, false);
        emit ReportSettled(reportId, 0, 0); // Will be filled with actual values
        
        oracle.settle(reportId);
    }

    // Helper function to create and submit a report
    function _createAndSubmitReport() internal returns (uint256 reportId) {
        reportId = oracle.createReportInstance{value: 0.001 ether}(
            address(weth),
            address(usdt),
            1 ether,
            400,
            110,
            60,
            10 ether,
            5,
            100,
            0.0001 ether
        );

        oracle.submitInitialReport(reportId, 1 ether, 3000e18);
    }

    // Events for testing
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

    // allow contract to receive ether
    receive() external payable {}
}
