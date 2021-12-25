// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.11;

import "@openzeppelin/token/ERC20/ERC20.sol";

contract MintableERC20 is ERC20
{
    // solhint-disable-next-line no-empty-blocks
    constructor (string memory aName, string memory aSymbol) ERC20(aName, aSymbol) {}

    function Mint(address aReceiver, uint256 aAmount) external
    {
        _mint(aReceiver, aAmount);
    }
}
