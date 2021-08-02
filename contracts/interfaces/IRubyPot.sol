// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma experimental ABIEncoderV2;

import {PotConstant} from "../library/PotConstant.sol";

interface IRubyPot {

    function potInfoOf(address _account) external view returns (PotConstant.PotInfo memory, PotConstant.PotInfoMe memory);

    function deposit(uint amount) external;
    function withdrawAll(uint amount) external;
}