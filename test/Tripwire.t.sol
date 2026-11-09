// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { TripwireReactive } from "../src/TripwireReactive.sol";
import { TripwireRescuer } from "../src/TripwireRescuer.sol";
import { MockSystem, MockProxy, MockERC20, NoReturnToken, RevertingToken } from "./mocks/Mocks.sol";

contract TripwireTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant APPROVAL = 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925;
    uint256 internal constant APPROVAL_FOR_ALL = 0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31;
    uint256 internal constant TRANSFER = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    uint256 internal constant BASE = 84532;
    uint256 internal constant UNI = 1301;

    address internal wallet = makeAddr("wallet");
    address internal safe = makeAddr("safe");
    address internal drainer = makeAddr("drainer");
    address internal dex = makeAddr("dex");

    MockSystem internal sys;
    MockProxy internal proxy;
    TripwireReactive internal reactive;
    TripwireRescuer internal rescuerBase;
    TripwireRescuer internal rescuerUni;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    function setUp() public {
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM_ADDR));
        proxy = new MockProxy();

        reactive = new TripwireReactive(wallet, true);
        rescuerBase = new TripwireRescuer(IPayable(payable(address(proxy))), address(reactive), wallet, safe);
        rescuerUni = new TripwireRescuer(IPayable(payable(address(proxy))), address(reactive), wallet, safe);
        reactive.setRescuer(BASE, address(rescuerBase));
        reactive.setRescuer(UNI, address(rescuerUni));
        reactive.setTrusted(safe, true);
        reactive.setTrusted(dex, true);

        usdc = new MockERC20();
        weth = new MockERC20();
        usdc.mint(wallet, 1_000e6);
        weth.mint(wallet, 5 ether);

        vm.startPrank(wallet);
        rescuerBase.addToken(address(usdc));
        rescuerBase.addToken(address(weth));
        usdc.approve(address(rescuerBase), type(uint256).max);
        weth.approve(address(rescuerBase), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ helpers

    function _log(uint256 chainId, uint256 topic0, address from, address to, uint256 opCode, bytes memory data)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: chainId,
            contractAddress: address(usdc),
            topic0: topic0,
            topic1: uint256(uint160(from)),
            topic2: uint256(uint160(to)),
            topic3: 0,
            data: data,
            blockNumber: 1,
            opCode: opCode,
            blockHash: 0,
            txHash: 0xabc,
            logIndex: 0
        });
    }

    function _react(IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(log_);
    }

    function _erc20Approval(address spender, uint256 amount) internal view returns (IReactive.LogRecord memory) {
        return _log(BASE, APPROVAL, wallet, spender, 3, abi.encode(amount));
    }

    /// @dev Plays the network: delivers every recorded callback request through the proxy.
    function _deliverAll() internal {
        uint256 n = sys.requestCount();
        for (uint256 i = 0; i < n; i++) {
            ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.request(i);
            assertTrue(proxy.deliver(c.recipient, address(reactive), c.payload), "callback failed");
        }
    }

    // ------------------------------------------------------------ subscriptions

    function test_SubscribesPerChainToWalletEvents() public view {
        // 2 chains x (Approval, ApprovalForAll, Transfer)
        assertEq(sys.subCount(), 6);
        (uint256 chainId, address c, uint256 topic0, uint256 topic1) = sys.subs(0);
        assertEq(chainId, BASE);
        assertEq(c, address(0));
        assertEq(topic0, APPROVAL);
        assertEq(topic1, uint256(uint160(wallet)));
    }

    function test_NoTransferSubscriptionWhenDisabled() public {
        TripwireReactive r = new TripwireReactive(wallet, false);
        uint256 before = sys.subCount();
        r.setRescuer(BASE, address(rescuerBase));
        assertEq(sys.subCount() - before, 2);
    }

    function test_SetRescuerGuards() public {
        vm.expectRevert(abi.encodeWithSelector(TripwireReactive.ChainAlreadySet.selector, BASE));
        reactive.setRescuer(BASE, address(1));

        vm.prank(drainer);
        vm.expectRevert(TripwireReactive.NotOwner.selector);
        reactive.setRescuer(7, address(1));

        for (uint256 i = 0; i < 6; i++) {
            reactive.setRescuer(100 + i, address(uint160(100 + i)));
        }
        vm.expectRevert(TripwireReactive.TooManyChains.selector);
        reactive.setRescuer(999, address(1));
    }

    // ------------------------------------------------------------ react: what trips

    function test_UntrustedApprovalTripsAndRequestsEveryChain() public {
        vm.expectEmit(true, true, true, true);
        emit TripwireReactive.Tripped(BASE, drainer, address(usdc), TripwireReactive.Reason.Approval, 0xabc);
        _react(_erc20Approval(drainer, type(uint256).max));

        assertFalse(reactive.armed());
        assertEq(sys.requestCount(), 2);
        assertEq(sys.request(0).chainId, BASE);
        assertEq(sys.request(0).recipient, address(rescuerBase));
        assertEq(sys.request(1).chainId, UNI);
        assertEq(sys.request(1).recipient, address(rescuerUni));
        assertGe(sys.request(0).gasLimit, 100_000);
    }

    function test_UntrustedApprovalForAllTrips() public {
        _react(_log(UNI, APPROVAL_FOR_ALL, wallet, drainer, 3, abi.encode(true)));
        assertFalse(reactive.armed());
        assertEq(sys.requestCount(), 2);
    }

    function test_Erc721ApprovalTrips() public {
        _react(_log(BASE, APPROVAL, wallet, drainer, 4, ""));
        assertFalse(reactive.armed());
    }

    function test_UntrustedTransferTrips() public {
        _react(_log(BASE, TRANSFER, wallet, drainer, 3, abi.encode(uint256(1))));
        assertFalse(reactive.armed());
    }

    // ------------------------------------------------------------ react: what does not

    function test_TrustedSpenderDoesNotTrip() public {
        _react(_erc20Approval(dex, type(uint256).max));
        _react(_erc20Approval(address(rescuerBase), type(uint256).max));
        assertTrue(reactive.armed());
        assertEq(sys.requestCount(), 0);
    }

    function test_RevokesDoNotTrip() public {
        _react(_erc20Approval(drainer, 0));
        _react(_log(BASE, APPROVAL_FOR_ALL, wallet, drainer, 3, abi.encode(false)));
        _react(_log(BASE, APPROVAL, wallet, address(0), 4, ""));
        assertTrue(reactive.armed());
    }

    function test_TransferToSafeDoesNotTrip() public {
        _react(_log(BASE, TRANSFER, wallet, safe, 3, abi.encode(uint256(1))));
        assertTrue(reactive.armed());
    }

    function test_TransferIgnoredWhenNotWatching() public {
        TripwireReactive r = new TripwireReactive(wallet, false);
        r.setRescuer(BASE, address(rescuerBase));
        vm.prank(SYSTEM_ADDR);
        r.react(_log(BASE, TRANSFER, wallet, drainer, 3, abi.encode(uint256(1))));
        assertTrue(r.armed());
    }

    function test_IgnoresOtherWalletsUnknownChainsAndOddLogs() public {
        _react(_log(BASE, APPROVAL, drainer, drainer, 3, abi.encode(uint256(1)))); // someone else's approval
        _react(_log(424242, APPROVAL, wallet, drainer, 3, abi.encode(uint256(1)))); // chain with no rescuer
        _react(_log(BASE, APPROVAL, wallet, drainer, 2, abi.encode(uint256(1)))); // wrong topic count
        _react(_log(BASE, APPROVAL, wallet, drainer, 3, "")); // malformed data must not revert
        _react(_log(BASE, 0x1234, wallet, drainer, 3, abi.encode(uint256(1)))); // unknown event
        assertTrue(reactive.armed());
        assertEq(sys.requestCount(), 0);
    }

    function test_TripsOnlyOnceUntilRearmed() public {
        _react(_erc20Approval(drainer, 1));
        _react(_erc20Approval(drainer, 1));
        assertEq(sys.requestCount(), 2);

        reactive.rearm();
        _react(_erc20Approval(drainer, 1));
        assertEq(sys.requestCount(), 4);
    }

    function test_ReactOnlyFromSystem() public {
        IReactive.LogRecord memory l = _erc20Approval(drainer, 1);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        reactive.react(l);
    }

    function test_PanicRequestsRescuesAndIsOwnerOnly() public {
        vm.prank(drainer);
        vm.expectRevert(TripwireReactive.NotOwner.selector);
        reactive.panic();

        reactive.panic();
        assertFalse(reactive.armed());
        assertEq(sys.requestCount(), 2);
    }

    // ------------------------------------------------------------ rescuer

    function test_EndToEnd_ApprovalToDrainerMovesFundsToSafe() public {
        _react(_erc20Approval(drainer, type(uint256).max));
        _deliverAll();

        assertEq(usdc.balanceOf(wallet), 0);
        assertEq(weth.balanceOf(wallet), 0);
        assertEq(usdc.balanceOf(safe), 1_000e6);
        assertEq(weth.balanceOf(safe), 5 ether);
        assertEq(usdc.balanceOf(address(rescuerBase)), 0);
    }

    function test_RescueTakesMinOfBalanceAndAllowance() public {
        vm.prank(wallet);
        usdc.approve(address(rescuerBase), 400e6);
        reactive.panic();
        _deliverAll();
        assertEq(usdc.balanceOf(safe), 400e6);
        assertEq(usdc.balanceOf(wallet), 600e6);
    }

    function test_RescueRejectsDirectCallers() public {
        vm.prank(drainer);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, drainer, address(proxy)));
        rescuerBase.rescue(address(reactive), BASE, drainer);
    }

    function test_RescueRejectsOtherReactiveContracts() public {
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, drainer, address(reactive))
        );
        rescuerBase.rescue(drainer, BASE, drainer);
    }

    function test_BrokenTokenDoesNotBlockTheOthers() public {
        RevertingToken bad = new RevertingToken();
        bad.mint(wallet, 10);
        NoReturnToken usdt = new NoReturnToken();
        usdt.mint(wallet, 77);
        address eoaToken = makeAddr("notAContract");

        vm.startPrank(wallet);
        rescuerUni.addToken(address(bad));
        rescuerUni.addToken(eoaToken);
        rescuerUni.addToken(address(usdt));
        bad.approve(address(rescuerUni), type(uint256).max);
        usdt.approve(address(rescuerUni), type(uint256).max);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(rescuerUni));
        emit TripwireRescuer.RescueFailed(address(bad), 10);
        vm.expectEmit(true, false, false, true, address(rescuerUni));
        emit TripwireRescuer.Rescued(address(usdt), 77);
        vm.prank(address(proxy));
        rescuerUni.rescue(address(reactive), UNI, drainer);
        assertEq(usdt.balanceOf(safe), 77);
        assertEq(bad.balanceOf(wallet), 10);
    }

    function test_ManualSweepBySafeOnly() public {
        vm.prank(wallet);
        vm.expectRevert(TripwireRescuer.NotSafe.selector);
        rescuerBase.sweep();

        vm.prank(safe);
        rescuerBase.sweep();
        assertEq(usdc.balanceOf(safe), 1_000e6);
    }

    function test_TokenListRules() public {
        vm.prank(drainer);
        vm.expectRevert(TripwireRescuer.NotWalletOrSafe.selector);
        rescuerBase.addToken(address(1));

        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(TripwireRescuer.AlreadyAdded.selector, address(usdc)));
        rescuerBase.addToken(address(usdc));

        // A stolen wallet key must not be able to shrink the protection.
        vm.prank(wallet);
        vm.expectRevert(TripwireRescuer.NotSafe.selector);
        rescuerBase.removeToken(address(usdc));

        vm.prank(safe);
        rescuerBase.removeToken(address(usdc));
        assertEq(rescuerBase.tokenCount(), 1);
        assertFalse(rescuerBase.isToken(address(usdc)));

        vm.startPrank(safe);
        for (uint256 i = 0; i < 15; i++) {
            rescuerBase.addToken(address(uint160(1000 + i)));
        }
        vm.expectRevert(TripwireRescuer.TooManyTokens.selector);
        rescuerBase.addToken(address(9999));
        vm.stopPrank();
    }

    function test_FullTokenListFitsInCallbackGas() public {
        vm.startPrank(wallet);
        for (uint256 i = 0; i < 16; i++) {
            MockERC20 t = new MockERC20();
            t.mint(wallet, 1 ether);
            t.approve(address(rescuerUni), type(uint256).max);
            rescuerUni.addToken(address(t));
        }
        vm.stopPrank();

        vm.prank(address(proxy));
        uint256 g = gasleft();
        rescuerUni.rescue(address(reactive), UNI, drainer);
        uint256 used = g - gasleft();
        // Requested limit is 1.5M; leave room for the proxy's own overhead.
        emit log_named_uint("gas for 16-token rescue", used);
        assertLt(used, 1_200_000);
    }
}
