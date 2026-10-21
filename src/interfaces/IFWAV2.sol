// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IFWAV2 {
    struct Acquisition {
        address purchaser;
        uint256 requestBlock;
        uint256 priceEscrowed;
        uint256 listingId;
        uint8 status;
    }

    struct Listing {
        address collection;
        address depositor;
        address purchaser;
        uint256 tokenId;
        uint256 weight;
        uint256 value;
        uint256 feeShare;
        uint256 feeDebt;
        uint256 slot;
        uint64 allocatedAt;
        uint8 status;
    }
    function quoteAcquisitionPrice() external view returns (uint256 fee, uint256 vrf, uint256 total);
    function isPurchaseBlackout() external view returns (bool);
    function acquire(
        address purchaser,
        uint256 count,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps
    ) external payable returns (uint256[] memory requestIds);
    function acquisitions(uint256 requestId) external view returns (Acquisition memory);
    function listings(uint256 listingId) external view returns (Listing memory);
    function settlementWindow() external view returns (uint256);
    function keepNFT(uint256 listingId) external;
    function acquisitionRefundCredit(address purchaser) external view returns (uint256);
    function withdrawAcquisitionRefund() external returns (uint256);
}
