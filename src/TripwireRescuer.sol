// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @title Tripwire (destination side)
/// @notice Holds an ERC-20 allowance from the protected wallet. When TripwireReactive reports an
///         incident, it pulls every registered token from the wallet to a fixed safe address.
/// @dev    `wallet` and `safe` are immutable, so a stolen wallet key cannot redirect a rescue.
///         The contract never keeps tokens: they go wallet -> safe in one transferFrom.
contract TripwireRescuer is AbstractCallback {
    uint256 public constant MAX_TOKENS = 16;

    address public immutable wallet;
    address public immutable safe;

    address[] public tokens;
    mapping(address => bool) public isToken;

    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event RescueStarted(uint256 indexed originChainId, address indexed counterparty, bool manual);
    event Rescued(address indexed token, uint256 amount);
    event RescueFailed(address indexed token, uint256 amount);

    error NotWalletOrSafe();
    error NotSafe();
    error ZeroAddress();
    error TooManyTokens();
    error AlreadyAdded(address token);
    error NotAdded(address token);

    constructor(IPayable callbackProxy_, address reactive_, address wallet_, address safe_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        if (wallet_ == address(0) || safe_ == address(0)) revert ZeroAddress();
        wallet = wallet_;
        safe = safe_;
    }

    // ---------------------------------------------------------------- token list

    /// @notice Adds a token to the rescue list. The wallet must also approve this contract for it.
    /// @dev    Adding is harmless even from a compromised wallet key: tokens only ever go to `safe`.
    function addToken(address token_) external {
        if (msg.sender != wallet && msg.sender != safe) revert NotWalletOrSafe();
        if (token_ == address(0)) revert ZeroAddress();
        if (isToken[token_]) revert AlreadyAdded(token_);
        if (tokens.length >= MAX_TOKENS) revert TooManyTokens();
        isToken[token_] = true;
        tokens.push(token_);
        emit TokenAdded(token_);
    }

    /// @notice Removes a token. Only the safe address may shrink the protection.
    function removeToken(address token_) external {
        if (msg.sender != safe) revert NotSafe();
        if (!isToken[token_]) revert NotAdded(token_);
        isToken[token_] = false;
        uint256 n = tokens.length;
        for (uint256 i = 0; i < n; i++) {
            if (tokens[i] == token_) {
                tokens[i] = tokens[n - 1];
                tokens.pop();
                break;
            }
        }
        emit TokenRemoved(token_);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ---------------------------------------------------------------- rescue

    /// @notice Callback from Reactive Network. `reactive_` is injected by the callback proxy.
    function rescue(address reactive_, uint256 originChainId_, address counterparty_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        emit RescueStarted(originChainId_, counterparty_, false);
        _sweep();
    }

    /// @notice Fallback that does not depend on Reactive Network: the safe address can pull directly.
    function sweep() external {
        if (msg.sender != safe) revert NotSafe();
        emit RescueStarted(block.chainid, address(0), true);
        _sweep();
    }

    /// @notice Settles outstanding callback debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @dev Never reverts on a bad token: a failed callback is still billed and would strand
    ///      every other token on the list.
    function _sweep() internal {
        uint256 n = tokens.length; // bounded by MAX_TOKENS
        for (uint256 i = 0; i < n; i++) {
            address token = tokens[i];
            uint256 amount = _rescuable(token);
            if (amount == 0) continue;

            (bool ok, bytes memory ret) =
                token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", wallet, safe, amount));
            // Accept tokens that return nothing (USDT-style) as well as those returning true.
            if (ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (bool))))) {
                emit Rescued(token, amount);
            } else {
                emit RescueFailed(token, amount);
            }
        }
    }

    /// @dev min(balance, allowance), tolerating tokens whose view calls revert.
    function _rescuable(address token_) internal view returns (uint256) {
        if (token_.code.length == 0) return 0;
        try IERC20Minimal(token_).balanceOf(wallet) returns (uint256 balance) {
            try IERC20Minimal(token_).allowance(wallet, address(this)) returns (uint256 allowed) {
                return balance < allowed ? balance : allowed;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }
}
