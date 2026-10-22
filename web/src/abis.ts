import { parseAbi, erc20Abi, type Abi } from "viem";
import tokenSource from "./tokenAbi.json";
import hookSource from "./hookAbi.json";
import rewardsSource from "./rewardsAbi.json";
import routerSource from "./routerAbi.json";
import quoterSource from "./quoterAbi.json";
import stateSource from "./stateViewAbi.json";
import permitSource from "./permit2Abi.json";
export const tokenAbi = tokenSource as Abi;
export const hookAbi = hookSource as Abi;
export const rewardsAbi = rewardsSource as Abi;
export const routerAbi = routerSource as Abi;
export const quoterAbi = quoterSource as Abi;
export const stateAbi = stateSource as Abi;
export const permitAbi = permitSource as Abi;
export { erc20Abi };
// IFWAV2 and IIntake signatures from the project's pinned Solidity interfaces.
export const fwaV2Abi = parseAbi([
  "function quoteAcquisitionPrice() view returns (uint256 fee,uint256 vrf,uint256 total)",
  "function isPurchaseBlackout() view returns (bool)",
  "function acquisitions(uint256 requestId) view returns ((address purchaser,uint256 requestBlock,uint256 priceEscrowed,uint256 listingId,uint8 status))",
  "function listings(uint256 listingId) view returns ((address collection,address depositor,address purchaser,uint256 tokenId,uint256 weight,uint256 value,uint256 feeShare,uint256 feeDebt,uint256 slot,uint64 allocatedAt,uint8 status))",
  "function settlementWindow() view returns (uint256)",
  "function acquisitionRefundCredit(address purchaser) view returns (uint256)",
]);
export const intakeAbi = parseAbi([
  "function priceOf(bytes32 action,address asset) view returns (uint256)",
]);
export const hubAbi = parseAbi([
  "function projects(uint256 projectId) view returns (address creator,address receiver)",
]);
export const receiverAbi = parseAbi([
  "function playground() view returns (address)",
  "function projectId() view returns (uint256)",
]);
