// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

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
* Copyright (c) 2020 RubyFinance
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

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";

import "../interfaces/IRubyMinterV2.sol";
import "../interfaces/IStakingRewards.sol";
import "../interfaces/IPriceCalculator.sol";

import "../zap/ZapBSC.sol";
import "../library/SafeToken.sol";

abstract contract RubyMinterV2 is IRubyMinterV2, OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public immutable RUBY;
    address public immutable RUBY_POOL;

    address public constant TREASURY = 0x0989091F27708Bc92ea4cA60073e03592B94C0eE;
    address private constant TIMELOCK = 0x85c9162A51E03078bdCd08D4232Bab13ed414cC3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint public constant FEE_MAX = 10000;

    IPriceCalculator public constant priceCalculator = IPriceCalculator(0xF5BF8A9249e3cc4cB684E3f23db9669323d4FB7d);
    ZapBSC private constant zap = ZapBSC(0xdC2bBB0D33E0e7Dea9F5b98F46EDBaC823586a0C);
    IPancakeRouter02 private constant router = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    /* ========== STATE VARIABLES ========== */

    address public rubyChef;
    mapping(address => bool) private _minters;
    address public _deprecated_helper; // deprecated

    uint public PERFORMANCE_FEE;
    uint public override WITHDRAWAL_FEE_FREE_PERIOD;
    uint public override WITHDRAWAL_FEE;

    uint public _deprecated_rubyPerProfitBNB; // deprecated
    uint public _deprecated_rubyPerRubyBNBFlip;   // deprecated

    uint private _floatingRateEmission;
    uint private _freThreshold;

    /* ========== MODIFIERS ========== */

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "RubyMinterV2: caller is not the minter");
        _;
    }

    modifier onlyRubyChef {
        require(msg.sender == rubyChef, "RubyMinterV2: caller not the ruby chef");
        _;
    }

    constructor(address _ruby, address _rubyPool)public{
        RUBY = _ruby;
        RUBY_POOL = _rubyPool;
    }

    /* ========== EVENTS ========== */

    event PerformanceFee(address indexed asset, uint amount, uint value);

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
        WITHDRAWAL_FEE = 50;
        PERFORMANCE_FEE = 3000;

        _deprecated_rubyPerProfitBNB = 5e18;
        _deprecated_rubyPerRubyBNBFlip = 6e18;

        IBEP20(RUBY).approve(RUBY_POOL, uint(- 1));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferRubyOwner(address _owner) external onlyOwner {
        Ownable(RUBY).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");
        // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external override onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setRubyChef(address _rubyChef) external onlyOwner {
        require(rubyChef == address(0), "RubyMinterV2: setRubyChef only once");
        rubyChef = _rubyChef;
    }

    function setFloatingRateEmission(uint floatingRateEmission) external onlyOwner {
        require(floatingRateEmission > 1e18 && floatingRateEmission < 10e18, "RubyMinterV2: floatingRateEmission wrong range");
        _floatingRateEmission = floatingRateEmission;
    }

    function setFREThreshold(uint threshold) external onlyOwner {
        _freThreshold = threshold;
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(RUBY).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountRubyToMint(uint bnbProfit) public view override returns (uint) {
        return bnbProfit.mul(priceCalculator.priceOfBNB()).div(priceCalculator.priceOfRuby()).mul(floatingRateEmission()).div(1e18);
    }

    function amountRubyToMintForRubyBNB(uint amount, uint duration) public view override returns (uint) {
        return amount.mul(_deprecated_rubyPerRubyBNBFlip).mul(duration).div(365 days).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) external view override returns (uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) public view override returns (uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    function floatingRateEmission() public view returns(uint) {
        return _floatingRateEmission == 0 ? 120e16 : _floatingRateEmission;
    }

    function freThreshold() public view returns(uint) {
        return _freThreshold == 0 ? 18e18 : _freThreshold;
    }

    function shouldMarketBuy() public view returns(bool) {
        return priceCalculator.priceOfRuby().mul(freThreshold()).div(priceCalculator.priceOfBNB()) < 1e18;
    }

    /* ========== V1 FUNCTIONS ========== */

    function mintFor(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint) public payable override onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        _transferAsset(asset, feeSum);

        if (asset == RUBY) {
            IBEP20(RUBY).safeTransfer(DEAD, feeSum);
            return;
        }

        bool marketBuy = shouldMarketBuy();
        if (marketBuy == false) {
            if (asset == address(0)) { // means BNB
                SafeToken.safeTransferETH(TREASURY, feeSum);
            } else {
                IBEP20(asset).safeTransfer(TREASURY, feeSum);
            }
        } else {
            if (_withdrawalFee > 0) {
                if (asset == address(0)) { // means BNB
                    SafeToken.safeTransferETH(TREASURY, _withdrawalFee);
                } else {
                    IBEP20(asset).safeTransfer(TREASURY, _withdrawalFee);
                }
            }

            if (_performanceFee == 0) return;

            _marketBuy(asset, _performanceFee, to);
            _performanceFee = _performanceFee.mul(floatingRateEmission().sub(1e18)).div(floatingRateEmission());
        }

        (uint contributionInBNB, uint contributionInUSD) = priceCalculator.valueOfAsset(asset, _performanceFee);
        uint mintRuby = amountRubyToMint(contributionInBNB);
        if (mintRuby == 0) return;
        _mint(mintRuby, to);

        if (marketBuy) {
            uint usd = contributionInUSD.mul(floatingRateEmission()).div(floatingRateEmission().sub(1e18));
            emit PerformanceFee(asset, _performanceFee, usd);
        } else {
            emit PerformanceFee(asset, _performanceFee, contributionInUSD);
        }
    }

    /* ========== PancakeSwap V2 FUNCTIONS ========== */

    function mintForV2(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint timestamp) external payable override onlyMinter {
        mintFor(asset, _withdrawalFee, _performanceFee, to, timestamp);
    }

    /* ========== RubyChef FUNCTIONS ========== */

    function mint(uint amount) external override onlyRubyChef {
        if (amount == 0) return;
        _mint(amount, address(this));
    }

    function safeRubyTransfer(address _to, uint _amount) external override onlyRubyChef {
        if (_amount == 0) return;

        uint bal = IBEP20(RUBY).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(RUBY).safeTransfer(_to, _amount);
        } else {
            IBEP20(RUBY).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Ruby is transferred to the timelock contract.
    function mintGov(uint amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, TIMELOCK);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _marketBuy(address asset, uint amount, address to) private {
        uint _initRubyAmount = IBEP20(RUBY).balanceOf(address(this));

        if (asset == address(0)) {
            zap.zapIn{ value : amount }(RUBY);
        }
        else if (keccak256(abi.encodePacked(IPancakePair(asset).symbol())) == keccak256("Cake-LP")) {
            if (IBEP20(asset).allowance(address(this), address(router)) == 0) {
                IBEP20(asset).safeApprove(address(router), uint(- 1));
            }

            IPancakePair pair = IPancakePair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();

            // burn
            if (IPancakePair(asset).balanceOf(asset) > 0) {
                IPancakePair(asset).burn(address(zap));
            }

            (uint amountToken0, uint amountToken1) = router.removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp);

            if (IBEP20(token0).allowance(address(this), address(zap)) == 0) {
                IBEP20(token0).safeApprove(address(zap), uint(- 1));
            }
            if (IBEP20(token1).allowance(address(this), address(zap)) == 0) {
                IBEP20(token1).safeApprove(address(zap), uint(- 1));
            }

            if (token0 != RUBY) {
                zap.zapInToken(token0, amountToken0, RUBY);
            }

            if (token1 != RUBY) {
                zap.zapInToken(token1, amountToken1, RUBY);
            }
        }
        else {
            if (IBEP20(asset).allowance(address(this), address(zap)) == 0) {
                IBEP20(asset).safeApprove(address(zap), uint(- 1));
            }

            zap.zapInToken(asset, amount, RUBY);
        }

        uint rubyAmount = IBEP20(RUBY).balanceOf(address(this)).sub(_initRubyAmount);
        IBEP20(RUBY).safeTransfer(to, rubyAmount);
    }

    function _transferAsset(address asset, uint amount) private {
        if (asset == address(0)) {
            // case) transferred BNB
            require(msg.value >= amount);
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _mint(uint amount, address to) private {
        BEP20 tokenRUBY = BEP20(RUBY);

        tokenRUBY.mint(amount);
        if (to != address(this)) {
            tokenRUBY.transfer(to, amount);
        }

        uint rubyForDev = amount.mul(15).div(100);
        tokenRUBY.mint(rubyForDev);
        tokenRUBY.transfer(TREASURY, rubyForDev);
    }
}
