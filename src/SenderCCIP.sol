// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRaffle} from "./interfaces/IRaffle.sol";

contract SenderCCIP is Ownable, CCIPReceiver{
    using SafeERC20 for IERC20;

    enum MessageType {
    ENTER_RAFFLE,
    WINNER_NOTIFICATION,
    RAFFLE_STATUS_UPDATE 
    }

    struct CrossChainMessage {
        MessageType messageType;
        bytes data;
    }
    
    error CCIPTokenSender__InsufficientBalance(IERC20 USDC_TOKEN, uint256 _userBalance, uint256 _amount);
    error Raffle__InsufficientAmountOfTicket(uint256 _nbTickets, string reason);
    error  Raffle__InsufficientBalance(
                IERC20 s_paymentToken,
                uint256 currentBalance,
                uint256 ticketsCost,
                string reason
            );
    error Raffle__RaffleNotActive();

    
    IRouterClient private immutable i_routerClient;
    IERC20 private immutable s_paymentToken;
    IERC20 private immutable i_LINK_TOKEN;
    uint64 private immutable i_main_chain_selector;


    uint256 private s_ticketPrice;

    address private s_receiverContract;
    address private s_targetRaffleContract;

    address private s_sender;
    bool private raffleActive;

    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (s_sender == address(0)) {
            revert Receiver__SenderNotSet();
        }
        if (_sourceChainSelector != i_main_chain_selector || _sender != s_sender) {
            revert Receiver__NotAllowedForSourceChainOrSenderAddress(_sourceChainSelector, _sender);
        }
        _;
    }

    event EntrySentCrossChain(uint256 _nbTickets,address _player , bytes32 messageID);
    event RaffleStatusUpdated(bool newStatus);

    constructor(address _routerClientAddressMainChain, address _usdc, address _link, uint64 _main_chain_selector ) Ownable(msg.sender) CCIPReceiver(_routerClientAddressMainChain){
        i_routerClient = IRouterClient(_routerClientAddressMainChain);
        s_paymentToken=IERC20(_usdc);
        i_LINK_TOKEN=IERC20(_link); 
        i_main_chain_selector=_main_chain_selector;
    }
    
    function enterRaffle(uint256 _nbTickets) public{
        if(!raffleActive){
            revert Raffle__RaffleNotActive();
        }
        if(_nbTickets<1){
            revert Raffle__InsufficientAmountOfTicket(_nbTickets,"Minimum 1 ticket");
        }
        uint256 ticketsCost = _nbTickets * s_ticketPrice;
        if(s_paymentToken.balanceOf(msg.sender)<ticketsCost){
            revert Raffle__InsufficientBalance(
                s_paymentToken,
                s_paymentToken.balanceOf(msg.sender),
                ticketsCost,
                "Insufficient balance for the amount of ticket bought"
            );
        }
        s_paymentToken.safeTransferFrom(msg.sender,address(this),ticketsCost);
        bytes32 messageID = sendEntryCrossChain(_nbTickets,msg.sender, ticketsCost);
        emit EntrySentCrossChain(_nbTickets,msg.sender,messageID);
    }

    function sendEntryCrossChain(uint256 _nbTickets,address _player, uint256 _totalCost)internal returns (bytes32 messageID){
        bytes memory functionCallData = abi.encodeWithSelector(IRaffle.enterRaffleCrossChain.selector,_nbTickets , _player, _totalCost );
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0]= Client.EVMTokenAmount({token:address(s_paymentToken), amount: _totalCost});

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(s_receiverContract),
            data: abi.encode(s_targetRaffleContract,functionCallData),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300000})
            ),
            feeToken: address(i_LINK_TOKEN)
        });

        uint256 ccipFees = i_routerClient.getFee(i_main_chain_selector,message);
        if(ccipFees> i_LINK_TOKEN.balanceOf(address(this))){
            revert CCIPTokenSender__InsufficientBalance(i_LINK_TOKEN, i_LINK_TOKEN.balanceOf(address(this)), ccipFees);
        }
        i_LINK_TOKEN.approve(address(i_routerClient), ccipFees);
        s_paymentToken.approve(address(i_routerClient), _totalCost);
        messageID = i_routerClient.ccipSend(i_main_chain_selector, message);
    }

    // Receive the message from the main chain to update the raffle status
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override 
      onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        )
    {
       CrossChainMessage memory message = abi.decode(any2EvmMessage.data, (CrossChainMessage));

       if (message.messageType == MessageType.RAFFLE_STATUS_UPDATE) {
            bool newStatus = abi.decode(message.data, (bool));
            raffleActive = newStatus;
            emit RaffleStatusUpdated(newStatus);
        }
    }

    // Set the sender contract allowed to receive messages from 
    function setSender(address _sender) external onlyOwner {
        // set the sender contract allowed to receive messages from 
        s_sender = _sender;
    }

    // Withdraw the balance of the contract
    function withdraw(address _beneficiary, address token) public onlyOwner{
        IERC20 erc20 = IERC20(token);
        erc20.safeTransferFrom(address(this),_beneficiary,address(this).balance);
    }
}