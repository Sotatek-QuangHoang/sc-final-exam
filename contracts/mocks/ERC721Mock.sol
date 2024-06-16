// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ERC721Mock is ERC721, Ownable {
    uint256 private _currentTokenId = 0;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}

    function mint(address to) public onlyOwner returns (uint256) {
        uint256 newTokenId = _currentTokenId;
        _mint(to, newTokenId);
        _currentTokenId += 1;
        return newTokenId;
    }
}
