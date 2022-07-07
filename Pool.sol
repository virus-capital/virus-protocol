//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import { vToken, IVirusToken, IPool } from "./Interfaces.sol";
import { IUniswapV2Router02 } from "./IUniswapV2.sol";

contract Pool is ReentrancyGuardUpgradeable, IPool {
    using SafeERC20 for IERC20;

    uint256 constant private PRECISION = 1e12;
    uint256 constant private STEP = 100000 ether;
    vToken constant private vBUSD = vToken(0x95c78222B3D6e262426483D42CfA53685A67Ab9D);
    IERC20 constant private BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IUniswapV2Router02 constant private ROUTER = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    struct UserInfo {
        uint256 amount;
        uint256 issued;
        uint256 rewardDebt;
    }

    uint256 public totalStaking;
    uint256 public supply;
    uint256 public freeTime;
    uint256 public minAmount;
    uint256 public rewardPerSecond;
    mapping (address => UserInfo) public users;
    mapping (address => uint256) public limits;

    address private dev;
    IVirusToken private token;
    address private mainGame;
    address private feeReceiver;
    uint256 private lastRewardTime;
    uint256 private accRewardPerShare;

    modifier onlyDev {
        require(msg.sender == dev, "only dev");
        _;
    }

    function initialize(IVirusToken _token, address _mainGame, address _feeReceiver) public initializer {
        __ReentrancyGuard_init();
        dev = msg.sender;
        token = _token;
        mainGame = _mainGame;
        feeReceiver = _feeReceiver;
        minAmount = 1000000 ether;
        rewardPerSecond = uint256(10000 ether) / (1 days);
        BUSD.approve(address(vBUSD), type(uint256).max);
        token.approve(address(ROUTER), type(uint256).max);
    }

    function setMinAmount(uint256 _minAmount) public onlyDev {
        require(_minAmount > 0, "must gt 0");
        update();
        minAmount = _minAmount;
    }

    function setFeeReceiver(address _feeReceiver) public onlyDev {
        feeReceiver = _feeReceiver;
    }

    function harvestProfit() public onlyDev {
        update();
        uint256 total = vBUSD.balanceOfUnderlying(address(this));
        if (total > totalStaking) {
            require(vBUSD.redeemUnderlying(total - totalStaking) == 0, "vBUSD fail");
            uint256 amount = BUSD.balanceOf(address(this));
            if (amount > 0) {
                BUSD.safeTransfer(feeReceiver, amount);
            }
        }
    }

    function update() public {
        if (block.timestamp <= lastRewardTime) {
            return;
        }
        if (freeTime == 0 && totalStaking >= minAmount) {
            freeTime = lastRewardTime + (10 days);
        }
        uint256 reward = (block.timestamp - lastRewardTime) * rewardPerSecond;
        lastRewardTime = block.timestamp;
        if (totalStaking < minAmount) return;
        accRewardPerShare += (reward * PRECISION) / totalStaking;
        token.mint(address(this), reward);
        _incSupply(reward);
    }

    function deposit(uint256 amount) public nonReentrant {
        update();
        if (freeTime > 0 && block.timestamp > freeTime) {
            require(limits[msg.sender] >= amount, "reach limit");
            limits[msg.sender] -= amount;
        }
        require(amount > 0, "amount invalid");
        BUSD.safeTransferFrom(msg.sender, address(this), amount);
        require(vBUSD.mint(amount) == 0, "vBUSD fail");
        totalStaking += amount;
        UserInfo storage user = users[msg.sender];
        user.amount += amount;
        user.rewardDebt += amount * accRewardPerShare / PRECISION;
    }

    function withdraw() public nonReentrant {
        update();
        UserInfo storage user = users[msg.sender];
        if (user.issued > 0) {
            token.burn(msg.sender, user.issued);
        }
        uint256 pending = user.amount * accRewardPerShare / PRECISION - user.rewardDebt;
        if (pending > 0) {
            token.burn(address(this), pending);
        }
        _decSupply(user.issued + pending);
        totalStaking -= user.amount;
        require(vBUSD.redeemUnderlying(user.amount) == 0, "vBUSD fail");
        BUSD.safeTransfer(msg.sender, user.amount);
        delete users[msg.sender];
    }

    function harvest() public nonReentrant {
        update();
        UserInfo storage user = users[msg.sender];
        uint256 pending = user.amount * accRewardPerShare / PRECISION - user.rewardDebt;
        if (pending > 0) {
            _sendReward(msg.sender, pending);
            user.issued += pending;
        }
        user.rewardDebt += pending;
    }

    function incLimit(address to, uint256 amount) public {
        require(msg.sender == mainGame, "only main game");
        limits[to] += amount;
    }

    function status(address user) public view returns (uint256 staking, uint256 pending, uint256 amount, uint256 issued) {
        staking = totalStaking;
        uint256 _accRewardPerShare = accRewardPerShare;
        if (block.timestamp > lastRewardTime && lastRewardTime != 0 && staking >= minAmount) {
            uint256 reward = (block.timestamp - lastRewardTime) * rewardPerSecond;
            _accRewardPerShare += reward * PRECISION / staking;
        }
        UserInfo memory userInfo = users[user];
        pending = userInfo.amount * _accRewardPerShare / PRECISION - userInfo.rewardDebt;
        amount = userInfo.amount;
        issued = userInfo.issued;
    }

    function _sendReward(address user, uint256 amount) internal {
        // send 90% to user
        token.transfer(user, amount * 9 / 10);
        // send 9% to main game
        token.transfer(mainGame, amount * 9 / 100);
        // and sell 1% to feeReceiver
        uint256 toSell = amount / 100;
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(BUSD);
        ROUTER.swapExactTokensForTokens(toSell, 0, path, feeReceiver, block.timestamp);
    }

    function _incSupply(uint256 amount) internal {
        if (amount == 0) return;
        uint256 old = supply / STEP;
        supply += amount;
        uint256 step = supply / STEP - old;
        for (uint i = 0; i < step; i++) {
            rewardPerSecond = rewardPerSecond * 9 / 10;
        }
    }

    function _decSupply(uint256 amount) internal {
        if (amount == 0) return;
        uint256 old = supply / STEP;
        supply -= amount;
        uint256 step = old - supply / STEP;
        for (uint i = 0; i < step; i++) {
            rewardPerSecond = rewardPerSecond * 10 / 9;
        }
    }
}