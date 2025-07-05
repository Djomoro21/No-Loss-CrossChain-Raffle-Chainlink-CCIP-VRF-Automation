// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Receiver is CCIPReceiver, Ownable {
    using SafeERC20 for IERC20;

    error Receiver__NothingToWithdraw();
    error Receiver__NotAllowedForSourceChainOrSenderAddress(uint64 sourceChainSelector, address sender);
    error Receiver__FunctionCallFail();
    error Receiver__SenderNotSet();
    error Receiver__NotAllowedToCall();
    error NotEnoughBalance(uint256 balance, uint256 required);

    enum MessageType {
        ENTER_RAFFLE,
        WINNER_NOTIFICATION,
        RAFFLE_STATUS_UPDATE 
    }
    
    struct CrossChainMessage {
        MessageType messageType;
        bytes data;
    }

    IRouterClient private immutable i_routerClient;
    IERC20 private immutable i_LINK_TOKEN;
    uint64 private s_satelliteChainSelector;

    address private s_sender;
    address private s_mainRaffleContract;

    // Event emitted when a message is received from another chain.
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

    constructor(
        address _satelliteChainRouterClientAddress, 
        uint64 _satelliteChainSelector, 
        address _mainRaffleContract, 
        address _link
    ) CCIPReceiver(_satelliteChainRouterClientAddress) Ownable(msg.sender) {
        i_routerClient = IRouterClient(_satelliteChainRouterClientAddress);
        s_satelliteChainSelector = _satelliteChainSelector;
        s_mainRaffleContract = _mainRaffleContract;
        i_LINK_TOKEN = IERC20(_link);
    }

    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (s_sender == address(0)) {
            revert Receiver__SenderNotSet();
        }
        if (_sourceChainSelector != s_satelliteChainSelector || _sender != s_sender) {
            revert Receiver__NotAllowedForSourceChainOrSenderAddress(_sourceChainSelector, _sender);
        }
        _;
    }

    function setSender(address _sender) external onlyOwner {
        s_sender = _sender;
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    )
        internal
        override
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        )
    {
        (address target, bytes memory functionCallData) = abi.decode(any2EvmMessage.data, (address, bytes));
        (bool success, ) = target.call(functionCallData);

        if (!success) {
            revert Receiver__FunctionCallFail();
        }

        // FIXED: Added bounds checking for token amounts
        address token = address(0);
        uint256 tokenAmount = 0;
        
        if (any2EvmMessage.destTokenAmounts.length > 0) {
            token = any2EvmMessage.destTokenAmounts[0].token;
            tokenAmount = any2EvmMessage.destTokenAmounts[0].amount;
        }

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address)),
            any2EvmMessage.data,
            token,
            tokenAmount
        );
    }

    function updateSatelliteChainWithRaffleStatus(bool _raffleActive) external {
        if(msg.sender != s_mainRaffleContract){
            revert Receiver__NotAllowedToCall();
        }
        
        CrossChainMessage memory message = CrossChainMessage({
            messageType: MessageType.RAFFLE_STATUS_UPDATE,
            data: abi.encode(_raffleActive)
        });

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(s_sender),
            data: abi.encode(message),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({
                    gasLimit: 200_000,
                    allowOutOfOrderExecution: true
                })
            ),
            feeToken: address(i_LINK_TOKEN)
        });

        uint256 fees = i_routerClient.getFee(
            s_satelliteChainSelector,
            evm2AnyMessage
        );

        if (fees > i_LINK_TOKEN.balanceOf(address(this)))
            revert NotEnoughBalance(i_LINK_TOKEN.balanceOf(address(this)), fees);

        i_LINK_TOKEN.approve(address(i_routerClient), fees);

        // FIXED: Declare messageId variable
        bytes32 messageId = i_routerClient.ccipSend(s_satelliteChainSelector, evm2AnyMessage);

        // FIXED: Encode message struct to bytes
        emit MessageSent(
            messageId,
            s_satelliteChainSelector,
            s_sender,
            abi.encode(message),
            address(i_LINK_TOKEN),
            fees
        );
    }

    function withdrawToken(address _token) public onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        if (amount == 0) revert Receiver__NothingToWithdraw();
        IERC20(_token).safeTransfer(msg.sender, amount);
    }
}