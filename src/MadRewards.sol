// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IMadToken} from "./interfaces/IMadToken.sol";
import {IFWAV2} from "./interfaces/IFWAV2.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./oracle/OracleAttestation.sol";
import {OracleQuestion} from "./oracle/OracleQuestion.sol";

interface IMadBudget {
    function nftEthClaims() external view returns (uint256);
    function redeemNftETH(uint256 amount) external;
}

/// @notice NFT custody and oracle settlement. Constructed by MadHook; never a launch allocation recipient.
contract MadRewards is OracleAttestationConsumer, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidConfig();
    error Blackout();
    error InsufficientBudget();
    error InvalidAcquisition();
    error SettlementWindowClosed();
    error NoNFT();
    error InvalidRound();
    error AskStillLive();
    error TooEarly();
    error InvalidResponse();
    error UnknownRequest();
    error AlreadyAwarded();

    event FwaV2Set(address indexed pool);
    event AcquisitionBoundsSet(uint256 feeMargin, uint256 slippage);
    event OracleSettingsSet(address indexed intake, bytes32 action, address asset, uint256 maxPrice, address signer);
    event Bought(uint256 indexed requestId, address indexed pool, uint256 paid);
    event Kept(uint256 indexed requestId, address indexed collection, uint256 tokenId, uint256 queueIndex);
    event RefundReceived(address indexed pool, uint256 amount);
    event RoundAssigned(uint256 indexed round, uint256 indexed nftIndex, uint64 closedAt);
    event Asked(uint256 indexed round, bytes32 indexed requestId, bytes32 questionHash, uint256 paid);
    event AskFailed(uint256 indexed round, bytes32 indexed requestId, uint8 status, bytes32 reason);
    event AskSuperseded(bytes32 indexed requestId);
    event WinnerStored(uint256 indexed round, address indexed winner);
    event AwardAttempt(uint256 indexed round, address indexed beneficiary, bool success);

    uint256 public constant ASK_TIMEOUT = 6 hours;
    uint256 public constant FALLBACK_DELAY = 72 hours;
    uint256 public constant CONFIRMATIONS = 8;
    address public immutable owner;
    address public immutable hook;
    IMadToken public immutable mad;
    IFWAV2 public fwaV2 = IFWAV2(0x958C41181182e76F221331b2755b77D9e1426A98);
    IIntake public intake = IIntake(0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
    IERC20 public oracleAsset = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    bytes32 public oracleAction = bytes32("oracle.request@oracle-1");
    /// @notice Zero means pay the live price without an additional ceiling, solely from donated IMD.
    uint256 public maxOraclePrice;
    uint256 public acquisitionFeeMargin;
    uint256 public acquisitionSlippageBps = 100;

    struct Purchase {
        address pool;
        bool claimed;
    }

    struct NFT {
        address collection;
        uint256 tokenId;
    }

    struct Round {
        uint256 nftIndexPlusOne;
        uint64 closedAt;
        address winner;
        address beneficiary;
        bool awarded;
        bytes32 liveAsk;
    }

    struct Pending {
        uint256 round;
        bytes32 questionHash;
        address intake;
        address signer;
        uint64 askedAt;
        bool active;
    }
    mapping(uint256 => Purchase) public purchases;
    mapping(address => bool) public purchasedFrom;
    mapping(bytes32 => bool) public recordedNFT;
    NFT[] public keptNFTs;
    uint256 public nextUnassigned;
    mapping(uint256 => Round) public rounds;
    mapping(bytes32 => Pending) public pending;
    address private expectedCollection;
    uint256 private expectedTokenId;

    constructor(address owner_, IMadToken mad_) OracleAttestationConsumer(0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982) {
        if (owner_ == address(0) || address(mad_) == address(0)) revert InvalidConfig();
        owner = owner_;
        mad = mad_;
        hook = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    receive() external payable {}

    function setFwaV2(IFWAV2 pool) external onlyOwner nonReentrant {
        if (address(pool) == address(0)) revert InvalidConfig();
        fwaV2 = pool;
        emit FwaV2Set(address(pool));
    }

    function setAcquisitionBounds(uint256 feeMargin, uint256 slippageBps) external onlyOwner nonReentrant {
        if (slippageBps > 10_000) revert InvalidConfig();
        acquisitionFeeMargin = feeMargin;
        acquisitionSlippageBps = slippageBps;
        emit AcquisitionBoundsSet(feeMargin, slippageBps);
    }

    /// @dev Fixed question, panel, timeouts and results cannot be changed by these protocol settings.
    function setOracleSettings(IIntake intake_, bytes32 action_, IERC20 asset_, uint256 maxPrice_, address signer_)
        external
        onlyOwner
        nonReentrant
    {
        if (address(intake_) == address(0) || action_ == bytes32(0) || address(asset_) == address(0)) {
            revert InvalidConfig();
        }
        intake = intake_;
        oracleAction = action_;
        oracleAsset = asset_;
        maxOraclePrice = maxPrice_;
        _setOracleSigner(signer_);
        emit OracleSettingsSet(address(intake_), action_, address(asset_), maxPrice_, signer_);
    }

    function nftBudget() public view returns (uint256) {
        return address(this).balance + IMadBudget(hook).nftEthClaims();
    }

    function buy() external nonReentrant returns (uint256 requestId) {
        IFWAV2 pool = fwaV2;
        if (pool.isPurchaseBlackout()) revert Blackout();
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice();
        if (total == 0 || nftBudget() < total) revert InsufficientBudget();
        if (address(this).balance < total) IMadBudget(hook).redeemNftETH(total - address(this).balance);
        uint256[] memory ids =
            pool.acquire{value: total}(address(this), 1, fee + acquisitionFeeMargin, 0, acquisitionSlippageBps);
        if (ids.length != 1 || purchases[ids[0]].pool != address(0)) revert InvalidAcquisition();
        requestId = ids[0];
        purchases[requestId].pool = address(pool);
        purchasedFrom[address(pool)] = true;
        emit Bought(requestId, address(pool), total);
    }

    function claim(uint256 requestId) external nonReentrant {
        Purchase storage purchase = purchases[requestId];
        if (purchase.pool == address(0) || purchase.claimed) revert InvalidAcquisition();
        IFWAV2 pool = IFWAV2(purchase.pool);
        IFWAV2.Acquisition memory a = pool.acquisitions(requestId);
        if (a.status != 2 || a.purchaser != address(this) || a.listingId == 0) revert InvalidAcquisition();
        IFWAV2.Listing memory l = pool.listings(a.listingId);
        if (l.status != 2 || l.purchaser != address(this) || l.collection == address(0)) revert InvalidAcquisition();
        if (block.timestamp >= uint256(l.allocatedAt) + pool.settlementWindow()) revert SettlementWindowClosed();
        bytes32 nftKey = keccak256(abi.encode(l.collection, l.tokenId));
        if (recordedNFT[nftKey]) revert InvalidAcquisition();
        purchase.claimed = true;
        recordedNFT[nftKey] = true;
        expectedCollection = l.collection;
        expectedTokenId = l.tokenId;
        pool.keepNFT(a.listingId);
        delete expectedCollection;
        delete expectedTokenId;
        if (IERC721(l.collection).ownerOf(l.tokenId) != address(this)) revert InvalidAcquisition();
        keptNFTs.push(NFT(l.collection, l.tokenId));
        emit Kept(requestId, l.collection, l.tokenId, keptNFTs.length - 1);
    }

    /// @notice A former V2 pool remains eligible for refunds after the owner selects its successor.
    function withdrawAcquisitionRefund(address pool) external nonReentrant returns (uint256 amount) {
        if (!purchasedFrom[pool]) revert InvalidAcquisition();
        uint256 beforeBalance = address(this).balance;
        IFWAV2(pool).withdrawAcquisitionRefund();
        amount = address(this).balance - beforeBalance;
        emit RefundReceived(pool, amount);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        if (msg.sender != expectedCollection || tokenId != expectedTokenId) revert InvalidAcquisition();
        return IERC721Receiver.onERC721Received.selector;
    }

    function hasUnassignedNFT() external view returns (bool) {
        return nextUnassigned < keptNFTs.length;
    }

    function assignRound(uint256 round) external onlyHook nonReentrant {
        if (rounds[round].nftIndexPlusOne != 0 || mad.leader(round) == address(0)) revert InvalidRound();
        (, uint64 last) = mad.roundBlocks(round);
        if (last != block.number || round >= mad.currentRound()) revert InvalidRound();
        if (nextUnassigned >= keptNFTs.length) revert NoNFT();
        uint256 index = nextUnassigned++;
        Round storage r = rounds[round];
        r.nftIndexPlusOne = index + 1;
        r.closedAt = uint64(block.timestamp);
        emit RoundAssigned(round, index, r.closedAt);
    }

    function question(uint256 round) public view returns (OracleQuestion.Question memory q) {
        (uint64 first, uint64 last) = mad.roundBlocks(round);
        if (rounds[round].nftIndexPlusOne == 0) revert InvalidRound();
        q.question = string.concat(
            "Who spent most MAD freezing wallets in round ",
            Strings.toString(round),
            " of token ",
            Strings.toHexString(address(mad)),
            " on Ethereum, blocks ",
            Strings.toString(first),
            " to ",
            Strings.toString(last),
            " inclusive? Sum cost in MAD base units from that token's Frozen(address indexed by, address indexed target, uint256 cost, uint64 until) events, grouped by by, ranked highest sum first. Ties: first to reach that total in block/transaction/log order."
        );
        q.chainId = 1;
        q.fromBlock = first;
        q.toBlock = last;
        q.answerType = OracleAttestation.ANSWER_ADDRESS_LIST;
        q.head = 1;
    }

    function questionBody(uint256 round) public view returns (bytes memory body, bytes32 questionHash) {
        OracleQuestion.Question memory q = question(round);
        questionHash = OracleQuestion.hash(q);
        body = OracleQuestion.body(q, 30, 20, 3600);
        // Chain evidence is the canonical default and omitted from the hashed document.
        // Make it explicit in the submitted body without changing that canonical hash.
        body[body.length - 1] = bytes1(",");
        body = bytes.concat(body, '"evidence":"chain"}');
    }

    function askWinner(uint256 round) external nonReentrant returns (bytes32 requestId) {
        Round storage r = rounds[round];
        if (
            r.nftIndexPlusOne == 0 || r.awarded || r.winner != address(0) || r.beneficiary != address(0)
                || block.timestamp >= uint256(r.closedAt) + FALLBACK_DELAY
        ) revert InvalidRound();
        (, uint64 last) = mad.roundBlocks(round);
        if (block.number < uint256(last) + CONFIRMATIONS) revert TooEarly();
        if (r.liveAsk != bytes32(0)) {
            Pending storage old = pending[r.liveAsk];
            if (old.active && block.timestamp < uint256(old.askedAt) + ASK_TIMEOUT) revert AskStillLive();
            old.active = false;
            emit AskSuperseded(r.liveAsk);
        }
        (bytes memory body, bytes32 hash) = questionBody(round);
        uint256 price = intake.priceOf(oracleAction, address(oracleAsset));
        if ((maxOraclePrice != 0 && price > maxOraclePrice) || oracleAsset.balanceOf(address(this)) < price) {
            revert InsufficientBudget();
        }
        oracleAsset.forceApprove(address(intake), price);
        requestId = intake.requestWithFailure(
            oracleAction,
            body,
            IIntake.Callback(address(this), this.onOracleResult.selector),
            this.onOracleFailure.selector,
            address(oracleAsset),
            price
        );
        oracleAsset.forceApprove(address(intake), 0);
        if (requestId == bytes32(0) || pending[requestId].intake != address(0)) revert InvalidResponse();
        pending[requestId] = Pending(round, hash, address(intake), oracleSigner, uint64(block.timestamp), true);
        r.liveAsk = requestId;
        emit Asked(round, requestId, hash, price);
    }

    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        Pending storage p = pending[requestId];
        if (!p.active || msg.sender != p.intake) revert UnknownRequest();
        Round storage r = rounds[p.round];
        if (
            r.liveAsk != requestId || r.winner != address(0) || r.beneficiary != address(0) || r.awarded
                || block.timestamp >= uint256(r.closedAt) + FALLBACK_DELAY
        ) revert InvalidResponse();
        (uint64 first, uint64 last) = mad.roundBlocks(p.round);
        if (
            a.questionHash != p.questionHash || a.chainId != 1 || a.fromBlock != first || a.toBlock != last
                || a.panelSize < 30 || a.quorum < 20 || a.agreed < a.quorum || a.agreed > a.panelSize
                || a.issuedAt < p.askedAt || a.expiresAt < a.issuedAt || a.expiresAt - a.issuedAt > 3600
                || p.signer != oracleSigner
        ) revert InvalidResponse();
        _verifyAttestation(a, signature);
        address[] memory answers = decodeAddressList(a);
        if (answers.length != 1 || answers[0] == address(0)) revert InvalidResponse();
        _consume(a.requestId);
        p.active = false;
        r.liveAsk = bytes32(0);
        r.winner = answers[0];
        emit WinnerStored(p.round, answers[0]);
    }

    function onOracleFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
        nonReentrant
    {
        Pending storage p = pending[requestId];
        if (!p.active || msg.sender != p.intake || rounds[p.round].liveAsk != requestId) revert UnknownRequest();
        if (status != 1 && status != 2) revert InvalidResponse();
        p.active = false;
        rounds[p.round].liveAsk = bytes32(0);
        emit AskFailed(p.round, requestId, status, reason);
    }

    function award(uint256 round) external nonReentrant returns (bool success) {
        Round storage r = rounds[round];
        if (r.nftIndexPlusOne == 0) revert InvalidRound();
        if (r.awarded) revert AlreadyAwarded();
        if (r.beneficiary == address(0)) {
            address winner = r.winner;
            if (winner == address(0)) {
                if (block.timestamp < uint256(r.closedAt) + FALLBACK_DELAY) revert TooEarly();
                winner = mad.leader(round);
            }
            r.beneficiary = winner;
            if (r.liveAsk != bytes32(0)) pending[r.liveAsk].active = false;
            r.liveAsk = bytes32(0);
        }
        NFT memory nft = keptNFTs[r.nftIndexPlusOne - 1];
        r.awarded = true;
        try IERC721(nft.collection).safeTransferFrom(address(this), r.beneficiary, nft.tokenId) {
            // A later, distinct purchase may acquire this physical NFT again after its winner resells it.
            // The old queue entry and round remain permanently awarded.
            delete recordedNFT[keccak256(abi.encode(nft.collection, nft.tokenId))];
            success = true;
        } catch {
            r.awarded = false;
        }
        emit AwardAttempt(round, r.beneficiary, success);
    }
}
