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
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "../../library/PausableUpgradeable.sol";
import "../../library/SafeToken.sol";
import "../../library/SafeVenus.sol";

import {VaultVenusBridgeOwner} from "./VaultVenusBridgeOwner.sol";
import "../VaultController.sol";

import "../../interfaces/IStrategy.sol";
import "../../interfaces/IVToken.sol";
import "../../interfaces/IVenusDistribution.sol";
import "../../interfaces/IVaultVenusBridge.sol";
import "../../interfaces/IBank.sol";

contract VaultVenus is VaultController, IStrategy, ReentrancyGuardUpgradeable {
    using SafeMath for uint256;
    using SafeToken for address;

    /* ========== CONSTANTS ============= */

    uint256 public constant override pid = 9999;
    PoolConstant.PoolTypes public constant override poolType =
        PoolConstant.PoolTypes.Venus;

    IVenusDistribution private constant VENUS_UNITROLLER =
        IVenusDistribution(0xfD36E2c2a6789Db23113685031d7F16329158384);
    VaultVenusBridgeOwner private constant VENUS_BRIDGE_OWNER =
        VaultVenusBridgeOwner(
            payable(0x500f1F9b16ff707F81d5281de6E5D5b14cE8Ea71)
        );

    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant XVS = 0xcF6BB5389c92Bdda8a3747Ddb454cB7a64626C63;

    uint256 private constant COLLATERAL_RATIO_INIT = 975;
    uint256 private constant COLLATERAL_RATIO_EMERGENCY = 998;
    uint256 private constant COLLATERAL_RATIO_SYSTEM_DEFAULT = 6e17;
    uint256 private constant DUST = 1000;

    uint256 private constant VENUS_EXIT_BASE = 10000;

    /* ========== STATE VARIABLES ========== */

    IVToken public vToken;
    IVaultVenusBridge public venusBridge;
    SafeVenus public safeVenus;
    address public bank;

    uint256 public venusBorrow;
    uint256 public venusSupply;

    uint256 public collateralDepth;
    uint256 public collateralRatioFactor;

    uint256 public collateralRatio;
    uint256 public collateralRatioLimit;
    uint256 public collateralRatioEmergency;

    uint256 public reserveRatio;

    uint256 public totalShares;
    mapping(address => uint256) private _shares;
    mapping(address => uint256) private _principal;
    mapping(address => uint256) private _depositedAt;

    uint256 public venusExitRatio;
    uint256 public collateralRatioSystem;

    /* ========== EVENTS ========== */

    event CollateralFactorsUpdated(
        uint256 collateralRatioFactor,
        uint256 collateralDepth
    );
    event DebtAdded(address bank, uint256 amount);
    event DebtRemoved(address bank, uint256 amount);

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

    /* ========== MODIFIERS ========== */

    modifier onlyBank() {
        require(
            bank != address(0) && msg.sender == bank,
            "VaultVenus: caller is not the bank"
        );
        _;
    }

    modifier accrueBank() {
        if (bank != address(0)) {
            IBank(bank).executeAccrue();
        }
        _;
    }

    /* ========== INITIALIZER ========== */

    receive() external payable {}

    function initialize(address _token, address _vToken) external initializer {
        require(_token != address(0), "VaultVenus: invalid token");
        __VaultController_init(IBEP20(_token));
        __ReentrancyGuard_init();

        vToken = IVToken(_vToken);

        (, uint256 collateralFactorMantissa, ) = VENUS_UNITROLLER.markets(
            _vToken
        );
        collateralFactorMantissa = Math.min(
            collateralFactorMantissa,
            Math.min(collateralRatioSystem, COLLATERAL_RATIO_SYSTEM_DEFAULT)
        );

        collateralDepth = 8;
        collateralRatioFactor = COLLATERAL_RATIO_INIT;

        collateralRatio = 0;
        collateralRatioEmergency = collateralFactorMantissa
            .mul(COLLATERAL_RATIO_EMERGENCY)
            .div(1000);
        collateralRatioLimit = collateralFactorMantissa
            .mul(collateralRatioFactor)
            .div(1000);

        reserveRatio = 10;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalSupply() external view override returns (uint256) {
        return totalShares;
    }

    function balance() public view override returns (uint256) {
        uint256 debtOfBank = bank == address(0)
            ? 0
            : IBank(bank).debtToProviders();
        return
            balanceAvailable().add(venusSupply).sub(venusBorrow).add(
                debtOfBank
            );
    }

    function balanceAvailable() public view returns (uint256) {
        return venusBridge.availableOf(address(this));
    }

    function balanceReserved() public view returns (uint256) {
        return
            Math.min(balanceAvailable(), balance().mul(reserveRatio).div(1000));
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
        uint256 accountBalance = balanceOf(account);
        uint256 accountPrincipal = principalOf(account);
        if (accountBalance >= accountPrincipal + DUST) {
            return accountBalance.sub(accountPrincipal);
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
        return address(_stakingToken);
    }

    function priceShare() external view override returns (uint256) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    function getUtilizationInfo()
        external
        view
        returns (uint256 liquidity, uint256 utilized)
    {
        liquidity = balance();
        utilized = balance().sub(balanceReserved());
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    //    function setVenusBridge(address payable newBridge) public payable onlyOwner {
    //        require(newBridge != address(0), "VenusVault: bridge must be non-zero address");
    //        if (_stakingToken.allowance(address(this), address(newBridge)) == 0) {
    //            _stakingToken.safeApprove(address(newBridge), uint(- 1));
    //        }
    //
    //        uint _balanceBefore;
    //        if (address(venusBridge) != address(0) && totalShares > 0) {
    //            _balanceBefore = balance();
    //
    //            venusBridge.harvest();
    //            _decreaseCollateral(uint(- 1));
    //
    //            (venusBorrow, venusSupply) = safeVenus.venusBorrowAndSupply(address(this));
    //            require(venusBorrow == 0 && venusSupply == 0, "VaultVenus: borrow and supply must be zero");
    //            venusBridge.migrateTo(newBridge);
    //        }
    //
    //        venusBridge = IVaultVenusBridge(newBridge);
    //        uint _balanceAfter = balance();
    //        if (_balanceAfter < _balanceBefore && address(_stakingToken) != WBNB) {
    //            uint migrationCost = _balanceBefore.sub(_balanceAfter);
    //            _stakingToken.transferFrom(owner(), address(venusBridge), migrationCost);
    //            venusBridge.deposit(address(this), migrationCost);
    //        }
    //
    //        IVaultVenusBridge.MarketInfo memory market = venusBridge.infoOf(address(this));
    //        require(market.token != address(0) && market.vToken != address(0), "VaultVenus: invalid market info");
    //        _increaseCollateral(safeVenus.safeCompoundDepth(address(this)));
    //    }
    //
    //    function setMinter(address newMinter) public override onlyOwner {
    //        VaultController.setMinter(newMinter);
    //    }
    //
    //    function setRubiChef(IRubiChef newChef) public override onlyOwner {
    //        require(address(_rubiChef) == address(0), "VaultVenus: rubiChef exists");
    //        VaultController.setRubiChef(IRubiChef(newChef));
    //    }
    //
    //    function setCollateralFactors(uint _collateralRatioFactor, uint _collateralDepth) external onlyOwner {
    //        require(_collateralRatioFactor < COLLATERAL_RATIO_EMERGENCY, "VenusVault: invalid collateral ratio factor");
    //
    //        collateralRatioFactor = _collateralRatioFactor;
    //        collateralDepth = _collateralDepth;
    //        _increaseCollateral(safeVenus.safeCompoundDepth(address(this)));
    //        emit CollateralFactorsUpdated(_collateralRatioFactor, _collateralDepth);
    //    }
    //
    //    function setCollateralRatioSystem(uint _collateralRatioSystem) external onlyOwner {
    //        require(_collateralRatioSystem <= COLLATERAL_RATIO_SYSTEM_DEFAULT, "VenusVault: invalid collateral ratio system");
    //        collateralRatioSystem = _collateralRatioSystem;
    //    }
    //
    //    function setReserveRatio(uint _reserveRatio) external onlyOwner {
    //        require(_reserveRatio < 1000, "VaultVenus: invalid reserve ratio");
    //        reserveRatio = _reserveRatio;
    //    }

    function setVenusExitRatio(uint256 _ratio) external onlyOwner {
        require(_ratio <= VENUS_EXIT_BASE);
        venusExitRatio = _ratio;
    }

    function setSafeVenus(address payable _safeVenus) public onlyOwner {
        safeVenus = SafeVenus(_safeVenus);
    }

    function setBank(address newBank) external onlyOwner {
        require(address(bank) == address(0), "VaultVenus: bank exists");
        bank = newBank;
    }

    function increaseCollateral() external onlyKeeper {
        _increaseCollateral(
            safeVenus.safeCompoundDepth(payable(address(this)))
        );
    }

    function decreaseCollateral(uint256 amountMin, uint256 supply)
        external
        payable
        onlyKeeper
    {
        updateVenusFactors();

        uint256 _balanceBefore = balance();

        supply = msg.value > 0 ? msg.value : supply;
        if (address(_stakingToken) == WBNB) {
            venusBridge.deposit{value: supply}(address(this), supply);
        } else {
            _stakingToken.transferFrom(
                msg.sender,
                address(venusBridge),
                supply
            );
            venusBridge.deposit(address(this), supply);
        }

        venusBridge.mint(balanceAvailable());
        _decreaseCollateral(amountMin);
        venusBridge.withdraw(msg.sender, supply);

        updateVenusFactors();
        uint256 _balanceAfter = balance();
        if (_balanceAfter < _balanceBefore && address(_stakingToken) != WBNB) {
            uint256 migrationCost = _balanceBefore.sub(_balanceAfter);
            _stakingToken.transferFrom(
                owner(),
                address(venusBridge),
                migrationCost
            );
            venusBridge.deposit(address(this), migrationCost);
        }
    }

    /* ========== BANKING FUNCTIONS ========== */

    function borrow(uint256 amount) external onlyBank returns (uint256) {
        updateVenusFactors();
        uint256 available = balanceAvailable();
        if (available < amount) {
            _decreaseCollateral(amount);
            available = balanceAvailable();
        }

        amount = Math.min(amount, available);
        venusBridge.withdraw(bank, amount);

        emit DebtAdded(bank, amount);
        return amount;
    }

    function repay() external payable onlyBank returns (uint256) {
        uint256 amount = msg.value;
        venusBridge.deposit{value: amount}(address(this), amount);

        emit DebtRemoved(bank, amount);
        return amount;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function updateVenusFactors() public {
        (venusBorrow, venusSupply) = safeVenus.venusBorrowAndSupply(
            payable(address(this))
        );
        (, uint256 collateralFactorMantissa, ) = VENUS_UNITROLLER.markets(
            address(vToken)
        );
        collateralFactorMantissa = Math.min(
            collateralFactorMantissa,
            Math.min(collateralRatioSystem, COLLATERAL_RATIO_SYSTEM_DEFAULT)
        );

        collateralRatio = venusBorrow == 0
            ? 0
            : venusBorrow.mul(1e18).div(venusSupply);
        collateralRatioLimit = collateralFactorMantissa
            .mul(collateralRatioFactor)
            .div(1000);
        collateralRatioEmergency = collateralFactorMantissa
            .mul(COLLATERAL_RATIO_EMERGENCY)
            .div(1000);
    }

    function deposit(uint256 amount)
        public
        override
        accrueBank
        notPaused
        nonReentrant
    {
        require(address(_stakingToken) != WBNB, "VaultVenus: invalid asset");
        updateVenusFactors();

        uint256 _balance = balance();
        uint256 _before = balanceAvailable();
        _stakingToken.transferFrom(msg.sender, address(venusBridge), amount);
        venusBridge.deposit(address(this), amount);
        amount = balanceAvailable().sub(_before);

        uint256 shares = totalShares == 0
            ? amount
            : amount.mul(totalShares).div(_balance);
        if (address(_rubiChef) != address(0)) {
            _rubiChef.updateRewardsOf(address(this));
        }

        totalShares = totalShares.add(shares);
        _shares[msg.sender] = _shares[msg.sender].add(shares);
        _principal[msg.sender] = _principal[msg.sender].add(amount);
        _depositedAt[msg.sender] = block.timestamp;

        if (address(_rubiChef) != address(0)) {
            _rubiChef.notifyDeposited(msg.sender, shares);
        }
        emit Deposited(msg.sender, amount);
    }

    function depositAll() external override {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function depositBNB() public payable accrueBank notPaused nonReentrant {
        require(address(_stakingToken) == WBNB, "VaultVenus: invalid asset");
        updateVenusFactors();

        uint256 _balance = balance();
        uint256 amount = msg.value;
        venusBridge.deposit{value: amount}(address(this), amount);

        uint256 shares = totalShares == 0
            ? amount
            : amount.mul(totalShares).div(_balance);
        if (address(_rubiChef) != address(0)) {
            _rubiChef.updateRewardsOf(address(this));
        }

        totalShares = totalShares.add(shares);
        _shares[msg.sender] = _shares[msg.sender].add(shares);
        _principal[msg.sender] = _principal[msg.sender].add(amount);
        _depositedAt[msg.sender] = block.timestamp;

        if (address(_rubiChef) != address(0)) {
            _rubiChef.notifyDeposited(msg.sender, shares);
        }
        emit Deposited(msg.sender, amount);
    }

    function withdrawAll() external override accrueBank {
        updateVenusFactors();
        uint256 amount = balanceOf(msg.sender);
        require(
            _hasSufficientBalance(amount),
            "VaultVenus: insufficient balance"
        );

        uint256 principal = principalOf(msg.sender);
        uint256 available = balanceAvailable();
        uint256 depositTimestamp = _depositedAt[msg.sender];
        if (available < amount) {
            _decreaseCollateral(_getBufferedAmountMin(amount));
            amount = balanceOf(msg.sender);
            available = balanceAvailable();
        }

        amount = Math.min(amount, available);
        uint256 shares = _shares[msg.sender];
        if (address(_rubiChef) != address(0)) {
            _rubiChef.notifyWithdrawn(msg.sender, shares);
            uint256 rubiAmount = _rubiChef.safeRubiTransfer(msg.sender);
            emit RubiPaid(msg.sender, rubiAmount, 0);
        }

        totalShares = totalShares.sub(shares);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        uint256 profit = amount > principal ? amount.sub(principal) : 0;
        uint256 withdrawalFee = canMint()
            ? _minter.withdrawalFee(principal, depositTimestamp)
            : 0;
        uint256 performanceFee = canMint() ? _minter.performanceFee(profit) : 0;
        if (withdrawalFee.add(performanceFee) > DUST) {
            venusBridge.withdraw(
                address(this),
                withdrawalFee.add(performanceFee)
            );
            if (address(_stakingToken) == WBNB) {
                _minter.mintFor{value: withdrawalFee.add(performanceFee)}(
                    address(0),
                    withdrawalFee,
                    performanceFee,
                    msg.sender,
                    depositTimestamp
                );
            } else {
                _minter.mintFor(
                    address(_stakingToken),
                    withdrawalFee,
                    performanceFee,
                    msg.sender,
                    depositTimestamp
                );
            }

            if (performanceFee > 0) {
                emit ProfitPaid(msg.sender, profit, performanceFee);
            }
            amount = amount.sub(withdrawalFee).sub(performanceFee);
        }

        amount = _getAmountWithExitRatio(amount);
        venusBridge.withdraw(msg.sender, amount);
        if (collateralRatio > collateralRatioLimit) {
            _decreaseCollateral(0);
        }
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function withdraw(uint256) external override {
        revert("N/A");
    }

    function withdrawUnderlying(uint256 _amount) external accrueBank {
        updateVenusFactors();
        uint256 amount = Math.min(_amount, _principal[msg.sender]);
        uint256 available = balanceAvailable();
        if (available < amount) {
            _decreaseCollateral(_getBufferedAmountMin(amount));
            available = balanceAvailable();
        }

        amount = Math.min(amount, available);
        uint256 shares = balance() == 0
            ? 0
            : Math.min(
                amount.mul(totalShares).div(balance()),
                _shares[msg.sender]
            );
        if (address(_rubiChef) != address(0)) {
            _rubiChef.notifyWithdrawn(msg.sender, shares);
        }

        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        uint256 depositTimestamp = _depositedAt[msg.sender];
        uint256 withdrawalFee = canMint()
            ? _minter.withdrawalFee(amount, depositTimestamp)
            : 0;
        if (withdrawalFee > DUST) {
            venusBridge.withdraw(address(this), withdrawalFee);
            if (address(_stakingToken) == WBNB) {
                _minter.mintFor{value: withdrawalFee}(
                    address(0),
                    withdrawalFee,
                    0,
                    msg.sender,
                    depositTimestamp
                );
            } else {
                _minter.mintFor(
                    address(_stakingToken),
                    withdrawalFee,
                    0,
                    msg.sender,
                    depositTimestamp
                );
            }
            amount = amount.sub(withdrawalFee);
        }

        amount = _getAmountWithExitRatio(amount);
        venusBridge.withdraw(msg.sender, amount);
        if (collateralRatio >= collateralRatioLimit) {
            _decreaseCollateral(0);
        }
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function getReward() public override accrueBank nonReentrant {
        updateVenusFactors();
        uint256 amount = earned(msg.sender);
        uint256 available = balanceAvailable();
        if (available < amount) {
            _decreaseCollateral(_getBufferedAmountMin(amount));
            amount = earned(msg.sender);
            available = balanceAvailable();
        }

        amount = Math.min(amount, available);
        if (address(_rubiChef) != address(0)) {
            uint256 rubiAmount = _rubiChef.safeRubiTransfer(msg.sender);
            emit RubiPaid(msg.sender, rubiAmount, 0);
        }

        uint256 shares = balance() == 0
            ? 0
            : Math.min(
                amount.mul(totalShares).div(balance()),
                _shares[msg.sender]
            );
        if (address(_rubiChef) != address(0)) {
            _rubiChef.notifyWithdrawn(msg.sender, shares);
        }

        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);

        // cleanup dust
        if (_shares[msg.sender] > 0 && _shares[msg.sender] < DUST) {
            if (address(_rubiChef) != address(0)) {
                _rubiChef.notifyWithdrawn(msg.sender, _shares[msg.sender]);
            }
            totalShares = totalShares.sub(_shares[msg.sender]);
            delete _shares[msg.sender];
        }

        uint256 depositTimestamp = _depositedAt[msg.sender];
        uint256 performanceFee = canMint() ? _minter.performanceFee(amount) : 0;
        if (performanceFee > DUST) {
            venusBridge.withdraw(address(this), performanceFee);
            if (address(_stakingToken) == WBNB) {
                _minter.mintFor{value: performanceFee}(
                    address(0),
                    0,
                    performanceFee,
                    msg.sender,
                    depositTimestamp
                );
            } else {
                _minter.mintFor(
                    address(_stakingToken),
                    0,
                    performanceFee,
                    msg.sender,
                    depositTimestamp
                );
            }
            amount = amount.sub(performanceFee);
        }

        amount = _getAmountWithExitRatio(amount);
        venusBridge.withdraw(msg.sender, amount);
        if (collateralRatio >= collateralRatioLimit) {
            _decreaseCollateral(0);
        }
        emit ProfitPaid(msg.sender, amount, performanceFee);
    }

    function harvest() public override accrueBank notPaused onlyKeeper {
        VENUS_BRIDGE_OWNER.harvestBehalf(address(this));
        _increaseCollateral(3);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _hasSufficientBalance(uint256 amount) private view returns (bool) {
        return balanceAvailable().add(venusSupply).sub(venusBorrow) >= amount;
    }

    function _getBufferedAmountMin(uint256 amount)
        private
        view
        returns (uint256)
    {
        return venusExitRatio > 0 ? amount.mul(1005).div(1000) : amount;
    }

    function _getAmountWithExitRatio(uint256 amount)
        private
        view
        returns (uint256)
    {
        uint256 redeemFee = amount.mul(1005).mul(venusExitRatio).div(1000).div(
            VENUS_EXIT_BASE
        );
        return amount.sub(redeemFee);
    }

    function _increaseCollateral(uint256 compound) private {
        updateVenusFactors();
        (uint256 mintable, uint256 mintableInUSD) = safeVenus.safeMintAmount(
            payable(address(this))
        );
        if (mintableInUSD > 1e18) {
            venusBridge.mint(mintable);
        }

        updateVenusFactors();
        uint256 borrowable = safeVenus.safeBorrowAmount(payable(address(this)));
        while (!paused && compound > 0 && borrowable > 1) {
            if (borrowable == 0 || collateralRatio >= collateralRatioLimit) {
                return;
            }

            venusBridge.borrow(borrowable);
            updateVenusFactors();
            (mintable, mintableInUSD) = safeVenus.safeMintAmount(
                payable(address(this))
            );
            if (mintableInUSD > 1e18) {
                venusBridge.mint(mintable);
            }

            updateVenusFactors();
            borrowable = safeVenus.safeBorrowAmount(payable(address(this)));
            compound--;
        }
    }

    function _decreaseCollateral(uint256 amountMin) private {
        updateVenusFactors();

        uint256 marketSupply = vToken
            .totalSupply()
            .mul(vToken.exchangeRateCurrent())
            .div(1e18);
        uint256 marketLiquidity = marketSupply > vToken.totalBorrowsCurrent()
            ? marketSupply.sub(vToken.totalBorrowsCurrent())
            : 0;
        require(
            marketLiquidity >= amountMin,
            "VaultVenus: not enough market liquidity"
        );

        if (
            amountMin != uint256(-1) &&
            collateralRatio == 0 &&
            collateralRatioLimit == 0
        ) {
            venusBridge.redeemUnderlying(Math.min(venusSupply, amountMin));
            updateVenusFactors();
        } else {
            uint256 redeemable = safeVenus.safeRedeemAmount(
                payable(address(this))
            );
            while (venusBorrow > 0 && redeemable > 0) {
                uint256 redeemAmount = amountMin > 0
                    ? Math.min(venusSupply, Math.min(redeemable, amountMin))
                    : Math.min(venusSupply, redeemable);
                venusBridge.redeemUnderlying(redeemAmount);
                venusBridge.repayBorrow(
                    Math.min(venusBorrow, balanceAvailable())
                );
                updateVenusFactors();

                redeemable = safeVenus.safeRedeemAmount(payable(address(this)));
                uint256 available = balanceAvailable().add(redeemable);
                if (
                    collateralRatio <= collateralRatioLimit &&
                    available >= amountMin
                ) {
                    uint256 remain = amountMin > balanceAvailable()
                        ? amountMin.sub(balanceAvailable())
                        : 0;
                    if (remain > 0) {
                        venusBridge.redeemUnderlying(
                            Math.min(remain, redeemable)
                        );
                    }
                    updateVenusFactors();
                    return;
                }
            }

            if (amountMin == uint256(-1) && venusBorrow == 0) {
                venusBridge.redeemAll();
                updateVenusFactors();
            }
        }
    }

    /* ========== SALVAGE PURPOSE ONLY ========== */

    function recoverToken(address tokenAddress, uint256 tokenAmount)
        external
        override
        onlyOwner
    {
        require(
            tokenAddress != address(0) &&
                tokenAddress != address(_stakingToken) &&
                tokenAddress != address(vToken) &&
                tokenAddress != XVS,
            "VaultVenus: cannot recover token"
        );

        IBEP20(tokenAddress).transfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
}
