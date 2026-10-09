// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The launch token: fixed supply, plain transfers, minted once to whoever deploys it
/// (the IMD launch factory). Nothing else.
contract Marginalia is ERC20 {
    constructor() ERC20("Marginalia", "MARG") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
