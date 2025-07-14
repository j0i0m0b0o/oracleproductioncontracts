// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* ---------- external deps ---------- */
import {IERC20}      from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}   from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* ---------- minimal OpenOracle interface ---------- */
interface IOpenOracle {
    /* createReportInstance(timeType = true overload) */
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
    ) external payable returns (uint256 reportId);

    /* initial report overload with reporter */
    function submitInitialReport(
        uint256 reportId,
        uint256 amount1,
        uint256 amount2,
        address reporter
    ) external;
}

/* ****************************************************
 *            OracleSwapFacility (v0.1)                *
 ***************************************************** */
contract OracleSwapFacility is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* immutables */
    IOpenOracle public immutable oracle;

    /* -------- EVENTS -------- */
    event SwapReportOpened(
        uint256 indexed reportId,
        address indexed user,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feePaidWei
    );

    constructor(address oracle_) {
        require(oracle_ != address(0), "oracle addr 0");
        oracle = IOpenOracle(oracle_);
    }

    function createAndReport(
        address token1,
        address token2,
        uint256 amount1,
        uint256 amount2,
        uint256 fee, // 2222 = 2.222bps
        uint256 settlementTime
            ) external payable nonReentrant returns (uint256 reportId) {
        require(token1 != token2, "tokens identical");
        require(amount1 > 0 && amount2 > 0, "zero amounts");
        if (msg.value <= 100) revert("not enough msg.value");

        /* ------------ pull the user’s tokens ------------ */
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        IERC20(token2).safeTransferFrom(msg.sender, address(this), amount2);

        /* ------------ create report instance ------------ */
        reportId = oracle.createReportInstance{value: msg.value}(
            token1,
            token2,
            amount1,          // exactToken1Report
            fee,
            101,
            settlementTime,
            amount1,
            0,
            0,
            msg.value - 1
        );

        /* ------------ let oracle move the tokens -------- */
        IERC20(token1).safeIncreaseAllowance(address(oracle), amount1);
        IERC20(token2).safeIncreaseAllowance(address(oracle), amount2);

        /* ------------ file the initial report ----------- */
        oracle.submitInitialReport(reportId, amount1, amount2, msg.sender);

        emit SwapReportOpened(
            reportId,
            msg.sender,
            token1,
            token2,
            amount1,
            amount2,
            msg.value
        );
    }
}