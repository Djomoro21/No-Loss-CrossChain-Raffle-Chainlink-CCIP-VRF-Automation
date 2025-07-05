//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol"; 
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {ConfirmedOwnerWithProposal} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwnerWithProposal.sol";
import {IReceiverCCIP} from "./interfaces/IReceiverCCIP.sol";

/*@author:Djomoro
*Host Create a raffle. Raffle has a duration for players to enter, an entry price a max number of rounds.
*Player enter the raffle by buying tickets(minimum 1). Ticket are bought with STABLE
*After the duration, Deposits are sent to Aave to genreate yield for a certain period. Then the accured yield
*is shared between player and host address 
*Each ticket bought is an entry and stored is an array. Winner is selected randomly
*
*/
contract Raffle is Ownable, VRFConsumerBaseV2Plus, AutomationCompatibleInterface{
    using SafeERC20 for IERC20;

    error Raffle__InsufficientAmountOfTicket(uint256 nbTickets,string reason);
    error Raffle__InsufficientBalance(IERC20 token, uint256 currentBalance, uint256 totalTicketsCost, string reason);
    // Additional error declarations needed at the top of the contract
    error Raffle__StillOpen(RaffleStatut raffleStatut);
    error Raffle__InvalidTicketPrice(uint256 ticketPrice, string reason);
    error Raffle__InvalidMaxRounds(uint256 maxRounds, string reason);
    error Raffle__InvalidInterval(uint256 interval, string reason);
    error Raffle__InvalidTokenAddress(address tokenAddress, string reason);
    error Raffle__IsNotOpen(RaffleStatut raffleStatut);
    error Raffle__NotAllowedToCall();
    error Raffle__MaxRoundsReached();
    error HostPayoutFailed();
    error Raffle__NoUpKeepNeeded();
    error WinnerPayoutFailed();
    error FallBack();
    

    enum RaffleStatut{
        OPEN,
        PAUSE,
        CALCULATING_WINNER
    }
    struct Winner{
        address winnerAddress;
        uint256 nbTicketOwned;
        uint256 payout;
    }
    //Duration
    uint256 private s_interval;
    uint256 private s_lastTimeStamp;
    uint256 private s_remainingTimeBeforePause;
    //Ticket Price
    uint256 private s_ticketPrice;
    IERC20 private s_paymentToken;
    //Round
    uint256 private s_maxRounds;
    uint256 private s_currentRound;
    address[] private s_PlayersInTheRound;
    mapping(uint256 round => address[] player) private s_roundToPlayersList;
    mapping(uint256 round => Winner roundWinner) private s_roundWinner;
    //Player
    uint256 private s_playerID;
    mapping(uint256 playerID => address player) private s_IDtoPlayer;
    mapping(address player => uint256 playerID) private s_playerToID;
    mapping(address playerAddress => uint256 nbTicket) private s_playerToTicket;
    //Raffle
    uint256[] private s_raffleEntries;
    RaffleStatut private s_raffleStatut;
    //VRF
    bytes32 private immutable i_keyhash;
    uint256 private immutable i_subscriptionID;
    uint16 private constant REQUEST_CONFIRMATION = 3;
    uint32 private constant NUM_WORDS = 1;
    uint32 private immutable i_callbackGasLimit;


    bool private s_transfered;
    bool private s_withdrawn;
    uint256 private s_interval_accrual;

    mapping(address sender => bool allowed) private s_allowedSender;
    address[] private s_allowedSenderList;

    event RaffleEntriesUpdated(address player, uint256 nbTickets);
    event RaffleNewPlayerEntered(address player, uint256 nbTickets);
    event RafflePriceUpdated(uint256 oldPrice, uint256 newPrice);
    event RaffleMaxRoundUpdated(uint256 oldMaxRounds, uint256 newMaxRounds);
    event RafflePaymentTokenUpdated(IERC20 oldToken, IERC20 newToken);
    event RaffleIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event RaffleWinnerPicked(address winner, uint256 winnerShare);
    
    modifier onlyOwner() override(Ownable, ConfirmedOwnerWithProposal) {
        _checkOwner();
        _;
    }
    modifier onlyAllowListed(){
        if(!s_allowedSender[msg.sender]){
            revert Raffle__NotAllowedToCall();
        }
        _;
    }

    constructor(
            address _owner/*, uint256 _interval, uint256 _ticketPrice, uint256 _maxRounds, address _paymentToken, uint256 _interval_accrual*/,
            uint256 _subscriptionID,
            bytes32 gaslane,
            uint32 _callbackGasLimit,
            address _vrfCoordinator
        )
        Ownable(_owner == address(0) ? msg.sender : _owner)
        VRFConsumerBaseV2Plus(_vrfCoordinator){
        s_interval = 600; 
        s_lastTimeStamp = block.timestamp;
        s_ticketPrice = 0.01 ether;
        s_maxRounds = 3;
        s_paymentToken = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
        s_currentRound = 0;
        s_playerID = 0;
        s_raffleStatut = RaffleStatut.OPEN;
        s_transfered = false;
        s_withdrawn = false;
        i_keyhash = gaslane;
        i_subscriptionID = _subscriptionID;
        i_callbackGasLimit = _callbackGasLimit;
    }

    function enterRaffle(uint256 _nbTickets)public{
        if(s_raffleStatut != RaffleStatut.OPEN){
            revert Raffle__IsNotOpen(s_raffleStatut);
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

        if(s_playerToID[msg.sender] == 0) { /*New Player*/
            s_playerID ++;
            s_IDtoPlayer[s_playerID] = msg.sender;
            s_playerToID[msg.sender] = s_playerID;
            s_playerToTicket[msg.sender] = _nbTickets;
            s_PlayersInTheRound.push(msg.sender);

            for(uint256 i = 0 ; i<_nbTickets ; i++){
                s_raffleEntries.push(s_playerID);
            }
            emit RaffleNewPlayerEntered(msg.sender, _nbTickets);
        }else{/*Existing Player*/
            s_playerToTicket[msg.sender] += _nbTickets;
             for(uint256 i = 0 ; i<_nbTickets ; i++){
                s_raffleEntries.push(s_playerToID[msg.sender]);
            }
            emit RaffleEntriesUpdated(msg.sender, _nbTickets);
        }
    }
    function enterRaffleCrossChain(address _player,  uint256 _nbTickets, uint256 _totalCost) external onlyAllowListed{
        if(s_raffleStatut != RaffleStatut.OPEN){
            revert Raffle__IsNotOpen(s_raffleStatut);
        }
        s_paymentToken.safeTransferFrom(msg.sender,address(this),_totalCost);

        if(s_playerToID[_player] == 0) { /*New Player*/
            s_playerID ++;
            s_IDtoPlayer[s_playerID] = _player;
            s_playerToID[_player] = s_playerID;
            s_playerToTicket[_player] = _nbTickets;
            s_PlayersInTheRound.push(_player);

            for(uint256 i = 0 ; i<_nbTickets ; i++){
                s_raffleEntries.push(s_playerID);
            }
            emit RaffleNewPlayerEntered(_player, _nbTickets);
        }else{/*Existing Player*/
            s_playerToTicket[_player] += _nbTickets;
             for(uint256 i = 0 ; i<_nbTickets ; i++){
                s_raffleEntries.push(s_playerToID[_player]);
            }
            emit RaffleEntriesUpdated(_player, _nbTickets);
        }
    }
    //If funds have not still been transfered and raffle duration is over and Raffle is open we need to perform an upkeep
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
       if(!s_transfered){
        bool isOpen = s_raffleStatut == RaffleStatut.OPEN;
        bool isRoundOver =  block.timestamp - s_lastTimeStamp >= s_interval; 
        upkeepNeeded = isOpen && isRoundOver;
       }
       if(!s_withdrawn){
        bool isTransfered = s_transfered;
        bool isAccrualOver =  block.timestamp - s_lastTimeStamp >= s_interval_accrual; 
        upkeepNeeded = isTransfered && isAccrualOver;
       }
    }
    //If has Balance so call the function to transfer to aave, else move to next Round
    function performUpkeep(bytes calldata /* performData */) external override {
        bool hasBalance = s_paymentToken.balanceOf(address(this)) > 0;
        if(!hasBalance && !s_transfered){
            s_roundToPlayersList[s_currentRound] = s_PlayersInTheRound;
            nextRound();
        } else if(hasBalance && !s_transfered){
            transferFunds();
        }else if(!s_withdrawn && s_transfered){
            withdrawFunds();
        }
    }
    function nextRound() internal{ 
        if(s_currentRound > s_maxRounds){
            revert Raffle__MaxRoundsReached();
        }
        s_raffleEntries = new uint256[](0);
        s_PlayersInTheRound = new address[](0);
        s_transfered = false;
        s_withdrawn= false;
        s_lastTimeStamp = block.timestamp;
        s_currentRound++;
        s_raffleStatut = RaffleStatut.OPEN;
    }
    function transferFunds() internal{
        s_transfered = true;
        s_lastTimeStamp = block.timestamp;
    }
    function withdrawFunds() internal{
        s_withdrawn =true;
        pickWinner();
    }
    function pickWinner() internal{
        s_raffleStatut =  RaffleStatut.CALCULATING_WINNER;
        VRFV2PlusClient.RandomWordsRequest memory request = VRFV2PlusClient.RandomWordsRequest({
            keyHash: i_keyhash,
            subId: i_subscriptionID,
            requestConfirmations: REQUEST_CONFIRMATION,
            callbackGasLimit: i_callbackGasLimit,
            numWords: NUM_WORDS,
            extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
        });
        uint256 requestId = s_vrfCoordinator.requestRandomWords(request);

    }

    function fulfillRandomWords(uint256 requestId, /*requestId*/ uint256[] calldata randomWords) internal override {
        uint256 indexOfWinner = randomWords[0] % s_raffleEntries.length;
        uint256 winnerID = s_raffleEntries[indexOfWinner];
        address winner = s_IDtoPlayer[winnerID];

        uint256 winnerShare = (address(this).balance * 95) / 100;
        s_roundWinner[s_currentRound] = Winner(winner, s_playerToTicket[winner], winnerShare);
        uint256 hostShare = (address(this).balance * 5) / 100;
        (bool winnerPayoutSuccess,) = payable(winner).call{value: winnerShare}("");
        if(!winnerPayoutSuccess) { revert WinnerPayoutFailed(); }
        (bool hostPayoutSuccess,) = payable(owner()).call{value: hostShare}("");
        if(!hostPayoutSuccess) { revert HostPayoutFailed(); }
        emit RaffleWinnerPicked(winner, winnerShare);
        nextRound();

    }
    function pauseRaffle() public onlyOwner{
        if(s_raffleStatut != RaffleStatut.OPEN){
            revert Raffle__IsNotOpen(s_raffleStatut);
        }
    
        s_raffleStatut = RaffleStatut.PAUSE;
        
        // Calculate remaining time when paused
        uint256 elapsedTime = block.timestamp - s_lastTimeStamp;
        if (elapsedTime < s_interval) {
            s_remainingTimeBeforePause = s_interval - elapsedTime; // Store remaining time
        } else {
            s_remainingTimeBeforePause = 0; // Round should have ended
        }
    }
    function resumeRaffle() public onlyOwner{
        if(s_raffleStatut != RaffleStatut.PAUSE){
            revert Raffle__StillOpen(s_raffleStatut);
        }
    
        // Reset timestamp so remaining time is preserved
        s_lastTimeStamp = block.timestamp - (s_interval - s_remainingTimeBeforePause);
        
        s_raffleStatut = RaffleStatut.OPEN;
    }

    function updateRaffleStatusToSatelliteChain() public onlyOwner{
        bool s_raffleActive = (s_raffleStatut == RaffleStatut.OPEN);
    
        for(uint256 i = 0; i < s_allowedSenderList.length; i++) {
            // Cast the address to IReceiverCCIP interface and call the function
            IReceiverCCIP(s_allowedSenderList[i]).updateSatelliteChainWithRaffleStatus(s_raffleActive);
        }
    }
    //Getters
    function getCurrentRound() public view returns (uint256){return s_currentRound;}
    function getMaxRounds() public view returns(uint256)  {return s_maxRounds;}
    function getPaymentToken() public view returns (IERC20)  {return s_paymentToken;}
    function getPlayersListInTheRound(uint256 _round) public view returns (address[] memory){return s_roundToPlayersList[_round];}
    function getRaffleEntries() public view returns (uint256[] memory)  {return s_raffleEntries;}
    function getPlayerToTicket(address _player) public view returns (uint256){return s_playerToTicket[_player];}
    function getRaffleStatut() public view returns (RaffleStatut)  {return s_raffleStatut;}
    function getPlayerIDByAddress(address _player) public view returns (uint256){return s_playerToID[_player];}
    function getPlayerByID(uint256 _id) public view returns (address){return s_IDtoPlayer[_id];}
    function getCurrentPlayerID() public view returns(uint256){return s_playerID;}
    function getInterval() public view returns (uint256)  {return s_interval; }
    function getPaymentTokenBalance() public  view returns(IERC20,uint256){return (s_paymentToken, s_paymentToken.balanceOf(address(this)));}
    //Setters
    function setAllowedSender(address _sender) public onlyOwner{
        s_allowedSender[_sender] = true;
        s_allowedSenderList.push(_sender);
    }
   function updateTicketPrice(uint256 _ticketPrice) public onlyOwner {
        if(s_raffleStatut == RaffleStatut.OPEN){
            revert Raffle__StillOpen(s_raffleStatut);
        }
        
        // Input validation
        if(_ticketPrice == 0){
            revert Raffle__InvalidTicketPrice(_ticketPrice, "Ticket price cannot be zero");
        }
        
        uint256 oldValue = s_ticketPrice;
        s_ticketPrice = _ticketPrice; 
        emit RafflePriceUpdated(oldValue, s_ticketPrice);
    }

    function updateMaxRounds(uint256 _maxRound) public onlyOwner {
        if(s_raffleStatut == RaffleStatut.OPEN){
            revert Raffle__StillOpen(s_raffleStatut);
        }
        
        // Input validation
        if(_maxRound == 0){
            revert Raffle__InvalidMaxRounds(_maxRound, "Max rounds cannot be zero");
        }
        
        uint256 oldValue = s_maxRounds;
        s_maxRounds = _maxRound;
        emit RaffleMaxRoundUpdated(oldValue, s_maxRounds);
    }

    function updatePaymentToken(address _token) public onlyOwner {
        if(s_raffleStatut == RaffleStatut.OPEN){
            revert Raffle__StillOpen(s_raffleStatut);
        }
        
        // Input validation
        if(_token == address(0)){
            revert Raffle__InvalidTokenAddress(_token, "Token address cannot be zero");
        }
        
        IERC20 oldToken = s_paymentToken;
        s_paymentToken = IERC20(_token);
        emit RafflePaymentTokenUpdated(oldToken, s_paymentToken);
    }

    function updateInterval(uint256 _interval) public onlyOwner {
        // Input validation
        if(_interval == 0){
            revert Raffle__InvalidInterval(_interval, "Interval cannot be zero");
        }
        
        uint256 oldValue = s_interval;
        s_interval = _interval; 
        emit RaffleIntervalUpdated(oldValue, s_interval);
    }
    // Override conflicting functions from base contracts
    function owner() public view override(Ownable, ConfirmedOwnerWithProposal) returns (address) {
        return Ownable.owner();
    }

    function transferOwnership(address newOwner) public override(Ownable, ConfirmedOwnerWithProposal) onlyOwner {
        Ownable.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, ConfirmedOwnerWithProposal) {
        Ownable._transferOwnership(newOwner);
    }

    receive() external payable { revert FallBack(); }
    fallback() external payable { revert FallBack(); }
}