// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pure formatting helpers for scenario-test `console2.log` output.
///         Converts 1e18-scaled USD and signed basis-point values into human-readable strings.
library Fmt {
    /// @notice `$63,750.00` from a uint256 USD value in 1e18 fixed-point.
    function usd(uint256 v1e18) internal pure returns (string memory) {
        uint256 whole = v1e18 / 1e18;
        uint256 cents = (v1e18 % 1e18) / 1e16;
        return string.concat("$", _withCommas(whole), ".", _pad2(cents));
    }

    /// @notice `+$1,904.87` or `-$521.91` from a signed 1e18 USD value.
    function iusd(int256 v1e18) internal pure returns (string memory) {
        if (v1e18 < 0) return string.concat("-", usd(uint256(-v1e18)));
        return string.concat("+", usd(uint256(v1e18)));
    }

    /// @notice `19.47%` or `-73.84%` from signed basis points.
    function aprPct(int256 bps) internal pure returns (string memory) {
        if (bps < 0) {
            uint256 u = uint256(-bps);
            return string.concat("-", toStr(u / 100), ".", _pad2(u % 100), "%");
        }
        uint256 p = uint256(bps);
        return string.concat(toStr(p / 100), ".", _pad2(p % 100), "%");
    }

    /// @notice Plain uint → decimal string, no commas.
    function toStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 temp = v;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits -= 1;
            buf[digits] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(buf);
    }

    /// @notice Signed int → decimal string with leading sign for negatives.
    function toIStr(int256 v) internal pure returns (string memory) {
        if (v < 0) return string.concat("-", toStr(uint256(-v)));
        return toStr(uint256(v));
    }

    // ---------- internals ----------

    function _pad2(uint256 v) private pure returns (string memory) {
        if (v < 10) return string.concat("0", toStr(v));
        return toStr(v);
    }

    function _withCommas(uint256 n) private pure returns (string memory) {
        string memory s = toStr(n);
        bytes memory b = bytes(s);
        if (b.length <= 3) return s;
        uint256 commas = (b.length - 1) / 3;
        bytes memory out = new bytes(b.length + commas);
        uint256 j = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (i > 0 && (b.length - i) % 3 == 0) {
                out[j++] = ",";
            }
            out[j++] = b[i];
        }
        return string(out);
    }
}
