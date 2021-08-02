// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../library/bep20/BEP20Upgradeable.sol";

contract PRubyToken is BEP20Upgradeable {

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __BEP20__init("Platinum Ruby Token", "pRUBY", 18);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function mint(uint _amount) public onlyOwner {
        _mint(owner(), _amount);
    }
}
