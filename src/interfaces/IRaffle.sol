//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRaffle {
     /**
     * @notice Enter raffle on behalf of another player (cross-chain functionality)
     * @param _player Address of the player entering the raffle
     * @param _nbTickets Number of tickets to purchase for the player
     * @dev Only callable by allowed sender, requires raffle to be OPEN
     */
    function enterRaffleCrossChain(address _player, uint256 _nbTickets) external;
}