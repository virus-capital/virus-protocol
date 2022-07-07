//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface vToken {
    function mint(uint mintAmount) external returns (uint);
    function balanceOf(address) external returns (uint256);
    function balanceOfUnderlying(address account) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function redeem(uint redeemTokens) external returns (uint);
}

interface IPool {
    function incLimit(address to, uint256 amount) external;
}

interface IVirusToken is IERC20Upgradeable {
    function mint(address to, uint256 amount) external;
    function burn(address to, uint256 amount) external;
}