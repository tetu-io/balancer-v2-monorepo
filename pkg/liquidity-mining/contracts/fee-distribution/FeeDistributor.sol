// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-solidity-utils/contracts/helpers/IAuthentication.sol";
import "@balancer-labs/v2-solidity-utils/contracts/math/Math.sol";
import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/ReentrancyGuard.sol";
import "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/SafeERC20.sol";

import "../interfaces/IFeeDistributor.sol";
import "../interfaces/IVotingEscrow.sol";

// solhint-disable not-rely-on-time

/**
 * @title Fee Distributor
 * @notice Distributes any tokens transferred to the contract (e.g. Protocol fees and any BAL emissions) among veBAL
 * holders proportionally based on a snapshot of the week at which the tokens are sent to the FeeDistributor contract.
 * @dev Supports distributing arbitrarily many different tokens. In order to start distributing a new token to veBAL
 * holders simply transfer the tokens to the `FeeDistributor` contract and then call `checkpointToken`.
 */
contract FeeDistributor is IFeeDistributor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IVotingEscrow private immutable _votingEscrow;

    uint256 private immutable _startTime;

    // Global State
    uint256 private _timeCursor;
    mapping(uint256 => uint256) private _veSupplyCache;

    // Token State

    // `startTime` and `timeCursor` are both timestamps so comfortably fit in a uint64.
    // `cachedBalance` will comfortably fit the total supply of any meaningful token.
    // Should more than 2^128 tokens be sent to this contract then checkpointing this token will fail until enough
    // tokens have been claimed to bring the total balance back below 2^128.
    struct TokenState {
        uint64 startTime;
        uint64 timeCursor;
        uint128 cachedBalance;
    }
    mapping(IERC20 => TokenState) private _tokenState;
    mapping(IERC20 => mapping(uint256 => uint256)) private _tokensPerWeek;

    // User State

    // `startTime` and `timeCursor` are timestamps so will comfortably fit in a uint64.
    // For `lastEpochCheckpointed` to overflow would need over 2^128 transactions to the VotingEscrow contract.
    struct UserState {
        uint64 startTime;
        uint64 timeCursor;
        uint128 lastEpochCheckpointed;
    }
    mapping(address => UserState) private _userState;
    mapping(address => mapping(uint256 => uint256)) private _userBalanceAtTimestamp;
    mapping(address => mapping(IERC20 => uint256)) private _userTokenTimeCursor;

    constructor(IVotingEscrow votingEscrow, uint256 startTime) {
        _votingEscrow = votingEscrow;

        require(startTime >= _roundUpTimestamp(block.timestamp), "Must start after current week");
        startTime = _roundDownTimestamp(startTime);
        _startTime = startTime;
        _timeCursor = startTime;
    }

    /**
     * @notice Returns the VotingEscrow (veBAL) token contract
     */
    function getVotingEscrow() external view override returns (IVotingEscrow) {
        return _votingEscrow;
    }

    /**
     * @notice Returns the global time cursor representing the most earliest uncheckpointed week.
     */
    function getTimeCursor() external view override returns (uint256) {
        return _timeCursor;
    }

    /**
     * @notice Returns the user-level time cursor representing the most earliest uncheckpointed week.
     * @param user - The address of the user to query.
     */
    function getUserTimeCursor(address user) external view override returns (uint256) {
        return _userState[user].timeCursor;
    }

    /**
     * @notice Returns the token-level time cursor storing the timestamp at up to which tokens have been distributed.
     * @param token - The ERC20 token address to query.
     */
    function getTokenTimeCursor(IERC20 token) external view override returns (uint256) {
        return _tokenState[token].timeCursor;
    }

    /**
     * @notice Returns the user-level time cursor storing the timestamp of the latest token distribution claimed.
     * @param user - The address of the user to query.
     * @param token - The ERC20 token address to query.
     */
    function getUserTokenTimeCursor(address user, IERC20 token) external view override returns (uint256) {
        return _getUserTokenTimeCursor(user, token);
    }

    /**
     * @notice Returns the user's cached balance of veBAL as of the provided timestamp.
     * @dev Only timestamps which fall on Thursdays 00:00:00 UTC will return correct values.
     * This function requires `user` to have been checkpointed past `timestamp` so that their balance is cached.
     * @param user - The address of the user of which to read the cached balance of.
     * @param timestamp - The timestamp at which to read the `user`'s cached balance at.
     */
    function getUserBalanceAtTimestamp(address user, uint256 timestamp) external view override returns (uint256) {
        return _userBalanceAtTimestamp[user][timestamp];
    }

    /**
     * @notice Returns the cached total supply of veBAL as of the provided timestamp.
     * @dev Only timestamps which fall on Thursdays 00:00:00 UTC will return correct values.
     * This function requires the contract to have been checkpointed past `timestamp` so that the supply is cached.
     * @param timestamp - The timestamp at which to read the cached total supply at.
     */
    function getTotalSupplyAtTimestamp(uint256 timestamp) external view override returns (uint256) {
        return _veSupplyCache[timestamp];
    }

    /**
     * @notice Returns the FeeDistributor's cached balance of `token`.
     */
    function getTokenLastBalance(IERC20 token) external view override returns (uint256) {
        return _tokenState[token].cachedBalance;
    }

    // Checkpointing

    /**
     * @notice Caches the total supply of veBAL at the beginning of each week.
     * This function will be called automatically before claiming tokens to ensure the contract is properly updated.
     */
    function checkpoint() external override nonReentrant {
        _checkpointTotalSupply();
    }

    /**
     * @notice Caches the user's balance of veBAL at the beginning of each week.
     * This function will be called automatically before claiming tokens to ensure the contract is properly updated.
     * @param user - The address of the user to be checkpointed.
     */
    function checkpointUser(address user) external override nonReentrant {
        _checkpointUserBalance(user);
    }

    /**
     * @notice Assigns any newly-received tokens held by the FeeDistributor to weekly distributions.
     * @dev Any `token` balance held by the FeeDistributor above that which is returned by `getTokenLastBalance`
     * will be distributed evenly across the time period since `token` was last checkpointed.
     *
     * This function will be called automatically before claiming tokens to ensure the contract is properly updated.
     * @param token - The ERC20 token address to be checkpointed.
     */
    function checkpointToken(IERC20 token) external override nonReentrant {
        // Prevent someone from assigning tokens to an inaccessible week.
        require(block.timestamp > _startTime, "Fee distribution has not started yet");
        _checkpointToken(token, true);
    }

    /**
     * @notice Assigns any newly-received tokens held by the FeeDistributor to weekly distributions.
     * @dev A version of `checkpointToken` which supports checkpointing multiple tokens.
     * See `checkpointToken` for more details.
     * @param tokens - An array of ERC20 token addresses to be checkpointed.
     */
    function checkpointTokens(IERC20[] calldata tokens) external override nonReentrant {
        // Prevent someone from assigning tokens to an inaccessible week.
        require(block.timestamp > _startTime, "Fee distribution has not started yet");

        uint256 tokensLength = tokens.length;
        for (uint256 i = 0; i < tokensLength; ++i) {
            _checkpointToken(tokens[i], true);
        }
    }

    // Claiming

    /**
     * @notice Claims all pending distributions of the provided token for a user.
     * @dev It's not necessary to explicitly checkpoint before calling this function, it will ensure the FeeDistributor
     * is up to date before calculating the amount of tokens to be claimed.
     * @param user - The user on behalf of which to claim.
     * @param token - The ERC20 token address to be claimed.
     * @return The amount of `token` sent to `user` as a result of claiming.
     */
    function claimToken(address user, IERC20 token) external override nonReentrant returns (uint256) {
        // Prevent someone from assigning tokens to an inaccessible week.
        require(block.timestamp > _startTime, "Fee distribution has not started yet");
        _checkpointTotalSupply();
        _checkpointToken(token, false);
        _checkpointUserBalance(user);

        uint256 amount = _claimToken(user, token);
        return amount;
    }

    /**
     * @notice Claims a number of tokens on behalf of a user.
     * @dev A version of `claimToken` which supports claiming multiple `tokens` on behalf of `user`.
     * See `claimToken` for more details.
     * @param user - The user on behalf of which to claim.
     * @param tokens - An array of ERC20 token addresses to be claimed.
     * @return An array of the amounts of each token in `tokens` sent to `user` as a result of claiming.
     */
    function claimTokens(address user, IERC20[] calldata tokens)
        external
        override
        nonReentrant
        returns (uint256[] memory)
    {
        // Prevent someone from assigning tokens to an inaccessible week.
        require(block.timestamp > _startTime, "Fee distribution has not started yet");
        _checkpointTotalSupply();
        _checkpointUserBalance(user);

        uint256 tokensLength = tokens.length;
        uint256[] memory amounts = new uint256[](tokensLength);
        for (uint256 i = 0; i < tokensLength; ++i) {
            _checkpointToken(tokens[i], false);
            amounts[i] = _claimToken(user, tokens[i]);
        }

        return amounts;
    }

    // Internal functions

    /**
     * @dev It is required that both the global, token and user state have been properly checkpointed
     * before calling this function.
     */
    function _claimToken(address user, IERC20 token) internal returns (uint256) {
        TokenState storage tokenState = _tokenState[token];
        uint256 userTimeCursor = _getUserTokenTimeCursor(user, token);
        // We round `_tokenTimeCursor` down so it represents the beginning of the first incomplete week.
        uint256 currentActiveWeek = _roundDownTimestamp(tokenState.timeCursor);
        mapping(uint256 => uint256) storage tokensPerWeek = _tokensPerWeek[token];
        mapping(uint256 => uint256) storage userBalanceAtTimestamp = _userBalanceAtTimestamp[user];

        uint256 amount;
        for (uint256 i = 0; i < 20; ++i) {
            // We only want to claim for complete weeks so break once we reach `currentActiveWeek`.
            // This is as `tokensPerWeek[currentActiveWeek]` will continue to grow over the week.
            if (userTimeCursor >= currentActiveWeek) break;

            amount +=
                (tokensPerWeek[userTimeCursor] * userBalanceAtTimestamp[userTimeCursor]) /
                _veSupplyCache[userTimeCursor];
            userTimeCursor += 1 weeks;
        }
        // Update the stored user-token time cursor to prevent this user claiming this week again.
        _userTokenTimeCursor[user][token] = userTimeCursor;

        if (amount > 0) {
            tokenState.cachedBalance = uint128(tokenState.cachedBalance - amount);
            token.safeTransfer(user, amount);
            emit TokensClaimed(user, token, amount, userTimeCursor);
        }

        return amount;
    }

    /**
     * @dev Calculate the amount of `token` to be distributed to `_votingEscrow` holders since the last checkpoint.
     */
    function _checkpointToken(IERC20 token, bool force) internal {
        TokenState storage tokenState = _tokenState[token];
        uint256 lastTokenTime = tokenState.timeCursor;
        uint256 timeSinceLastCheckpoint;
        if (lastTokenTime == 0) {
            // If it's the first time we're checkpointing this token then start distributing from now.
            // Also mark at which timestamp users should start attempts to claim this token from.
            lastTokenTime = block.timestamp;
            tokenState.startTime = uint64(_roundDownTimestamp(block.timestamp));
        } else {
            timeSinceLastCheckpoint = block.timestamp - lastTokenTime;

            if (!force) {
                // Checkpointing N times within a single week is completely equivalent to checkpointing once at the end.
                // We then want to get as close as possible to a single checkpoint every Wed 23:59 UTC to save gas.

                // We then skip checkpointing if we're in the same week as the previous checkpoint.
                bool alreadyCheckpointedThisWeek = _roundDownTimestamp(block.timestamp) ==
                    _roundDownTimestamp(lastTokenTime);
                // However we want to ensure that all of this week's fees are assigned to the current week without
                // overspilling into the next week. To mitigate this, we checkpoint if we're near the end of the week.
                bool nearingEndOfWeek = _roundUpTimestamp(block.timestamp) - block.timestamp < 1 days;

                // This ensures that we checkpoint once at the beginning of the week and again for each user interaction
                // towards the end of the week to give an accurate final reading of the balance.
                if (alreadyCheckpointedThisWeek && !nearingEndOfWeek) {
                    return;
                }
            }
        }

        tokenState.timeCursor = uint64(block.timestamp);

        uint256 tokenBalance = token.balanceOf(address(this));
        uint256 tokensToDistribute = tokenBalance - tokenState.cachedBalance;
        if (tokensToDistribute == 0) return;
        require(tokenBalance <= type(uint128).max, "Maximum token balance exceeded");
        tokenState.cachedBalance = uint128(tokenBalance);

        uint256 thisWeek = _roundDownTimestamp(lastTokenTime);
        uint256 nextWeek = 0;

        // Distribute `tokensToDistribute` evenly across the time period from `lastTokenTime` to now.
        // These tokens are assigned to weeks proportionally to how much of this period falls into each week.
        mapping(uint256 => uint256) storage tokensPerWeek = _tokensPerWeek[token];
        for (uint256 i = 0; i < 20; ++i) {
            nextWeek = thisWeek + 1 weeks;
            if (block.timestamp < nextWeek) {
                // `thisWeek` is now the beginning of the current week, i.e. this is the final iteration.
                if (timeSinceLastCheckpoint == 0 && block.timestamp == lastTokenTime) {
                    tokensPerWeek[thisWeek] += tokensToDistribute;
                } else {
                    tokensPerWeek[thisWeek] +=
                        (tokensToDistribute * (block.timestamp - lastTokenTime)) /
                        timeSinceLastCheckpoint;
                }
                // As we've caught up to the present then we should now break
                break;
            } else {
                // We've gone a full week or more without checkpointing so need to distribute tokens to previous weeks
                if (timeSinceLastCheckpoint == 0 && nextWeek == lastTokenTime) {
                    // It shouldn't be possible to enter this block
                    tokensPerWeek[thisWeek] += tokensToDistribute;
                } else {
                    tokensPerWeek[thisWeek] +=
                        (tokensToDistribute * (nextWeek - lastTokenTime)) /
                        timeSinceLastCheckpoint;
                }
            }

            // We've now "checkpointed" up to the beginning of next week so must update timestamps appropriately.
            lastTokenTime = nextWeek;
            thisWeek = nextWeek;
        }

        emit TokenCheckpointed(token, tokensToDistribute, lastTokenTime);
    }

    /**
     * @dev Cache the `user`'s balance of `_votingEscrow` at the beginning of each new week
     */
    function _checkpointUserBalance(address user) internal {
        // Minimal user_epoch is 0 (if user had no point)
        uint256 userEpoch = 0;
        uint256 maxUserEpoch = _votingEscrow.user_point_epoch(user);

        // If user has never locked then they won't receive fees
        if (maxUserEpoch == 0) return;

        UserState storage userState = _userState[user];

        // weekCursor represents the timestamp of the beginning of the week from which we
        // start checkpointing the user's VotingEscrow balance.
        uint256 weekCursor = userState.timeCursor;
        if (weekCursor == 0) {
            // First checkpoint for user so need to do the initial binary search
            userEpoch = _findTimestampUserEpoch(user, _startTime, maxUserEpoch);
        } else {
            if (weekCursor == _roundDownTimestamp(block.timestamp)) {
                // User has checkpointed this week already so perform early return
                return;
            }
            // Otherwise use the value saved from last time
            userEpoch = userState.lastEpochCheckpointed;
        }

        // Epoch 0 is always empty so bump onto the next one so that we start on a valid epoch.
        if (userEpoch == 0) {
            userEpoch = 1;
        }

        IVotingEscrow.Point memory userPoint = _votingEscrow.user_point_history(user, userEpoch);

        // If this is the first checkpoint for the user, calculate the first week they're eligible for.
        // i.e. the timestamp of the first Thursday after they locked.
        if (weekCursor == 0) {
            weekCursor = _roundUpTimestamp(userPoint.ts);
            userState.startTime = uint64(weekCursor);
        }

        // Sanity check - can't claim fees from before fee distribution started.
        if (weekCursor < _startTime) {
            weekCursor = _startTime;
        }

        IVotingEscrow.Point memory oldUserPoint;
        for (uint256 i = 0; i < 50; ++i) {
            // Break if we're trying to cache the user's balance at a timestamp in the future
            if (weekCursor > block.timestamp) {
                break;
            }

            if (weekCursor >= userPoint.ts && userEpoch <= maxUserEpoch) {
                // The week being considered is contained in an epoch after the user epoch described by `oldUserPoint`.
                // We then shift `userPoint` into `oldUserPoint` and query the Point for the next user epoch.
                // We do this in order to step though epochs until we find the last epoch starting before `weekCursor`.
                userEpoch += 1;
                oldUserPoint = userPoint;
                if (userEpoch > maxUserEpoch) {
                    userPoint = IVotingEscrow.Point(0, 0, 0, 0);
                } else {
                    userPoint = _votingEscrow.user_point_history(user, userEpoch);
                }
            } else {
                // The week being considered lies inside the user epoch described by `oldUserPoint`
                // we can then use it to calculate the user's balance at the beginning of the week.

                int128 dt = int128(weekCursor - oldUserPoint.ts);
                uint256 userBalance = oldUserPoint.bias > oldUserPoint.slope * dt
                    ? uint256(oldUserPoint.bias - oldUserPoint.slope * dt)
                    : 0;

                // User's lock has expired and they haven't relocked yet.
                if (userBalance == 0 && userEpoch > maxUserEpoch) break;

                // User had a nonzero lock and so is eligible to collect fees.
                _userBalanceAtTimestamp[user][weekCursor] = userBalance;

                weekCursor += 1 weeks;
            }
        }

        userState.lastEpochCheckpointed = uint64(userEpoch - 1);
        userState.timeCursor = uint64(weekCursor);
    }

    /**
     * @dev Cache the totalSupply of VotingEscrow token at the beginning of each new week
     */
    function _checkpointTotalSupply() internal {
        uint256 timeCursor = _timeCursor;
        uint256 weekStart = _roundDownTimestamp(block.timestamp);

        // We expect `timeCursor == weekStart + 1 weeks` when fully up to date.
        if (timeCursor > weekStart) {
            // We've already checkpointed up to this week so perform early return
            return;
        }

        _votingEscrow.checkpoint();

        // Step through the each week and cache the total supply at beginning of week on this contract
        for (uint256 i = 0; i < 20; ++i) {
            if (timeCursor > weekStart) break;

            _veSupplyCache[timeCursor] = _votingEscrow.totalSupply(timeCursor);

            timeCursor += 1 weeks;
        }
        // Update state to the end of the current week (`weekStart` + 1 weeks)
        _timeCursor = timeCursor;
    }

    // Helper functions

    /**
     * @dev Wrapper around `_userTokenTimeCursor` which returns the start timestamp for `token`
     * if `user` has not attempted to interact with it previously.
     */
    function _getUserTokenTimeCursor(address user, IERC20 token) internal view returns (uint256) {
        uint256 userTimeCursor = _userTokenTimeCursor[user][token];
        if (userTimeCursor > 0) return userTimeCursor;
        // This is the first time that the user has interacted with this token.
        // We then start from the latest out of either when `user` first locked veBAL or `token` was first checkpointed.
        return Math.max(_userState[user].startTime, _tokenState[token].startTime);
    }

    /**
     * @dev Return the user epoch number for `user` corresponding to the provided `timestamp`
     */
    function _findTimestampUserEpoch(
        address user,
        uint256 timestamp,
        uint256 maxUserEpoch
    ) internal view returns (uint256) {
        uint256 min = 0;
        uint256 max = maxUserEpoch;

        // Perform binary search through epochs to find epoch containing `timestamp`
        for (uint256 i = 0; i < 128; ++i) {
            if (min >= max) break;

            // +2 avoids getting stuck in min == mid < max
            uint256 mid = (min + max + 2) / 2;
            IVotingEscrow.Point memory pt = _votingEscrow.user_point_history(user, mid);
            if (pt.ts <= timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return min;
    }

    /**
     * @dev Rounds the provided timestamp down to the beginning of the previous week (Thurs 00:00 UTC)
     */
    function _roundDownTimestamp(uint256 timestamp) private pure returns (uint256) {
        return (timestamp / 1 weeks) * 1 weeks;
    }

    /**
     * @dev Rounds the provided timestamp up to the beginning of the next week (Thurs 00:00 UTC)
     */
    function _roundUpTimestamp(uint256 timestamp) private pure returns (uint256) {
        return _roundDownTimestamp(timestamp + 1 weeks - 1);
    }
}
