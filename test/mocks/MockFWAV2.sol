// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IFWAV2} from "../../src/interfaces/IFWAV2.sol";
import {MockNFT} from "./MockNFT.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract MockFWAV2 is IFWAV2 {
    bool public blackout;
    uint256 public fee = 0.1 ether;
    uint256 public vrf = 0.01 ether;
    uint256 public discount;
    uint256 public settlementWindow = 3600;
    uint256 public nonce;
    uint256 public keepCalls;
    address public lastPurchaser;
    uint256 public lastCount;
    uint256 public lastMaxFee;
    uint256 public lastMinWeight;
    uint256 public lastSlippage;
    mapping(uint256 => Acquisition) private acqs;
    mapping(uint256 => Listing) private listed;
    mapping(address => uint256) public acquisitionRefundCredit;
    MockNFT public nft;

    constructor(MockNFT n) {
        nft = n;
    }

    function setBlackout(bool v) external {
        blackout = v;
    }

    function setQuote(uint256 f, uint256 v) external {
        fee = f;
        vrf = v;
    }

    function setDiscount(uint256 value) external {
        discount = value;
    }

    function quoteAcquisitionPrice() external view returns (uint256, uint256, uint256) {
        return (fee, vrf, fee + vrf);
    }

    function isPurchaseBlackout() external view returns (bool) {
        return blackout;
    }

    function acquire(address purchaser, uint256 count, uint256 maxFee, uint256 minWeighted, uint256 slippage)
        external
        payable
        returns (uint256[] memory ids)
    {
        require(!blackout && count == 1 && maxFee >= fee && msg.value >= fee + vrf - discount);
        lastPurchaser = purchaser;
        lastCount = count;
        lastMaxFee = maxFee;
        lastMinWeight = minWeighted;
        lastSlippage = slippage;
        uint256 id = ++nonce;
        acqs[id] = Acquisition(purchaser, block.number, fee - discount, 0, 1);
        ids = new uint256[](1);
        ids[0] = id;
        uint256 excess = msg.value - (fee + vrf - discount);
        if (excess != 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            require(ok);
        }
    }

    function fulfill(uint256 requestId) external {
        Acquisition storage a = acqs[requestId];
        require(a.status == 1);
        a.status = 2;
        a.listingId = requestId;
        nft.mint(address(this), requestId);
        listed[requestId] = Listing(
            address(nft), address(this), a.purchaser, requestId, 1, 1 ether, 0, 0, 0, uint64(block.timestamp), 2
        );
    }

    function acquisitions(uint256 id) external view returns (Acquisition memory) {
        return acqs[id];
    }

    /// @dev Allocate an NFT its previous winner has resold to the pool, under a new request.
    function fulfillExisting(uint256 requestId, uint256 tokenId) external {
        Acquisition storage a = acqs[requestId];
        require(a.status == 1 && nft.ownerOf(tokenId) == address(this));
        a.status = 2;
        a.listingId = requestId;
        listed[requestId] =
            Listing(address(nft), address(this), a.purchaser, tokenId, 1, 1 ether, 0, 0, 0, uint64(block.timestamp), 2);
    }

    function listings(uint256 id) external view returns (Listing memory) {
        return listed[id];
    }

    function keepNFT(uint256 id) external {
        Listing storage l = listed[id];
        require(l.status == 2 && msg.sender == l.purchaser);
        require(block.timestamp < uint256(l.allocatedAt) + settlementWindow);
        l.status = 4;
        keepCalls++;
        IERC721(l.collection).safeTransferFrom(address(this), msg.sender, l.tokenId);
    }

    function refund(uint256 id) external {
        Acquisition storage a = acqs[id];
        require(a.status == 1);
        a.status = 4;
        acquisitionRefundCredit[a.purchaser] += a.priceEscrowed;
    }

    function withdrawAcquisitionRefund() external returns (uint256 amount) {
        amount = acquisitionRefundCredit[msg.sender];
        require(amount != 0);
        acquisitionRefundCredit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}
