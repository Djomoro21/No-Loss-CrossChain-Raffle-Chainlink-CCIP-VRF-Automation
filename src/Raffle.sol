//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

import {PriceConverter} from "./PriceConverter.sol";

/**
 * @title Asimple Raffle contract
 * @author Djomoro
 * @notice This contract is for creating a sample raffle
 * @dev Implements Chainlink VRFv2.5
 */
contract Raffle is VRFConsumerBaseV2Plus, AutomationCompatibleInterface{
    using PriceConverter for uint256;
    /*Errors */
    error Raffle__RaffleNotOpen(RaffleStatus status);
    error Raffle__NotEnoughEthSent();
    error Raffle__ReimbursementFailed(uint256 amount);
    error Raffle__RefundFailed();
    error SendMoreToEnterRaffle();
    error NotEnougthTimeHasPassed();
    error WinnerPayoutFailed();
    error HostPayoutFailed();
    error RaffleClosed();
    error RaffleStillOpen();
    error NotOwner();
    error UpkeepNotNeeded();
    /* Type declarations*/

    enum RaffleStatus{
        OPEN,
        ACCURING_YIELD,
        CALCULATING_WINNER,
        MAX_ROUNDS_REACHED,
        TIME_OVER,
        PAUSED
    }
    /*State Variable */
    struct Player {
        address playerAddress;
        uint256 nbTicketOwned;
    }
    Player[] s_Round_PlayerList;
    mapping(uint256 playerID => Player) s_playersToID;
    mapping(uint256 roundNumber => Player) s_Round_Winners_List;
    mapping(uint256 roundNumber => Player[]) s_Player_List_By_Round;
    AggregatorV3Interface s_priceFeed;
    uint256 private s_PlayerID;
    uint256[] s_raffle_entries;
    uint256 private currentRound;
    uint256 private immutable i_maxRound;
    address private immutable i_owner;
    uint256 private immutable i_interval;
    uint256 private immutable i_interval_investment;
    uint256 private immutable TICKET_PRICE_USD;
    uint256 private s_lastTimeStamp;
    bytes32 private immutable i_keyhash;
    uint256 private immutable i_subscriptionID;
    uint16 private constant REQUEST_CONFIRMATION = 3;
    uint32 private constant NUM_WORDS = 1;
    uint32 private immutable i_callbackGasLimit;
    RaffleStatus s_raffleStatuts;
    bool private s_timeisup;
    bool private s_fundstransfered;
    bool private s_fundswithdrawn;

    /*Events */
    event RaffleEntered(address indexed player, uint256 indexed nbTickets);
    event RaffleWinnerPicked(address indexed player, uint256 winnerShare);
    event RaffleMaxRoundReached();
    event RaffleNewRoundStarted(uint256 indexed currentRound);

    constructor(
        uint256 _subscriptionID,
        bytes32 gaslane,
        uint256 _interval,
        uint256 _TICKET_PRICE_USD,
        uint32 _callbackGasLimit,
        address _vrfCoordinator,
        address _priceFeedAddress,
        uint256 _max_Round,
        uint256 _interval_investment
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        s_priceFeed = AggregatorV3Interface(_priceFeedAddress);
        i_owner = msg.sender;
        i_maxRound = _max_Round;
        currentRound = 1;
        i_interval = _interval;
        i_keyhash = gaslane;
        i_subscriptionID = _subscriptionID;
        i_callbackGasLimit = _callbackGasLimit;
        s_lastTimeStamp = block.timestamp;
        s_raffleStatuts = RaffleStatus.OPEN;
        TICKET_PRICE_USD = _TICKET_PRICE_USD;
        s_PlayerID = 0;
        s_timeisup= false;
        s_fundstransfered = false;
        s_fundswithdrawn = false;
        i_interval_investment = _interval_investment;
    }

    
    function enterRaffle() public payable {
        if ((block.timestamp - s_lastTimeStamp) >= i_interval) {
            s_raffleStatuts = RaffleStatus.TIME_OVER;
        }
        if (s_raffleStatuts != RaffleStatus.OPEN) {
            revert Raffle__RaffleNotOpen(s_raffleStatuts);
        }
        uint256 nbTickets = msg.value / TICKET_PRICE_USD;
        if (nbTickets < 1) {
            revert Raffle__NotEnoughEthSent();
        }
        
        Player memory newPlayer = Player(msg.sender, nbTickets);
        
        if (!playerExist(newPlayer)) {
            // Add new player
            s_Round_PlayerList.push(newPlayer);
            s_playersToID[s_PlayerID] = newPlayer;
            for (uint256 index = 0; index < nbTickets; ++index) {
                s_raffle_entries.push(s_PlayerID);
            }
            s_PlayerID++;
        } else {
            // Update existing player
            uint256 existingPlayerID = getExistingPlayerID(msg.sender);
            
            // Update ticket count in mapping
            s_playersToID[existingPlayerID].nbTicketOwned += nbTickets;
            
            // Update ticket count in array
            for (uint256 i = 0; i < s_Round_PlayerList.length; i++) {
                if (s_Round_PlayerList[i].playerAddress == msg.sender) {
                    s_Round_PlayerList[i].nbTicketOwned += nbTickets;
                    break;
                }
            }
            
            // Add new raffle entries for the additional tickets
            for (uint256 index = 0; index < nbTickets; ++index) {
                s_raffle_entries.push(existingPlayerID);
            }
        }
        
        // Handle refund for excess payment
        uint256 refundAmount = msg.value % TICKET_PRICE_USD;
        if (refundAmount > 0) {
            require(address(this).balance >= refundAmount, "Insufficient balance for refund");
            (bool success,) = payable(msg.sender).call{value: refundAmount}("");
            if (!success) {
                revert Raffle__ReimbursementFailed(refundAmount);
            }
        }
        
        emit RaffleEntered(msg.sender, nbTickets);
    }

    function checkUpkeep(bytes memory /* checkData */ ) public override returns(bool upkeepNeeded, bytes memory /* performData*/){
        if(!s_fundstransfered){
            bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) >= i_interval);
            bool isOpen = (s_raffleStatuts ==  RaffleStatus.OPEN);
            upkeepNeeded = isOpen && timeHasPassed;
            return(upkeepNeeded,"");
        }else if(!s_fundswithdrawn){
            bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) >= i_interval_investment);
            upkeepNeeded = timeHasPassed;
            return(upkeepNeeded,"");
        }else{
            upkeepNeeded = false;
            return(upkeepNeeded,"");
        }
    }


    function performUpkeep(bytes calldata /* performData */ ) external override {

        (bool upkeepNeeded,) = checkUpkeep("");
        if(!upkeepNeeded){ revert UpkeepNotNeeded();}

        bool hasBalance = address(this).balance > 0;
        if(!hasBalance && !s_fundstransfered){
            //Move on to the next round
            nextRound();
        }else if(hasBalance && !s_fundstransfered){
            //Transfer funds to generate yield
            transferfunds();
        }else if(s_fundstransfered && !s_fundswithdrawn){
            //Withdraw funds and distribute
            withdrawfunds();
        }

    }

    function nextRound() internal {
            currentRound++;
            if(currentRound < i_maxRound){ 
                s_raffleStatuts = RaffleStatus.OPEN;
                s_lastTimeStamp = block.timestamp;
                s_fundstransfered = false;
                s_fundswithdrawn = false;
                emit RaffleNewRoundStarted(currentRound);
            }else{
                s_raffleStatuts = RaffleStatus.MAX_ROUNDS_REACHED;
                emit RaffleMaxRoundReached();
            }
    }
    function transferfunds() internal{
        s_fundstransfered = true;
        s_raffleStatuts =  RaffleStatus.ACCURING_YIELD;
        s_lastTimeStamp = block.timestamp;
    }
    function withdrawfunds() internal{
        s_fundswithdrawn = true;
        pickwinner();
    }

    function pickwinner() internal{
        s_raffleStatuts =  RaffleStatus.CALCULATING_WINNER;
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
        uint256 indexOfWinner = randomWords[0] % s_raffle_entries.length;
        uint256 winnerID = s_raffle_entries[indexOfWinner];
        Player memory winner = s_playersToID[winnerID];
        s_Round_Winners_List[currentRound] = winner;
        s_Player_List_By_Round[currentRound]= s_Round_PlayerList;
        address payable winnerAddress = payable(winner.playerAddress);
        
        delete s_raffle_entries;
        delete s_Round_PlayerList;

        
        uint256 winnerShare = (address(this).balance * 95) / 100;
        uint256 hostShare = (address(this).balance * 5) / 100;
        (bool winnerPayoutSuccess,) = winnerAddress.call{value: winnerShare}("");
        if(!winnerPayoutSuccess) { revert WinnerPayoutFailed(); }
        (bool hostPayoutSuccess,) = payable(i_owner).call{value: hostShare}("");
        if(!hostPayoutSuccess) { revert HostPayoutFailed(); }
        emit RaffleWinnerPicked(winnerAddress, winnerShare);
        nextRound();
        
    }


    function playerExist(Player memory _player) internal view returns(bool playerExists) {
        playerExists = false;
        for (uint256 i = 0; i < s_Round_PlayerList.length; i++) {
            if (s_Round_PlayerList[i].playerAddress == _player.playerAddress) {
                playerExists = true;
                break;
            }
        }
    }

    function getExistingPlayerID(address _playerAddress) internal view returns(uint256 playerID) {
        for (uint256 i = 0; i < s_Round_PlayerList.length; i++) {
            if (s_Round_PlayerList[i].playerAddress == _playerAddress) {
                // Find the corresponding ID in the mapping
                for (uint256 j = 0; j < s_PlayerID; j++) {
                    if (s_playersToID[j].playerAddress == _playerAddress) {
                        return j;
                    }
                }
            }
        }
        revert("Player not found"); // This should never happen if playerExist returned true
    }
    function pauseRaffle() public OnlyOWner{
        s_raffleStatuts =  RaffleStatus.PAUSED;
    }

    function resumeRaffle() public OnlyOWner{
        s_raffleStatuts =  RaffleStatus.OPEN;
    }
    
    function refundPaticipants() public OnlyOWner{
        Player[] memory PlayerList = s_Round_PlayerList;
        for(uint256 i=0; i < PlayerList.length; i++){
            uint256 amountToRefund = PlayerList[i].nbTicketOwned * TICKET_PRICE_USD;
            (bool success,) = payable(PlayerList[i].playerAddress).call{value:amountToRefund}("");
            if(!success){
                revert Raffle__RefundFailed();
            }
        }
    }

    modifier OnlyOWner(){
        if (msg.sender != i_owner) {
            revert NotOwner();
        }
        _;
    }

    
    
    /**
     * Getters Functions
     */


    function getInterval() public view returns (uint256) {
        return i_interval;
    }

    function getCurrentRaffleRound() public view returns (uint256) {
        return currentRound;
    }

    function getMaxRound() public view returns (uint256) {
        return i_maxRound;
    }

    function getPlayer(uint256 _playerIndex) public view returns (Player memory) {
        return s_playersToID[_playerIndex];
    }
    function getPlayerNBTickets(uint256 _playerIndex) public view returns (uint256) {
        return s_playersToID[_playerIndex].nbTicketOwned;
    }
    function getHostAddress() public view returns(address){
        return i_owner;
    }
    function getRaffleInterval() public view returns(uint256){
        return i_interval;
    }
    function getRaffleStatus() public view returns(RaffleStatus) {
        return s_raffleStatuts;
    }
    function getWinner(uint256 roundNumber) public view returns(Player memory) {
        return s_Round_Winners_List[roundNumber];
    }
}
