//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceConverter {
    function getETHPrice(AggregatorV3Interface _priceFeed) public view returns(uint256){
        AggregatorV3Interface dataFeed = _priceFeed;
        (
            /* uint80 roundId */,
            int256 answer,
            /*uint256 startedAt*/,
            /*uint256 updatedAt*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        return uint256(answer*1e10);
    }
   
    function getConversionRateEthToUsd(uint256 _ethAmount, AggregatorV3Interface _priceFeed) public view returns (uint256){
        uint ethPrice = getETHPrice( _priceFeed);
        uint ethToUsd = (_ethAmount * ethPrice)/1e18;
        return ethToUsd;
    } 
    // New function to convert USD to ETH
    function getConversionRateUsdToEth(uint256 _usdAmount, AggregatorV3Interface _priceFeed) public view returns (uint256){
        uint ethPrice = getETHPrice( _priceFeed);
        // Convert USD to ETH by dividing USD amount by ETH price
        // Multiply by 1e18 first to maintain precision
        uint usdToEth = (_usdAmount * 1e18) / ethPrice;
        return usdToEth;
    }
}