//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
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
    error SendMoreToEnterRaffle();
    error NotEnougthTimeHasPassed();
    error WinnerPayoutFailed();
    error HostPayoutFailed();
    error RaffleClosed();
    error RaffleStillOpen();
    error NotOwner();
    /* Type declarations*/

    enum RaffleStatuts {
        ONGOING,
        PAUSE,
        ENDED
    }
    /*State Variable */
    struct Player {
        address playerAddress;
        uint256 nbTicketOwned;
    }
    Player[] s_total_player;
    mapping(uint256 => Player) s_players_list;
    mapping(uint256 => address) s_Round_Winners_List;
    AggregatorV3Interface s_priceFeed;
    uint256 private s_playercounter;
    uint256[] s_raffle_entries;
    uint256 private currentRound;
    uint256 private maxRound;
    address private immutable i_owner;
    uint256 private immutable i_interval;
    uint256 private immutable TICKET_PRICE_USD;
    uint256 private s_lastTimeStamp;
    bytes32 private immutable i_keyhash;
    uint256 private immutable i_subscriptionID;
    uint16 private constant REQUEST_CONFIRMATION = 3;
    uint32 private constant NUM_WORDS = 1;
    uint32 private immutable i_callbackGasLimit;
    RaffleStatuts s_raffleState;

    /*Events */
    event RaffleEntered(address indexed player, uint256 indexed nbTickets);
    event RaffleWinnerPicked(address indexed player);
    event RaffleNewRoundStarted(uint256 indexed currentRound);

    constructor(
        uint256 _subscriptionID,
        bytes32 gaslane,
        uint256 _interval,
        uint256 _TICKET_PRICE_USD,
        uint32 _callbackGasLimit,
        address _vrfCoordinator,
        address _priceFeedAddress,
        uint256 _max_Round
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        s_priceFeed = AggregatorV3Interface(_priceFeedAddress);
        i_owner = msg.sender;
        maxRound = _max_Round;
        currentRound = 1;
        i_interval = _interval;
        i_keyhash = gaslane;
        i_subscriptionID = _subscriptionID;
        i_callbackGasLimit = _callbackGasLimit;
        s_lastTimeStamp = block.timestamp;
        s_raffleState = RaffleStatuts.ONGOING;
        TICKET_PRICE_USD = _TICKET_PRICE_USD;
        s_playercounter = 0;
    }

    
    function enterRaffle() public payable RaffleOpen{
        uint256 nbTickets = msg.value / TICKET_PRICE_USD.getConversionRateEthToUsd(s_priceFeed);
        if (nbTickets < 1) {
            revert SendMoreToEnterRaffle();
        }
        s_total_player.push(Player(msg.sender,nbTickets));
        s_players_list[s_playercounter] = Player(msg.sender,nbTickets);
        for(uint256 index = 0; index < nbTickets; ++index){
            s_raffle_entries.push(s_playercounter);
        }
        s_playercounter++;
        uint256 refundAmount = msg.value % TICKET_PRICE_USD.getConversionRateEthToUsd(s_priceFeed);
        if(refundAmount > 0){
            require(address(this).balance >= refundAmount, "Insufficient balance for refund");
            (bool success,) = payable(msg.sender).call{value:refundAmount}("");
            require(success,"Refund Failed");
        }
        emit RaffleEntered(msg.sender, nbTickets);
    }

    function checkUpkeep(bytes memory /* checkData */ ) public view override returns(bool upkeepNeeded, bytes memory /* performData*/){
        bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) >= i_interval);
        bool isOpen = (s_raffleState == RaffleStatuts.ONGOING);
        bool hasBalance = address(this).balance > 0;
        upkeepNeeded = timeHasPassed && isOpen && hasBalance;
        return(upkeepNeeded,"");
    }


    function performUpkeep(bytes calldata /* performData */ ) external override {

        (bool upkeepNeeded,) = checkUpkeep("");
        if(!upkeepNeeded){ revert();}
        s_raffleState = RaffleStatuts.ENDED;
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
        uint256 indexOfWinner = randomWords[0] % s_playercounter;
        address payable recentWinner = payable(s_players_list[s_raffle_entries[indexOfWinner]].playerAddress);
        s_Round_Winners_List[currentRound] = recentWinner;
        delete s_raffle_entries;
        delete s_total_player;
        uint256 winnerShare = (address(this).balance * 95) / 100;
        uint256 hostShare = (address(this).balance * 5) / 100;
        (bool winnerPayoutSuccess,) = recentWinner.call{value: winnerShare}("");
        if(!winnerPayoutSuccess) { revert WinnerPayoutFailed(); }
        (bool hostPayoutSuccess,) = payable(i_owner).call{value: hostShare}("");
        if(!hostPayoutSuccess) { revert HostPayoutFailed(); }
        emit RaffleWinnerPicked(recentWinner);
        if(currentRound != maxRound){
            s_raffleState = RaffleStatuts.ONGOING;
            s_lastTimeStamp = block.timestamp;
            currentRound++;
            emit RaffleNewRoundStarted(currentRound);
        }
        
    }

    function pauseRaffle() public OnlyOWner{
        s_raffleState = RaffleStatuts.PAUSE;
    }
    

    modifier OnlyOWner(){
        if (msg.sender != i_owner) {
            revert NotOwner();
        }
        _;
    }

    modifier RaffleOpen(){
        if (s_raffleState != RaffleStatuts.ONGOING) {
            revert RaffleClosed();
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
        return maxRound;
    }

    function getPlayer(uint256 _playerIndex) public view returns (Player memory) {
        return s_players_list[_playerIndex];
    }
    function getHostAddress() public view returns(address){
        return i_owner;
    }
    function getRaffleInterval() public view returns(uint256){
        return i_interval;
    }
    function getRaffleStatus() public view returns(RaffleStatuts) {
        return s_raffleState;
    }
    function getWinner(uint256 roundNumber) public view returns(address) {
        return s_Round_Winners_List[roundNumber];
    }
}
