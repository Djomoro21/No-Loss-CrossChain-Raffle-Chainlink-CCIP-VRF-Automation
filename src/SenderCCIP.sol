// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRaffle} from "./interfaces/IRaffle.sol";

contract SenderCCIP is Ownable {
    using SafeERC20 for IERC20;
    
    error CCIPTokenSender__InsufficientBalance(IERC20 USDC_TOKEN, uint256 _userBalance, uint256 _amount);
    error Raffle__InsufficientAmountOfTicket(uint256 _nbTickets, string reason);
    error  Raffle__InsufficientBalance(
                IERC20 s_paymentToken,
                uint256 currentBalance,
                uint256 ticketsCost,
                string reason
            );

    IRouterClient private immutable i_routerClient;
    IERC20 private immutable s_paymentToken;
    IERC20 private immutable i_LINK_TOKEN;
    uint64 private immutable i_main_chain_selector;
    uint256 private s_ticketPrice;

    address private s_receiverContract;
    address private s_targetRaffleContract;

    event EntrySentCrossChain(uint256 _nbTickets,address _player , bytes32 messageID);

    constructor(address _routerClient, address _usdc, address _link, uint64 _main_chain_selector ) Ownable(msg.sender){
        i_routerClient = IRouterClient(_routerClient);
        s_paymentToken=IERC20(_usdc);
        i_LINK_TOKEN=IERC20(_link); 
        i_main_chain_selector=_main_chain_selector;
    }
    
    function enterRaffle(uint256 _nbTickets) public{
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
        bytes memory functionCallData = abi.encodeWithSelector(IRaffle.enterRaffleCrossChain.selector,_nbTickets , _player );
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

    function withdraw(address _beneficiary, address token) public onlyOwner{
        IERC20 erc20 = IERC20(token);
        erc20.safeTransferFrom(address(this),_beneficiary,address(this).balance);
    }
}