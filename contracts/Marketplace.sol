// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import { Events } from "contracts/libraries/Events.sol";
import { Constants } from "contracts/libraries/Constants.sol";

contract NFTMarketplace is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IERC1155Receiver, IERC721Receiver, ERC165 {
    using SafeERC20 for IERC20;

    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 amount; // For ERC1155
        uint256 price;
        address paymentToken; // address(0) for ETH, otherwise ERC20 token address
        Constants.SaleType saleType;
        uint256 auctionEndTime;
        address highestBidder;
        uint256 highestBid;
        uint256 bidIncrement; // For Auction
    }

    mapping(uint256 => Listing) public listings;
    mapping(address => bool) public blacklist;
    uint256 public listingCounter;
    uint256 public buyerFee;
    uint256 public sellerFee;
    address public treasury;

    constructor() {
        _disableInitializers();
    }

    // ================================ MODIFIERS ================================

    modifier onlyNotBlacklisted() {
        require(!blacklist[msg.sender], "Blacklisted");
        _;
    }

    modifier onlyAuthorized(uint256 listingId) {
        Listing storage listing = listings[listingId];
        require(
            msg.sender == listing.seller || 
            msg.sender == listing.highestBidder || 
            msg.sender == owner(),
            "Not authorized"
        );
        _;
    }

    modifier auctionSaleOnly(uint256 listingId) {
        require(listings[listingId].saleType == Constants.SaleType.Auction, "Not an auction sale");
        _;
    }

    // ================================ EXTERNAL FUNCTIONS ================================

    function initialize(address _owner, address _treasury, uint256 _buyerFee, uint256 _sellerFee) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init(_owner);
        treasury = _treasury;
        buyerFee = _buyerFee;
        sellerFee = _sellerFee;
    }

    function listNFT(
        address nftContract, 
        uint256 tokenId, 
        uint256 amount, 
        uint256 price, 
        address paymentToken, 
        Constants.SaleType saleType, 
        uint256 auctionDuration,
        uint256 bidIncrement
    ) external onlyNotBlacklisted {
        require(price > 0, "Price must be greater than 0");

        if (saleType == Constants.SaleType.Auction) {
            require(auctionDuration > 0, "Auction duration must be greater than 0");
            require(bidIncrement > 0, "Bid increment must be greater than 0");
        }

        listingCounter++;
        uint256 listingId = listingCounter;

        listings[listingId] = Listing({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            amount: amount,
            price: price,
            paymentToken: paymentToken,
            saleType: saleType,
            auctionEndTime: saleType == Constants.SaleType.Auction ? block.timestamp + auctionDuration : 0,
            highestBidder: address(0),
            highestBid: 0,
            bidIncrement: saleType == Constants.SaleType.Auction ? bidIncrement : 0
        });

        transferNFT(nftContract, msg.sender, address(this), tokenId, amount);

        emit Events.Listed(listingId, msg.sender, nftContract, tokenId, amount, price, paymentToken, saleType, auctionDuration, bidIncrement);
    }

    function buyNFT(uint256 listingId) external payable onlyNotBlacklisted nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.saleType == Constants.SaleType.FixedPrice, "Not a fixed price sale");
        require(listing.price > 0, "Invalid listing");
        
        uint256 buyerFeeAmount = (listing.price * buyerFee) / Constants.TAX_BASE;
        uint256 sellerFeeAmount = (listing.price * sellerFee) / Constants.TAX_BASE;
        uint256 sellerProceeds = listing.price - sellerFeeAmount;
        uint256 totalAmountToPay = listing.price + buyerFeeAmount;

        handlePayment(listing.paymentToken, msg.sender, listing.seller, totalAmountToPay, buyerFeeAmount, sellerFeeAmount, sellerProceeds);

        transferNFT(listing.nftContract, address(this), msg.sender, listing.tokenId, listing.amount);

        emit Events.Purchased(listingId, msg.sender);
        delete listings[listingId];
    }

    function placeBid(uint256 listingId, uint256 bidAmount) external payable onlyNotBlacklisted auctionSaleOnly(listingId) nonReentrant {
        Listing storage listing = listings[listingId];
        require(block.timestamp < listing.auctionEndTime, "Auction ended");
        require(bidAmount >= listing.highestBid + listing.bidIncrement, "Bid too low");

        uint256 buyerFeeAmount = (bidAmount * buyerFee) / Constants.TAX_BASE;
        uint256 totalBidAmount = bidAmount + buyerFeeAmount;

        // Refund previous highest bidder
        if (listing.highestBidder != address(0)) {
            uint256 previousBidAmount = listing.highestBid;
            uint256 previousBuyerFeeAmount = (previousBidAmount * buyerFee) / Constants.TAX_BASE;

            handleRefund(listing.paymentToken, listing.highestBidder, previousBidAmount, previousBuyerFeeAmount);
        }

        handlePayment(listing.paymentToken, msg.sender, address(this), totalBidAmount, buyerFeeAmount, 0, bidAmount);

        listing.highestBid = bidAmount;
        listing.highestBidder = msg.sender;

        emit Events.BidPlaced(listingId, msg.sender, bidAmount);
    }

    function endAuction(uint256 listingId) external onlyNotBlacklisted nonReentrant onlyAuthorized(listingId) auctionSaleOnly(listingId) {
        Listing storage listing = listings[listingId];
        require(block.timestamp >= listing.auctionEndTime, "Auction not ended yet");
        require(listing.highestBidder != address(0), "No bids placed");

        uint256 highestBid = listing.highestBid;
        uint256 buyerFeeAmount = (highestBid * buyerFee) / Constants.TAX_BASE;
        uint256 sellerFeeAmount = (highestBid * sellerFee) / Constants.TAX_BASE;
        uint256 sellerProceeds = highestBid - sellerFeeAmount;

        handlePayment(listing.paymentToken, address(this), listing.seller, highestBid, buyerFeeAmount, sellerFeeAmount, sellerProceeds);

        transferNFT(listing.nftContract, address(this), listing.highestBidder, listing.tokenId, listing.amount);

        emit Events.AuctionEnded(listingId, listing.highestBidder, highestBid);
        delete listings[listingId];
    }

    function cancelSale(uint256 listingId) external onlyNotBlacklisted nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.seller == msg.sender, "Not the seller");
        require(listing.highestBidder == address(0), "Cannot cancel an active auction");

        transferNFT(listing.nftContract, address(this), msg.sender, listing.tokenId, listing.amount);

        emit Events.SaleCancelled(listingId);
        delete listings[listingId];
    }

    function blacklistUser(address user, bool status) external onlyOwner {
        blacklist[user] = status;
    }

    // ================================ INTERNAL FUNCTIONS ================================

    function transferNFT(address nftContract, address from, address to, uint256 tokenId, uint256 amount) internal {
        if (IERC721(nftContract).supportsInterface(0x80ac58cd)) { // ERC721
            IERC721(nftContract).safeTransferFrom(from, to, tokenId);
        } else if (IERC1155(nftContract).supportsInterface(0xd9b67a26)) { // ERC1155
            IERC1155(nftContract).safeTransferFrom(from, to, tokenId, amount, "");
        } else {
            revert("Unsupported NFT standard");
        }
    }

    function handlePayment(
        address paymentToken,
        address payer,
        address recipient,
        uint256 totalAmount,
        uint256 buyerFeeAmount,
        uint256 sellerFeeAmount,
        uint256 sellerProceeds
    ) internal {
        if (paymentToken == address(0)) { // ETH Payment
            require(msg.value >= totalAmount, "Insufficient payment");
            payable(treasury).transfer(buyerFeeAmount + sellerFeeAmount);
            payable(recipient).transfer(sellerProceeds);

            // Refund excess payment if any
            if (msg.value > totalAmount) {
                payable(payer).transfer(msg.value - totalAmount);
            }
        } else { // ERC20 Token Payment
            require(msg.value == 0, "Cannot send ETH when paying with tokens");
            IERC20(paymentToken).safeTransferFrom(payer, treasury, buyerFeeAmount + sellerFeeAmount);
            IERC20(paymentToken).safeTransferFrom(payer, recipient, sellerProceeds);
        }
    }

    function handleRefund(
        address paymentToken,
        address recipient,
        uint256 bidAmount,
        uint256 feeAmount
    ) internal {
        if (paymentToken == address(0)) { // ETH Payment
            payable(recipient).transfer(bidAmount + feeAmount);
        } else { // ERC20 Token Payment
            IERC20(paymentToken).transfer(recipient, bidAmount + feeAmount);
        }
    }

    // ================================ ERC1155/ERC721 RECEIVER FUNCTIONS ================================
    // Implement the IERC1155Receiver interface functions
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    // Implement the IERC721Receiver interface function
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return 
            interfaceId == type(IERC1155Receiver).interfaceId || 
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
