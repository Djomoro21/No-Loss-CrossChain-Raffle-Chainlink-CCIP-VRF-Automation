//SPDX-License-Identifier: MIT
import {Script, console} from "forge-std/Script.sol";
import {Raffle} from "../src/Raffle.sol";
import {HelperConfig} from "./HelperConfig.sol";

contract DeployRaffleScript is Script{
    function run() external{
        return deployContract();
    }
    function deployContract() public returns(Raffle, HelperConfig){
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.networkConfig memory config = helperConfig.getConfig();
        vm.startBroadcast();
        Raffle raffle = new Raffle(
            config.subscriptionId,
            config.gasLane, 
            config.automationUpdateInterval,
            config.raffleEntranceFee,
            config.callbackGasLimit,
            config.vrfCoordinatorV2_5,
            config.link,
            config.account,
            config.priceFeed,
            config.max_Round);
        vm.stopBroadcast();
    }
}