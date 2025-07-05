// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";

interface IReceiverCCIP {
    // Enums
    enum MessageType {
        ENTER_RAFFLE,
        WINNER_NOTIFICATION,
        RAFFLE_STATUS_UPDATE 
    }
    
    // Structs
    struct CrossChainMessage {
        MessageType messageType;
        bytes data;
    }

    // Events
    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        bytes data,
        address token,
        uint256 tokenAmount
    );

    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        bytes data,
        address token,
        uint256 tokenAmount
    );

    // Errors
    error Receiver__NothingToWithdraw();
    error Receiver__NotAllowedForSourceChainOrSenderAddress(uint64 sourceChainSelector, address sender);
    error Receiver__FunctionCallFail();
    error Receiver__SenderNotSet();
    error Receiver__NotAllowedToCall();
    error NotEnoughBalance(uint256 balance, uint256 required);

    // Functions
    function setSender(address _sender) external;
    function withdrawToken(address _token) external;
    function updateSatelliteChainWithRaffleStatus(bool _raffleActive) external;
    
    // View functions (if any public state variables)
    function owner() external view returns (address);
} 