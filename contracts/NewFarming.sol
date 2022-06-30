// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import { IStrategy } from "./interfaces/IStrategy.sol";

contract NewFarming is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  // Info of each user.
  struct UserInfo {
    uint256 shares;
    uint256 rewardDebt;
    uint256 claimable;
  }

  IERC20 public rewardToken;
  IERC20 public stakingToken;
  IStrategy public strategy;
  uint256 public startTime;

  uint256 public rewardsPerSecond;
  uint256 public lastRewardTime;
  uint256 public accRewardPerShare;

  uint256 private constant MONTH = 7 minutes;

  // week -> addedRewards
  uint256[65535] public totalRewards;

  // user => Info of each user that stakes LP tokens.
  mapping(address => UserInfo) public userInfo;

  constructor(
    IERC20 _rewardToken,
    IERC20 _stakingToken,
    uint256 _startTime
  ) {
    rewardToken = _rewardToken;
    stakingToken = _stakingToken;
    startTime = _startTime;
    lastRewardTime = block.timestamp;
  }

  function setStrategy(IStrategy _strategy) external {
    require(address(strategy) == address(0), "already added");
    strategy = _strategy;
  }

  function claimableReward(address _user) external view returns (uint256) {
    UserInfo storage user = userInfo[_user];
    (uint256 _accRewardPerShare, ) = _getRewardData();
    _accRewardPerShare += accRewardPerShare;
    return user.claimable + (user.shares * _accRewardPerShare) / 1e12 - user.rewardDebt;
  }

  // Update reward variables of the given pool to be up-to-date.
  function updatePool() public returns (uint256 _accRewardPerShare) {
    uint256 _lastRewardTime = lastRewardTime;
    require(_lastRewardTime > 0, "Invalid pool");
    if (block.timestamp <= _lastRewardTime) {
      return _accRewardPerShare;
    }
    (_accRewardPerShare, rewardsPerSecond) = _getRewardData();
    lastRewardTime = block.timestamp;
    if (_accRewardPerShare == 0) return _accRewardPerShare;
    _accRewardPerShare += accRewardPerShare;
    accRewardPerShare = _accRewardPerShare;
    return _accRewardPerShare;
  }

  function deposit(uint256 _wantAmt) public nonReentrant returns (uint256) {
    require(_wantAmt > 0, "Cannot deposit zero");
    address _userAddress = msg.sender;
    uint256 _accRewardPerShare = updatePool();
    UserInfo storage user = userInfo[_userAddress];

    user.claimable += (user.shares * _accRewardPerShare) / 1e12 - user.rewardDebt;

    stakingToken.safeTransferFrom(_userAddress, address(this), _wantAmt);
    stakingToken.safeIncreaseAllowance(address(strategy), _wantAmt);
    uint256 sharesAdded = strategy.deposit(_userAddress, _wantAmt);
    user.shares += sharesAdded;

    user.rewardDebt = (user.shares * accRewardPerShare) / 1e12;
    return user.claimable;
  }

  function withdraw(uint256 _wantAmt) public nonReentrant returns (uint256) {
    address _userAddress = msg.sender;
    require(_wantAmt > 0, "Cannot withdraw zero");
    uint256 _accRewardPerShare = updatePool();
    UserInfo storage user = userInfo[_userAddress];

    uint256 sharesTotal = strategy.sharesTotal();

    require(user.shares > 0, "user.shares is 0");
    require(sharesTotal > 0, "sharesTotal is 0");

    user.claimable += (user.shares * _accRewardPerShare) / 1e12 - user.rewardDebt;

    // Withdraw want tokens
    uint256 amount = (user.shares * strategy.wantLockedTotal()) / sharesTotal;
    if (_wantAmt > amount) {
      _wantAmt = amount;
    }
    uint256 sharesRemoved = strategy.withdraw(_userAddress, _wantAmt);

    if (sharesRemoved >= user.shares) {
      _safeRewardTransfer(msg.sender, user.claimable);
      user.claimable = 0;
      user.shares = 0;
    } else {
      uint256 transferAmount = (user.claimable * sharesRemoved) / user.shares;
      _safeRewardTransfer(msg.sender, transferAmount);
      user.claimable -= transferAmount;
      user.shares -= sharesRemoved;
    }

    IERC20 token = stakingToken;
    uint256 wantBal = token.balanceOf(address(this));
    if (wantBal < _wantAmt) {
      _wantAmt = wantBal;
    }
    user.rewardDebt = (user.shares * accRewardPerShare) / 1e12;
    token.safeTransfer(_userAddress, _wantAmt);

    return user.claimable;
  }

  function withdrawAll() public returns (uint256) {
    return withdraw(type(uint256).max);
  }

  // Get updated reward data for the given token
  function _getRewardData()
    internal
    view
    returns (uint256 _accRewardPerShare, uint256 _rewardsPerSecond)
  {
    uint256 lpSupply = strategy.sharesTotal();
    uint256 start = startTime;
    uint256 currentMonth = (block.timestamp - start) / MONTH;

    if (lpSupply == 0) {
      return (0, getRewardsPerSecond(currentMonth));
    }

    uint256 _lastRewardTime = lastRewardTime;
    uint256 rewardMonth = (_lastRewardTime - start) / MONTH;
    _rewardsPerSecond = rewardsPerSecond;
    uint256 reward;
    uint256 duration;
    while (rewardMonth < currentMonth) {
      rewardMonth++;
      uint256 nextRewardTime = rewardMonth * MONTH + start;
      duration = nextRewardTime - _lastRewardTime;
      reward += duration * _rewardsPerSecond;
      _rewardsPerSecond = getRewardsPerSecond(rewardMonth);
      _lastRewardTime = nextRewardTime;
    }

    duration = block.timestamp - _lastRewardTime;
    reward += duration * _rewardsPerSecond;
    return ((reward * 1e12) / lpSupply, _rewardsPerSecond);
  }

  function _safeRewardTransfer(address _user, uint256 _rewardAmt) internal returns (uint256) {
    uint256 rewardBal = rewardToken.balanceOf(address(this));
    if (_rewardAmt > rewardBal) {
      _rewardAmt = rewardBal;
    }
    if (_rewardAmt > 0) {
      rewardToken.transfer(_user, _rewardAmt);
    }
    return _rewardAmt;
  }

  function getMonth() public view returns (uint256) {
    if (startTime > block.timestamp) return 0;
    return (block.timestamp - startTime) / MONTH;
  }

  function getRewardsPerSecond(uint256 _month) public view returns (uint256) {
    if (_month == 0) return 0;

    --_month;

    return (totalRewards[_month]) / (MONTH);
  }

  function inCaseTokensGetStuck(
    address _user,
    address _token,
    uint256 _amount
  ) public onlyOwner {
    require(_token != address(rewardToken), "!safe");
    IERC20(_token).safeTransfer(_user, _amount);
  }

  // Withdraw without caring about rewards. EMERGENCY ONLY.
  function emergencyWithdraw() public nonReentrant {
    address _userAddress = msg.sender;
    UserInfo storage user = userInfo[_userAddress];

    uint256 wantLockedTotal = strategy.wantLockedTotal();
    uint256 sharesTotal = strategy.sharesTotal();
    uint256 amount = (user.shares * wantLockedTotal) / sharesTotal;

    strategy.withdraw(_userAddress, amount);

    stakingToken.safeTransfer(_userAddress, amount);
    delete userInfo[_userAddress];
  }

  function addReward(uint256 month, uint256 amount) external {
    uint256 currentMonth = getMonth();
    require(currentMonth <= month, "You can add rewards starting from the current month");
    rewardToken.transferFrom(msg.sender, address(this), amount);
    uint256 totalAmount = totalRewards[month] + amount;
    totalRewards[month] = totalAmount;
  }

  function removeReward(uint256 month, uint256 amount) external onlyOwner {
    uint256 currentWeek = getMonth();
    require(currentWeek < month, "You can remove rewards starting from the next month");
    uint256 totalAmount = totalRewards[month] - amount;
    totalRewards[month] = totalAmount;
    rewardToken.transfer(msg.sender, amount);
  }
}
