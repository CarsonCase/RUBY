// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IPotController {
    function numbersDrawn(uint potId, bytes32 requestId, uint256 randomness) external;
}
