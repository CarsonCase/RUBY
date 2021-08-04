// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma experimental ABIEncoderV2;

interface IRubyChef {

    struct UserInfo {
        uint balance;
        uint pending;
        uint rewardPaid;
    }

    struct VaultInfo {
        address token;
        uint allocPoint;       // How many allocation points assigned to this pool. RUBYs to distribute per block.
        uint lastRewardBlock;  // Last block number that RUBYs distribution occurs.
        uint accRubyPerShare; // Accumulated RUBYs per share, times 1e12. See below.
    }

    function rubyPerBlock() external view returns (uint);
    function totalAllocPoint() external view returns (uint);

    function vaultInfoOf(address vault) external view returns (VaultInfo memory);
    function vaultUserInfoOf(address vault, address user) external view returns (UserInfo memory);
    function pendingRuby(address vault, address user) external view returns (uint);

    function notifyDeposited(address user, uint amount) external;
    function notifyWithdrawn(address user, uint amount) external;
    function safeRubyTransfer(address user) external returns (uint);

    function updateRewardsOf(address vault) external;
}
