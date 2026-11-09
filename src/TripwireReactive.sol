// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title Tripwire (reactive side)
/// @notice Watches one wallet on several chains. The moment that wallet grants an approval to,
///         or (optionally) sends tokens to, an address that is not on its allowlist, Tripwire asks
///         every chain's TripwireRescuer to move the wallet's remaining tokens to a safe address.
/// @dev    Lives on Reactive Network. It never holds user tokens and cannot choose where they go:
///         the safe address is fixed inside each TripwireRescuer.
contract TripwireReactive is AbstractReactive {
    // keccak256("Approval(address,address,uint256)") — shared by ERC-20 and ERC-721.
    uint256 internal constant APPROVAL_TOPIC_0 = 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925;
    // keccak256("ApprovalForAll(address,address,bool)")
    uint256 internal constant APPROVAL_FOR_ALL_TOPIC_0 =
        0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31;
    // keccak256("Transfer(address,address,uint256)")
    uint256 internal constant TRANSFER_TOPIC_0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    uint64 internal constant CALLBACK_GAS_LIMIT = 1_500_000;
    uint256 public constant MAX_CHAINS = 8;

    enum Reason { Approval, ApprovalForAll, Transfer, Manual }

    address public immutable owner;
    /// @notice The wallet being protected.
    address public immutable wallet;
    /// @notice Whether outgoing transfers to unknown recipients also trip the wire.
    bool public immutable watchTransfers;

    /// @notice True while the wire is live. Flips to false when tripped, so one incident
    ///         produces exactly one round of rescues.
    bool public armed = true;

    uint256[] public chainIds;
    mapping(uint256 chainId => address rescuer) public rescuers;
    /// @notice Spenders and recipients the wallet is allowed to deal with.
    mapping(address => bool) public trusted;

    event RescuerSet(uint256 indexed chainId, address indexed rescuer);
    event TrustedSet(address indexed account, bool trusted);
    event Tripped(
        uint256 indexed originChainId,
        address indexed counterparty,
        address indexed token,
        Reason reason,
        uint256 originTxHash
    );
    event Rearmed();

    error NotOwner();
    error ZeroAddress();
    error TooManyChains();
    error ChainAlreadySet(uint256 chainId);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address wallet_, bool watchTransfers_) payable {
        if (wallet_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        wallet = wallet_;
        watchTransfers = watchTransfers_;
    }

    // ---------------------------------------------------------------- setup

    /// @notice Registers the rescuer for a chain and starts watching the wallet there.
    /// @dev    One rescuer per chain, set once: the rescuer authenticates this contract with an
    ///         immutable address, so swapping it means a fresh deployment anyway.
    function setRescuer(uint256 chainId_, address rescuer_) external onlyOwner {
        if (rescuer_ == address(0)) revert ZeroAddress();
        if (rescuers[chainId_] != address(0)) revert ChainAlreadySet(chainId_);
        if (chainIds.length >= MAX_CHAINS) revert TooManyChains();

        rescuers[chainId_] = rescuer_;
        chainIds.push(chainId_);
        // The wallet has to approve the rescuer; that approval must not trip the wire.
        trusted[rescuer_] = true;
        emit RescuerSet(chainId_, rescuer_);
        emit TrustedSet(rescuer_, true);

        uint256 walletTopic = uint256(uint160(wallet));
        // Any contract on that chain, events where the wallet is the first indexed argument
        // (owner for approvals, sender for transfers).
        SYSTEM.subscribe(chainId_, address(0), APPROVAL_TOPIC_0, walletTopic, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId_, address(0), APPROVAL_FOR_ALL_TOPIC_0, walletTopic, REACTIVE_IGNORE, REACTIVE_IGNORE);
        if (watchTransfers) {
            SYSTEM.subscribe(chainId_, address(0), TRANSFER_TOPIC_0, walletTopic, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    function setTrusted(address account_, bool trusted_) external onlyOwner {
        trusted[account_] = trusted_;
        emit TrustedSet(account_, trusted_);
    }

    /// @notice Re-enables the wire after an incident has been dealt with.
    function rearm() external onlyOwner {
        armed = true;
        emit Rearmed();
    }

    /// @notice Manual trigger: rescue everything now, on every chain.
    function panic() external onlyOwner {
        armed = false;
        emit Tripped(block.chainid, address(0), address(0), Reason.Manual, 0);
        _requestRescues(block.chainid, address(0));
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    function chainCount() external view returns (uint256) {
        return chainIds.length;
    }

    // ---------------------------------------------------------------- react

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        // Never revert here: a reverting react() is still billed. Unmatched logs fall through.
        if (!armed) return;
        if (address(uint160(log_.topic1)) != wallet) return;
        if (rescuers[log_.chainId] == address(0)) return;

        address counterparty = address(uint160(log_.topic2));
        Reason reason;

        if (log_.topic0 == APPROVAL_TOPIC_0) {
            if (log_.opCode == 3) {
                // ERC-20: the amount is the only non-indexed field. A zero amount is a revoke.
                if (log_.data.length < 32 || abi.decode(log_.data, (uint256)) == 0) return;
            } else if (log_.opCode == 4) {
                // ERC-721: approved address is indexed; zero clears the approval.
                if (counterparty == address(0)) return;
            } else {
                return;
            }
            reason = Reason.Approval;
        } else if (log_.topic0 == APPROVAL_FOR_ALL_TOPIC_0) {
            if (log_.opCode != 3 || log_.data.length < 32 || !abi.decode(log_.data, (bool))) return;
            reason = Reason.ApprovalForAll;
        } else if (log_.topic0 == TRANSFER_TOPIC_0 && watchTransfers) {
            if (log_.opCode != 3 && log_.opCode != 4) return;
            reason = Reason.Transfer;
        } else {
            return;
        }

        if (trusted[counterparty]) return;

        armed = false;
        emit Tripped(log_.chainId, counterparty, log_.contractAddress, reason, log_.txHash);
        _requestRescues(log_.chainId, counterparty);
    }

    function _requestRescues(uint256 originChainId_, address counterparty_) internal {
        // First argument is a placeholder: the network overwrites it with this contract's address.
        bytes memory payload =
            abi.encodeWithSignature("rescue(address,uint256,address)", address(0), originChainId_, counterparty_);

        uint256 n = chainIds.length; // bounded by MAX_CHAINS
        for (uint256 i = 0; i < n; i++) {
            uint256 chainId = chainIds[i];
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: chainId,
                    recipient: rescuers[chainId],
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
        }
    }
}
