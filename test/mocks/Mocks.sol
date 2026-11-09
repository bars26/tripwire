// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @dev Stands in for the system contract at 0x8888…8888. Records subscriptions and callback requests.
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
    }

    Sub[] public subs;
    ISystemContract.CallbackConfiguration_V_1_0[] internal _requests;

    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256 topic1_, uint256, uint256)
        external
    {
        subs.push(Sub(chainId_, contract_, topic0_, topic1_));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        _requests.push(config_);
    }

    function subCount() external view returns (uint256) {
        return subs.length;
    }

    function requestCount() external view returns (uint256) {
        return _requests.length;
    }

    function request(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return _requests[i];
    }
}

/// @dev Stands in for a destination chain's callback proxy.
contract MockProxy {
    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Mirrors the real proxy: overwrite the first argument with the requesting reactive contract.
    function deliver(address recipient_, address reactive_, bytes memory payload_) external returns (bool ok) {
        assembly {
            mstore(add(payload_, 36), reactive_)
        }
        (ok,) = recipient_.call(payload_);
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @dev USDT-style: transferFrom returns nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev A token whose transfers always revert (paused, blacklisted, broken).
contract RevertingToken is MockERC20 {
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("paused");
    }
}
