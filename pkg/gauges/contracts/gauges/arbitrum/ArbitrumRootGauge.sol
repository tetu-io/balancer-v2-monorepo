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

import "../PremintedGauge.sol";

interface IGatewayRouter {
    function outboundTransfer(
        IERC20 token,
        address recipient,
        uint256 amount,
        uint256 gasLimit,
        uint256 gasPrice,
        bytes calldata data
    ) external payable;

    function getGateway(address token) external view returns (address gateway);
}

contract ArbitrumRootGauge is PremintedGauge {
    address private immutable _gateway;
    IGatewayRouter private immutable _gatewayRouter;

    uint256 private _gasLimit;
    uint256 private _gasPrice;
    uint256 private _maxSubmissionCost;

    address private immutable _recipient = address(this);

    event ArbitrumFeesModified(uint256 gasLimit, uint256 gasPrice, uint256 maxSubmissionCost);

    constructor(
        IBalancerMinter minter,
        IGatewayRouter gatewayRouter,
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 maxSubmissionCost
    ) PremintedGauge(minter) {
        _gateway = gatewayRouter.getGateway(address(minter.getBalancerToken()));
        _gatewayRouter = gatewayRouter;

        _gasLimit = gasLimit;
        _gasPrice = gasPrice;
        _maxSubmissionCost = maxSubmissionCost;
    }

    function _postMintAction(uint256 mintAmount) internal override {
        // Token needs to be approved on the gateway NOT the gateway router
        _balToken.approve(_gateway, mintAmount);

        uint256 gasLimit = _gasLimit;
        uint256 gasPrice = _gasPrice;
        uint256 maxSubmissionCost = _maxSubmissionCost;
        uint256 totalBridgeCost = _getTotalBridgeCost(gasLimit, gasPrice, maxSubmissionCost);
        require(msg.value == totalBridgeCost, "Incorrect msg.value passed");

        // After bridging, the BAL should arrive on Arbitrum within 10 minutes. If it
        // does not, the L2 transaction may have failed due to an insufficient amount
        // within `max_submission_cost + (gas_limit * gas_price)`
        // In this case, the transaction can be manually broadcasted on Arbitrum by calling
        // `ArbRetryableTicket(0x000000000000000000000000000000000000006e).redeem(redemption-TxID)`
        // The calldata for this manual transaction is easily obtained by finding the reverted
        // transaction in the tx history for 0x000000000000000000000000000000000000006e on Arbiscan.
        // https://developer.offchainlabs.com/docs/l1_l2_messages#retryable-transaction-lifecycle
        _gatewayRouter.outboundTransfer{ value: totalBridgeCost }(
            _balToken,
            _recipient,
            mintAmount,
            gasLimit,
            gasPrice,
            abi.encode(maxSubmissionCost)
        );
    }

    function getTotalBridgeCost() external view returns (uint256) {
        return _getTotalBridgeCost(_gasLimit, _gasPrice, _maxSubmissionCost);
    }

    function _getTotalBridgeCost(
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 maxSubmissionCost
    ) internal pure returns (uint256) {
        return gasLimit * gasPrice + maxSubmissionCost;
    }

    /**
     * @notice Set the fees for the Arbitrum side of the bridging transaction
     */
    function setArbitrumFees(
        uint256 gasLimit,
        uint256 gasPrice,
        uint256 maxSubmissionCost
    ) external {
        // TODO: Authenticate

        _gasLimit = gasLimit;
        _gasPrice = gasPrice;
        _maxSubmissionCost = maxSubmissionCost;
        emit ArbitrumFeesModified(gasLimit, gasPrice, maxSubmissionCost);
    }
}
