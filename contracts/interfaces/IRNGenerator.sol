// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IRNGenerator {
    function getRandomNumber(uint _potId, uint256 userProvidedSeed) external returns(bytes32 requestId);
}