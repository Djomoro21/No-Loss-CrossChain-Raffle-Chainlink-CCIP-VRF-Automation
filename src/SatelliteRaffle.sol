//SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title Satellite Raffle Contract
 * @author Djomoro
 * @notice This contract handles cross-chain raffle entries and winner notifications
 * @dev Deployed on satellite chains to communicate with main raffle contract via CCIP
 */
contract SatelliteRaffle is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;

    /*Errors */
    error InsufficientFeeTokenAmount();
    error NothingToWithdraw();
    error NotAllowlistedSourceChain(uint64 sourceChainSelector);
    error NotAllowlistedSender(address sender);
    error InvalidMessageType();
    error InsufficientPayment();
    error PayoutFailed();
    error RefundFailed();

    enum MessageType {
        ENTER_RAFFLE,
        WINNER_NOTIFICATION
    }

    struct CrossChainEntry {
        address player;
        uint256 tickets;
        uint64 sourceChain;
    }

    struct CrossChainMessage {
        MessageType messageType;
        bytes data;
    }

    struct WinnerInfo {
        address winner;
        uint256 amount;
        uint256 round;
    }

    // State variables
    IRouterClient private s_router;
    IERC20 private s_linkToken;
    AggregatorV3Interface private s_priceFeed;
    
    uint64 private immutable i_mainChainSelector;
    address private immutable i_mainRaffleContract;
    uint256 private immutable i_ticketPriceUSD;
    
    // Allowlisted chains and senders
    mapping(uint64 => bool) public allowlistedSourceChains;
    mapping(address => bool) public allowlistedSenders;
    
    // Track entries and winners
    mapping(address => uint256) public playerEntries; // Track entries per round
    mapping(uint256 => WinnerInfo) public roundWinners;
    
    uint256 public currentRound = 1;
    bool public raffleActive = true;

    /*Events */
    event CrossChainEntryInitiated(
        address indexed player, 
        uint256 tickets, 
        uint256 totalValue,
        bytes32 indexed messageId
    );
    event WinnerNotificationReceived(
        address indexed winner,
        uint256 amount,
        uint256 indexed round
    );
    event WinnerPaidOut(
        address indexed winner,
        uint256 amount,
        uint256 indexed round
    );
    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        CrossChainMessage message,
        address feeToken,
        uint256 fees
    );

    constructor(
        address _router,
        address _link,
        address _priceFeed,
        uint64 _mainChainSelector,
        address _mainRaffleContract,
        uint256 _ticketPriceUSD
    ) CCIPReceiver(_router) {
        s_router = IRouterClient(_router);
        s_linkToken = IERC20(_link);
        s_priceFeed = AggregatorV3Interface(_priceFeed);
        i_mainChainSelector = _mainChainSelector;
        i_mainRaffleContract = _mainRaffleContract;
        i_ticketPriceUSD = _ticketPriceUSD;
        
        // Allow the main chain and contract by default
        allowlistedSourceChains[_mainChainSelector] = true;
        allowlistedSenders[_mainRaffleContract] = true;
    }

    modifier onlyAllowlistedSourceChain(uint64 _sourceChainSelector) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert NotAllowlistedSourceChain(_sourceChainSelector);
        _;
    }

    modifier onlyAllowlistedSender(address _sender) {
        if (!allowlistedSenders[_sender]) revert NotAllowlistedSender(_sender);
        _;
    }

    modifier onlyActiveRaffle() {
        require(raffleActive, "Raffle is not active");
        _;
    }

    // Configuration functions
    function allowlistSourceChain(uint64 _sourceChainSelector, bool allowed) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = allowed;
    }

    function allowlistSender(address _sender, bool allowed) external onlyOwner {
        allowlistedSenders[_sender] = allowed;
    }

    function setRaffleActive(bool _active) external onlyOwner {
        raffleActive = _active;
    }

    // Main function for users to enter the raffle from this chain
    function enterRaffle() external payable onlyActiveRaffle {
        uint256 ticketPriceWei = getTicketPriceInWei();
        uint256 nbTickets = msg.value / ticketPriceWei;
        
        if (nbTickets < 1) {
            revert InsufficientPayment();
        }

        // Calculate exact payment needed and refund excess
        uint256 totalCost = nbTickets * ticketPriceWei;
        uint256 refundAmount = msg.value - totalCost;
        
        if (refundAmount > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: refundAmount}("");
            if (!refundSuccess) {
                revert RefundFailed();
            }
        }

        // Track player entries
        playerEntries[msg.sender] += nbTickets;

        // Send cross-chain message to main raffle contract
        bytes32 messageId = _sendEntryToMainContract(msg.sender, nbTickets, totalCost);
        
        emit CrossChainEntryInitiated(msg.sender, nbTickets, totalCost, messageId);
    }

    // Internal function to send entry to main contract
    function _sendEntryToMainContract(
        address player, 
        uint256 tickets, 
        uint256 totalValue
    ) internal returns (bytes32 messageId) {
        CrossChainEntry memory entry = CrossChainEntry({
            player: player,
            tickets: tickets,
            sourceChain: getCurrentChainSelector()
        });

        CrossChainMessage memory message = CrossChainMessage({
            messageType: MessageType.ENTER_RAFFLE,
            data: abi.encode(entry)
        });

        // Create token transfer (sending ETH equivalent as tokens)
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(0), // Native token
            amount: totalValue
        });

        // Create the CCIP message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(i_mainRaffleContract),
            data: abi.encode(message),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 300_000})
            ),
            feeToken: address(s_linkToken)
        });

        // Get the fee required to send the CCIP message
        uint256 fees = s_router.getFee(i_mainChainSelector, evm2AnyMessage);

        if (fees > s_linkToken.balanceOf(address(this)))
            revert InsufficientFeeTokenAmount();

        // Approve the Router to transfer LINK tokens
        s_linkToken.approve(address(s_router), fees);

        // Send the message
        messageId = s_router.ccipSend(i_mainChainSelector, evm2AnyMessage);

        emit MessageSent(
            messageId, 
            i_mainChainSelector, 
            i_mainRaffleContract, 
            message, 
            address(s_linkToken), 
            fees
        );
    }

    // CCIP Receive function - handles messages from main contract
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage)
        internal
        override
        onlyAllowlistedSourceChain(any2EvmMessage.sourceChainSelector)
        onlyAllowlistedSender(abi.decode(any2EvmMessage.sender, (address)))
    {
        CrossChainMessage memory message = abi.decode(any2EvmMessage.data, (CrossChainMessage));
        
        if (message.messageType == MessageType.WINNER_NOTIFICATION) {
            (address winner, uint256 amount, uint256 round) = abi.decode(
                message.data, 
                (address, uint256, uint256)
            );
            
            // Store winner information
            roundWinners[round] = WinnerInfo({
                winner: winner,
                amount: amount,
                round: round
            });
            
            emit WinnerNotificationReceived(winner, amount, round);
            
            // Pay out the winner if they're on this chain
            _payoutWinner(winner, amount, round);
        }
    }

    // Internal function to pay out winner
    function _payoutWinner(address winner, uint256 amount, uint256 round) internal {
        // Check if we have sufficient balance (in a real implementation, 
        // you might want to implement a more sophisticated fund management system)
        if (address(this).balance >= amount) {
            (bool success,) = payable(winner).call{value: amount}("");
            if (!success) {
                revert PayoutFailed();
            }
            emit WinnerPaidOut(winner, amount, round);
        }
        // If insufficient balance, winner notification is stored and can be claimed later
    }

    // Manual payout function for cases where automatic payout failed
    function claimWinnings(uint256 round) external {
        WinnerInfo memory winnerInfo = roundWinners[round];
        require(winnerInfo.winner == msg.sender, "Not the winner");
        require(winnerInfo.amount > 0, "No winnings to claim");
        require(address(this).balance >= winnerInfo.amount, "Insufficient contract balance");
        
        // Clear the winner info to prevent double claiming
        delete roundWinners[round];
        
        (bool success,) = payable(msg.sender).call{value: winnerInfo.amount}("");
        if (!success) {
            // Restore winner info if payout failed
            roundWinners[round] = winnerInfo;
            revert PayoutFailed();
        }
        
        emit WinnerPaidOut(msg.sender, winnerInfo.amount, round);
    }

    // Helper function to get ticket price in wei
    function getTicketPriceInWei() public view returns (uint256) {
        (, int256 price, , , ) = s_priceFeed.latestRoundData();
        require(price > 0, "Invalid price feed");
        
        // Convert USD to Wei (assuming price feed gives ETH/USD with 8 decimals)
        uint256 ethPriceUSD = uint256(price) * 1e10; // Convert to 18 decimals
        return (i_ticketPriceUSD * 1e18) / ethPriceUSD;
    }

    // Get current chain selector (this would need to be implemented based on the chain)
    function getCurrentChainSelector() public view returns (uint64) {
        // This should return the current chain's CCIP selector
        // You'll need to set this based on which chain you're deploying to
        if (block.chainid == 1) return 5009297550715157269; // Ethereum Mainnet
        if (block.chainid == 137) return 4051577828743386545; // Polygon Mainnet
        if (block.chainid == 43114) return 6433500567565415381; // Avalanche Mainnet
        if (block.chainid == 42161) return 4949039107694359620; // Arbitrum One
        if (block.chainid == 10) return 3734403246176062136; // Optimism Mainnet
        if (block.chainid == 8453) return 15971525489660198786; // Base Mainnet
        
        // Add more chains as needed
        revert("Unsupported chain");
    }

    // Administrative functions
    function withdrawLink() external onlyOwner {
        uint256 amount = s_linkToken.balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        s_linkToken.safeTransfer(owner(), amount);
    }

    function withdrawETH() external onlyOwner {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        (bool success,) = payable(owner()).call{value: amount}("");
        if (!success) revert PayoutFailed();
    }

    function emergencyRefund(address player, uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient balance");
        (bool success,) = payable(player).call{value: amount}("");
        if (!success) revert RefundFailed();
    }

    // Deposit LINK tokens for CCIP fees
    function depositLink(uint256 amount) external {
        s_linkToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    // Getter functions
    function getPlayerEntries(address player) external view returns (uint256) {
        return playerEntries[player];
    }

    function getWinnerInfo(uint256 round) external view returns (WinnerInfo memory) {
        return roundWinners[round];
    }

    function getTicketPriceUSD() external view returns (uint256) {
        return i_ticketPriceUSD;
    }

    function getMainChainSelector() external view returns (uint64) {
        return i_mainChainSelector;
    }

    function getMainRaffleContract() external view returns (address) {
        return i_mainRaffleContract;
    }

    function getLinkBalance() external view returns (uint256) {
        return s_linkToken.balanceOf(address(this));
    }

    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function isChainAllowlisted(uint64 chainSelector) external view returns (bool) {
        return allowlistedSourceChains[chainSelector];
    }

    function isSenderAllowlisted(address sender) external view returns (bool) {
        return allowlistedSenders[sender];
    }

    // Receive function to accept ETH
    receive() external payable {}
}