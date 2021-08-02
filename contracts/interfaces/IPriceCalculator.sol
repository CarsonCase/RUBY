// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IPriceCalculator {
    struct ReferenceData {
        uint lastData;
        uint lastUpdated;
    }

    function pricesInUSD(address[] memory assets) external view returns (uint[] memory);
    function valueOfAsset(address asset, uint amount) external view returns (uint valueInBNB, uint valueInUSD);
    function priceOfRuby() view external returns (uint);
    function priceOfBNB() view external returns (uint);
}
