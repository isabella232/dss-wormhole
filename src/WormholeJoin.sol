// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.9;

import "./WormholeGUID.sol";

interface VatLike {
    function dai(address) external view returns (uint256);
    function live() external view returns (uint256);
    function urns(bytes32, address) external view returns (uint256, uint256);
    function frob(bytes32, address, address, address, int256, int256) external;
    function hope(address) external;
    function move(address, address, uint256) external;
    function nope(address) external;
    function slip(bytes32, address, int256) external;
}

interface DaiJoinLike {
    function dai() external view returns (TokenLike);
    function exit(address, uint256) external;
    function join(address, uint256) external;
}

interface TokenLike {
    function approve(address, uint256) external returns (bool);
}

interface FeesLike {
    function getFee(WormholeGUID calldata, uint256, int256, uint256, uint256) external view returns (uint256);
}

// Primary control for extending Wormhole credit
contract WormholeJoin {
    mapping (address =>        uint256) public wards;     // Auth
    mapping (bytes32 =>        address) public fees;      // Fees contract per source domain
    mapping (bytes32 =>        uint256) public line;      // Debt ceiling per source domain
    mapping (bytes32 =>         int256) public debt;      // Outstanding debt per source domain (can be < 0 when settlement occurs before mint)
    mapping (bytes32 => WormholeStatus) public wormholes; // Approved wormholes and pending unpaid

    address public vow;

    VatLike     immutable public vat;
    DaiJoinLike immutable public daiJoin;
    bytes32     immutable public ilk;
    bytes32     immutable public domain;

    uint256 constant public WAD = 10 ** 18;
    uint256 constant public RAY = 10 ** 27;

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, bytes32 indexed domain, address data);
    event File(bytes32 indexed what, bytes32 indexed domain, uint256 data);
    event Register(bytes32 indexed hashGUID, WormholeGUID wormholeGUID);
    event Withdraw(bytes32 indexed hashGUID, WormholeGUID wormholeGUID, uint256 amount, uint256 maxFeePercentage);
    event Settle(bytes32 indexed sourceDomain, uint256 batchedDaiToFlush);

    struct WormholeStatus {
        bool    blessed;
        uint248 pending;
    }

    // --- Errors ---
    error NotAuthorized(address sender);
    error FileUnrecognizedParam(bytes32 what);
    error Overflow(uint256 amount);
    error IncorrectDomain(bytes32 domain);
    error MaxFeeExceeded(uint256 fee, uint256 maxFee);
    error AlreadyBlessed(bytes32 hashGUID);
    error SenderNotOperator(address sender, address operator);

    constructor(address vat_, address daiJoin_, bytes32 ilk_, bytes32 domain_) {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        vat = VatLike(vat_);
        daiJoin = DaiJoinLike(daiJoin_);
        vat.hope(daiJoin_);
        daiJoin.dai().approve(daiJoin_, type(uint256).max);
        ilk = ilk_;
        domain = domain_;
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x <= y ? x : y;
    }

    modifier auth {
        if (wards[msg.sender] != 1) revert NotAuthorized(msg.sender);
        _;
    }

    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function file(bytes32 what, address data) external auth {
        if (what == "vow") {
            vow = data;
        } else {
            revert FileUnrecognizedParam(what);
        }
        emit File(what, data);
    }

    function file(bytes32 what, bytes32 domain_, address data) external auth {
        if (what == "fees") {
            fees[domain_] = data;
        } else {
            revert FileUnrecognizedParam(what);
        }
        emit File(what, domain_, data);
    }

    function file(bytes32 what, bytes32 domain_, uint256 data) external auth {
        if (what == "line") {
            if (data > 2 ** 255 - 1) revert Overflow(data);
            line[domain_] = data;
        } else {
            revert FileUnrecognizedParam(what);
        }
        emit File(what, domain_, data);
    }

    /**
    * @dev Internal function that executes the mint after a wormhole is registered
    * @param wormholeGUID Struct which contains the whole wormhole data
    * @param hashGUID Hash of the prev struct
    * @param maxFeePercentage Max percentage of the withdrawn amount (in WAD) to be paid as fee (e.g 1% = 0.01 * WAD)
    **/
    function _mint(WormholeGUID calldata wormholeGUID, bytes32 hashGUID, uint256 maxFeePercentage) internal {
        if (wormholeGUID.targetDomain != domain) revert IncorrectDomain(wormholeGUID.targetDomain);
        bool vatLive = vat.live() == 1;

        uint256 line_ = vatLive ? line[wormholeGUID.sourceDomain] : 0;

        int256 debt_ = debt[wormholeGUID.sourceDomain];

        // Stop execution if there isn't anything available to withdraw
        uint248 pending = wormholes[hashGUID].pending;
        if (int256(line_) <= debt_ || pending == 0) {
            emit Withdraw(hashGUID, wormholeGUID, 0, maxFeePercentage);
            return;
        }

        uint256 amtToTake = _min(
                                pending,
                                uint256(int256(line_) - debt_)
                            );

        uint256 fee = vatLive ? FeesLike(fees[wormholeGUID.sourceDomain]).getFee(wormholeGUID, line_, debt_, pending, amtToTake) : 0;
        uint256 maxFee = maxFeePercentage * amtToTake / WAD;
        if (fee > maxFee) revert MaxFeeExceeded(fee, maxFee);

        // No need of overflow check here as amtToTake is bounded by wormholes[hashGUID].pending
        // which is already a uint248. Also int256 >> uint248. Then both castings are safe.
        debt[wormholeGUID.sourceDomain] +=  int256(amtToTake);
        wormholes[hashGUID].pending     -= uint248(amtToTake);

        if (debt_ >= 0 || uint256(-debt_) < amtToTake) {
            uint256 amtToGenerate = debt_ < 0
                                    ? uint256(int256(amtToTake) + debt_) // amtToTake - |debt_|
                                    : amtToTake;
            // amtToGenerate doesn't need overflow check as it is bounded by amtToTake
            vat.slip(ilk, address(this), int256(amtToGenerate));
            vat.frob(ilk, address(this), address(this), address(this), int256(amtToGenerate), int256(amtToGenerate));
        }
        daiJoin.exit(bytes32ToAddress(wormholeGUID.receiver), amtToTake - fee);

        if (fee > 0) {
            vat.move(address(this), vow, fee * RAY);
        }

        emit Withdraw(hashGUID, wormholeGUID, amtToTake, maxFeePercentage);
    }

    /**
    * @dev External authed function that registers the wormwhole and executes the mint after
    * @param wormholeGUID Struct which contains the whole wormhole data
    * @param maxFeePercentage Max percentage of the withdrawn amount (in WAD) to be paid as fee (e.g 1% = 0.01 * WAD)
    **/
    function requestMint(WormholeGUID calldata wormholeGUID, uint256 maxFeePercentage) external auth {
        bytes32 hashGUID = getGUIDHash(wormholeGUID);
        if (wormholes[hashGUID].blessed) revert AlreadyBlessed(hashGUID);
        wormholes[hashGUID].blessed = true;
        wormholes[hashGUID].pending = wormholeGUID.amount;
        emit Register(hashGUID, wormholeGUID);
        _mint(wormholeGUID, hashGUID, maxFeePercentage);
    }

    /**
    * @dev External function that executes the mint of any pending and available amount (only callable by operator)
    * @param wormholeGUID Struct which contains the whole wormhole data
    * @param maxFeePercentage Max percentage of the withdrawn amount (in WAD) to be paid as fee (e.g 1% = 0.01 * WAD)
    **/
    function mintPending(WormholeGUID calldata wormholeGUID, uint256 maxFeePercentage) external {
        if (bytes32ToAddress(wormholeGUID.operator) != msg.sender) revert SenderNotOperator(msg.sender, bytes32ToAddress(wormholeGUID.operator));
        _mint(wormholeGUID, getGUIDHash(wormholeGUID), maxFeePercentage);
    }

    /**
    * @dev External function that repays debt with DAI previously pushed to this contract (in general coming from the bridges)
    * @param sourceDomain domain where the DAI is coming from
    * @param batchedDaiToFlush Amount of DAI that is being processed for repayment
    **/
    function settle(bytes32 sourceDomain, uint256 batchedDaiToFlush) external {
        if (batchedDaiToFlush > 2 ** 255) revert Overflow(batchedDaiToFlush);
        daiJoin.join(address(this), batchedDaiToFlush);
        if (vat.live() == 1) {
            (, uint256 art) = vat.urns(ilk, address(this)); // rate == RAY => normalized debt == actual debt
            uint256 amtToPayBack = _min(batchedDaiToFlush, art);
            vat.frob(ilk, address(this), address(this), address(this), -int256(amtToPayBack), -int256(amtToPayBack));
            vat.slip(ilk, address(this), -int256(amtToPayBack));
        }
        debt[sourceDomain] -= int256(batchedDaiToFlush);
        emit Settle(sourceDomain, batchedDaiToFlush);
    }
}
