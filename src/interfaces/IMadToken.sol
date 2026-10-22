// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IMadToken {
    function launchFactory() external view returns (address);
    function bindHook() external;
    function closeRound() external returns (uint256 round);
    function currentRound() external view returns (uint256);
    function roundBlocks(uint256 round) external view returns (uint64 first, uint64 last);
    function leader(uint256 round) external view returns (address);
    function spent(uint256 round, address account) external view returns (uint256);
}

interface IMadBinding {
    function launchFactory() external view returns (address);
    function mad() external view returns (IMadToken);
    function bindingActive() external view returns (bool);
}
