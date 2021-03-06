// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma experimental ABIEncoderV2;

/*
  ___                      _   _
 | _ )_  _ _ _  _ _ _  _  | | | |
 | _ \ || | ' \| ' \ || | |_| |_|
 |___/\_,_|_||_|_||_\_, | (_) (_)
                    |__/

*
* MIT License
* ===========
*
* Copyright (c) 2020 BunnyFinance
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "../library/bep20/SafeBEP20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/IRubiMinter.sol";
import "../interfaces/IRubiChef.sol";
import "./VaultController.sol";
import {PoolConstant} from "../library/PoolConstant.sol";
import "../interfaces/legacy/IStrategyLegacy.sol";
import "../zap/ZapBSC.sol";

contract VaultRubiMaximizer is
    VaultController,
    IStrategy,
    ReentrancyGuardUpgradeable
{
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(
        address indexed user,
        uint256 amount,
        uint256 withdrawalFee
    );
    event ProfitPaid(
        address indexed user,
        uint256 profit,
        uint256 performanceFee
    );
    event RubiPaid(
        address indexed user,
        uint256 profit,
        uint256 performanceFee
    );
    event Harvested(uint256 profit);
    /* ========== CONSTANTS ============= */

    address private constant RUBI = 0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    PoolConstant.PoolTypes public constant override poolType =
        PoolConstant.PoolTypes.RubiToRubi;
    address private constant RUBI_POOL =
        0xCADc8CB26c8C7cB46500E61171b5F27e9bd7889D;
    address private constant TREASURY =
        0x85c9162A51E03078bdCd08D4232Bab13ed414cC3;

    ZapBSC public constant zap =
        ZapBSC(payable(payable(0xdC2bBB0D33E0e7Dea9F5b98F46EDBaC823586a0C)));

    uint256 private constant DUST = 1000;

    uint256 public constant override pid = 9999;

    /* ========== STATE VARIABLES ========== */

    uint256 private totalShares;
    mapping(address => uint256) private _shares;
    mapping(address => uint256) private _principal;
    mapping(address => uint256) private _depositedAt;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __VaultController_init(IBEP20(RUBI));
        __ReentrancyGuard_init();

        _stakingToken.approve(RUBI_POOL, uint256(-1));
        IBEP20(WBNB).approve(address(zap), uint256(-1));
        setMinter(0x8cB88701790F650F273c8BB2Cc4c5f439cd65219);
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint256) {
        return totalShares;
    }

    function balance() public view override returns (uint256) {
        return IStrategyLegacy(RUBI_POOL).balanceOf(address(this));
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account)
        public
        view
        override
        returns (uint256)
    {
        return balanceOf(account);
    }

    function sharesOf(address account) public view override returns (uint256) {
        return _shares[account];
    }

    function principalOf(address account)
        public
        view
        override
        returns (uint256)
    {
        return _principal[account];
    }

    function earned(address account) public view override returns (uint256) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function depositedAt(address account)
        external
        view
        override
        returns (uint256)
    {
        return _depositedAt[account];
    }

    function rewardsToken() external view override returns (address) {
        return RUBI;
    }

    function priceShare() external view override returns (uint256) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint256 amount) public override {
        _deposit(amount, msg.sender);
    }

    function depositAll() external override {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function withdrawAll() external override {
        uint256 amount = balanceOf(msg.sender);
        uint256 principal = principalOf(msg.sender);
        uint256 depositTimestamp = _depositedAt[msg.sender];

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        IStrategyLegacy(RUBI_POOL).withdraw(amount);

        uint256 withdrawalFee = _minter.withdrawalFee(
            principal,
            depositTimestamp
        );
        if (withdrawalFee > 0) {
            _stakingToken.safeTransfer(TREASURY, withdrawalFee);
            amount = amount.sub(withdrawalFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function harvest() public override onlyKeeper {
        IStrategyLegacy(RUBI_POOL).getReward();

        uint256 before = IBEP20(RUBI).balanceOf(address(this));
        zap.zapInToken(WBNB, IBEP20(WBNB).balanceOf(address(this)), RUBI);
        uint256 harvested = IBEP20(RUBI).balanceOf(address(this)).sub(before);
        emit Harvested(harvested);

        IStrategyLegacy(RUBI_POOL).deposit(harvested);
    }

    function withdraw(uint256 shares) external override onlyWhitelisted {
        uint256 amount = balance().mul(shares).div(totalShares);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);

        IStrategyLegacy(RUBI_POOL).withdraw(amount);

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, 0);
    }

    // @dev underlying only + withdrawal fee + no perf fee
    function withdrawUnderlying(uint256 _amount) external {
        uint256 amount = Math.min(_amount, _principal[msg.sender]);
        uint256 shares = Math.min(
            amount.mul(totalShares).div(balance()),
            _shares[msg.sender]
        );
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        IStrategyLegacy(RUBI_POOL).withdraw(amount);

        uint256 depositTimestamp = _depositedAt[msg.sender];
        uint256 withdrawalFee = _minter.withdrawalFee(amount, depositTimestamp);
        if (withdrawalFee > 0) {
            _stakingToken.safeTransfer(TREASURY, withdrawalFee);
            amount = amount.sub(withdrawalFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function getReward() public override nonReentrant {
        uint256 amount = earned(msg.sender);
        uint256 shares = Math.min(
            amount.mul(totalShares).div(balance()),
            _shares[msg.sender]
        );
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _cleanupIfDustShares();

        IStrategyLegacy(RUBI_POOL).withdraw(amount);

        _stakingToken.safeTransfer(msg.sender, amount);
        emit ProfitPaid(msg.sender, amount, 0);
    }

    function _cleanupIfDustShares() private {
        uint256 shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setMinter(address newMinter) public override onlyOwner {
        VaultController.setMinter(newMinter);
    }

    function setRubiChef(IRubiChef _chef) public override onlyOwner {
        require(
            address(_rubiChef) == address(0),
            "VaultRubi: setRubiChef only once"
        );
        VaultController.setRubiChef(IRubiChef(_chef));
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _deposit(uint256 _amount, address _to)
        private
        nonReentrant
        notPaused
    {
        uint256 _pool = balance();
        _stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 shares = totalShares == 0
            ? _amount
            : (_amount.mul(totalShares)).div(_pool);

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(_amount);
        _depositedAt[_to] = block.timestamp;

        IStrategyLegacy(RUBI_POOL).deposit(_amount);
        emit Deposited(_to, _amount);
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    function recoverToken(address tokenAddress, uint256 tokenAmount)
        external
        override
        onlyOwner
    {
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
}
