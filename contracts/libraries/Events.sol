// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Constants } from "contracts/libraries/Constants.sol";

library Events {
    event Listed(uint256 indexed listingId, address indexed seller, address nftContract, uint256 tokenId, uint256 amount, uint256 price, address paymentToken, Constants.SaleType saleType, uint256 auctionEndTime, uint256 bidIncrement);
    event SaleCancelled(uint256 indexed listingId);
    event Purchased(uint256 indexed listingId, address indexed buyer);
    event BidPlaced(uint256 indexed listingId, address indexed bidder, uint256 amount);
    event AuctionEnded(uint256 indexed listingId, address indexed winner, uint256 amount);
}
