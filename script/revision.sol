//SPDX-License-IDentifier:MIT
pragma solidity 0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceConverter{
    function getETHPrice(AggregatorV3Interface dataFeed) public returns(uint256){
        (,int256 answer,,,) = dataFeed.latestRoundData;
        return (answer*1e10);
    }
    function conversionRateETHUSD(uint256 amountETH, AggregatorV3Interface dataFeed) public returns(uint256){
        uint256 ETHprice = getETHPrice(dataFeed);
        uint256 ETHToUSD = amountETH * ETHPrice;
        return  ETHToUSD;
    }
    function conversionRateUSDETH(uint256 amountUSD, AggregatorV3Interface dataFeed) public returns(uint256){
        uint256 ETHprice = getETHPrice(dataFeed);
        uint256 USDToETH = amountUSD / ETHPrice;
        return  USDToRTH;
    }
}

contract Raffle is VRFConsumerBaseV2Plus,AutomationCompatibleInterface{
    //Host Create a Raffle (variable to store host). Raffle has a time durée and a number of round. Minimum price for ticket is 5 USD
    //Player pay ticket to participate the raffle(need a struct player/). He can pay the amount of ticket he want to enter the raffle. He is reimbursed the remainder
    //After the specified time is passed, contract pick winner, he receive 95% while host take 5%
    using PriceConverter for uint256;
    
    error Raffle__OneTicketAtLeastToEnterRaffle();
    error Raffle__ClosedAtTheMoment(RaffleStatuts s_rf);
    error Raffle__OwnerNeeded();

    enum RaffleStatuts{OPEN,CALCULATING,PAUSED};
    struct Player {address playerAddress; uint256 nbTickets;}

    address private immutable i_owner;
    uint256 private immutable i_interval;
    uint256 private s_lastTimeStamp;
    uint256 private s_playerID;
    mapping(uint256 => Player) private s_players_list;
    mapping(uint256 => address) private s_round_winners;
    uint256[] private s_raffleEntries;
    uint256 private immutable i_maxRound;
    uint256 private s_current_round;
    uint256 private immutable i_ticketPrice;
    RaffleStatuts private s_rf;
    uint256 s_subscriptionId;
    address vrfCoordinator ;
    bytes32 s_keyHash;
    uint32 callbackGasLimit;
    uint16 requestConfirmations;
    uint32 numWords;

    event PlayerEnteredRaffle(address indexed playerAddress, uint256 indexed nbTickets);
    event PlayerReimbursed ( address indexed playerAddress, uint256 indexed amount);
    event DiceRolled(uint256 indexed requestId);
    event PaymentDone(address indexed winner, uint256 indexed winnerShare, address indexed i_owner, uint256 indexed hostShare);

    
    constructor(
        uint256 _subscriptionId, 
        address _vrfCoordinator, 
        bytes32 _gaslane,
        uint32 callbackGasLimit, 
        uint16 _requestConfirmations, 
        uint32 _numWords, 
        uint256 _interval, 
        uint256 _maxRound, 
        uint256 _ticketPrice)
        VRFConsumerBaseV2Plus(
            vrfCoordinator
        ){
        i_owner =msg.sender;
        i_interval=_interval;
        i_maxRound=_maxRound;
        i_ticketPrice = _ticketPrice;
        s_rf = RaffleStatuts.OPEN;
        s_playerID =0 ;
        s_lastTimeStamp = block.timestamp;
        s_current_round = 1;
    }
    function enterRaffle() public payable OnlyOpenRaffle{
        uint256 nbTickets = msg.value/i_ticketPrice;
        if(nbTickets<1){revert Raffle__OneTicketAtLeastToEnterRaffle();}
        s_players_list[s_playerID] = Player(msg.sender,nbTickets);
        for (uint256 i =0; i<nbTickets;i++){
            s_raffleEntries.push(s_playerID);
        }
        s_playerID++;
        uint256 amountToBeReimbursed = msg.value % i_ticketPrice;
        if (amountToBeReimbursed >0){
            (bool success,) = payable(msg.Sender).call{value: amountToBeReimbursed}("");
            require(success,"Reimbursment Failed");
            emit PlayerReimbursed(msg.sender,amountToBeReimbursed);
        }
        emit PlayerEnteredRaffle(msg.sender,nbTickets);
    }
f   unction checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        upkeepNeeded = (block.timestamp - lastTimeStamp) > i_interval;
        // We don't use the checkData in this example. The checkData is defined when the Upkeep was registered.
    }
    function performUpkeep(bytes calldata /* performData */) external override{
        if(s_rf != RaffleStatuts.OPEN && (block.timestamp - s_lastTimeStamp) < i_interval){revert Raffle__ClosedAtTheMoment(s_rf);}
        s_rf = RaffleStatuts.CALCULATING;
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                // Set nativePayment to true to pay for VRF requests with Sepolia ETH instead of LINK
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        emit DiceRolled(requestId);
    }
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override{
        uint256 totalPlayers = s_playerID;
        uint256 winnerIndex = randomWords[0] %  totalPlayer;
        address winner = s_players_list[s_raffleEntries[winnerIndex]].playerAddress;
        s_round_winners[s_current_round] = winner;
        uint256 winnerShare= address(this).balance * 95/100;
        (bool success,) = payable(winner).call{value:winnerShare}("");
        require(success, "Failed to withdraw winner share");
        uint256 hostShare= address(this).balance * 5/100;
        (bool success2,) = payable(i_owner).call{value:hostShare}("");
        require(success, "Failed to withdraw host share");
        delete s_raffleentries;
        s_current_round++;
        s_rf == RaffleStatuts.OPEN;
        emit PaymentDone(winner, winnerShare, i_owner, hostShare);

    }
    function pauseRaffle() public OnlyOwner{
        s_rf == RaffleStatuts.PAUSED;
    }
    modifier OnlyOpenRaffle(){
        if(s_rf != RaffleStatuts.OPEN){revert Raffle__ClosedAtTheMoment(s_rf);}
        _;
    }
    modifier OnlyOwner(){
        if(msg.sender != i_owner){revert Raffle__OwnerNeeded();}
        _;
    }
    //Getters Functions
    function getOwner()public view returns(address){
        return i_owner;
    }
    function receive(){
        enterRaffle();
    }
    function callback(){
        enterRaffle();
    }

}