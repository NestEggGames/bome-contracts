// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Mock .ai Agent ID registry: balanceOf > 0 == holds an ID.
contract MockAgentIdRegistry {
    mapping(address => bool) public hasId;

    function setId(address account, bool value) external {
        hasId[account] = value;
    }

    function setIds(address[] calldata accounts, bool value) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            hasId[accounts[i]] = value;
        }
    }

    function balanceOf(address owner) external view returns (uint256) {
        return hasId[owner] ? 1 : 0;
    }

    function handleOf(address) external pure returns (string memory) {
        return "agent.bnb";
    }
}

/// @notice Mock WBNB (WETH9-style subset).
contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "wbnb withdraw");
    }

    receive() external payable {}
}

/// @notice Faithful-enough Pancake V2 pair: CREATE2-deployed by the mock
/// factory with a no-arg constructor + initialize (like the real pair, so
/// the init code hash is a constant). Implements mint (with the real
/// MINIMUM_LIQUIDITY lock and totalSupply==0 bootstrap formula), burn,
/// skim, sync and swap with the 0.25% fee invariant.
contract MockPancakePair {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public factory;
    address public token0;
    address public token1;

    uint112 internal _reserve0;
    uint112 internal _reserve1;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function initialize(address token0_, address token1_) external {
        require(factory == address(0), "initialized");
        factory = msg.sender;
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, 0);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _updateReserves() internal {
        _reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        _reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = bal0 - _reserve0;
        uint256 amount1 = bal1 - _reserve1;
        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            balanceOf[address(0)] += MINIMUM_LIQUIDITY;
            totalSupply += MINIMUM_LIQUIDITY;
        } else {
            uint256 liq0 = (amount0 * totalSupply) / _reserve0;
            uint256 liq1 = (amount1 * totalSupply) / _reserve1;
            liquidity = liq0 < liq1 ? liq0 : liq1;
        }
        require(liquidity > 0, "insufficient liquidity minted");
        balanceOf[to] += liquidity;
        totalSupply += liquidity;
        _updateReserves();
    }

    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = balanceOf[address(this)];
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        amount0 = (liquidity * bal0) / totalSupply;
        amount1 = (liquidity * bal1) / totalSupply;
        balanceOf[address(this)] -= liquidity;
        totalSupply -= liquidity;
        require(IERC20(token0).transfer(to, amount0), "burn t0");
        require(IERC20(token1).transfer(to, amount1), "burn t1");
        _updateReserves();
    }

    /// Test-only helper so a test can move LP tokens into the pair (burn).
    function transferLP(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "lp balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function skim(address to) external {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        if (bal0 > _reserve0) require(IERC20(token0).transfer(to, bal0 - _reserve0), "skim t0");
        if (bal1 > _reserve1) require(IERC20(token1).transfer(to, bal1 - _reserve1), "skim t1");
    }

    function sync() external {
        _updateReserves();
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        require(amount0Out > 0 || amount1Out > 0, "zero out");
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "insufficient liquidity");
        if (amount0Out > 0) require(IERC20(token0).transfer(to, amount0Out), "swap t0");
        if (amount1Out > 0) require(IERC20(token1).transfer(to, amount1Out), "swap t1");
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = bal0 > _reserve0 - amount0Out ? bal0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = bal1 > _reserve1 - amount1Out ? bal1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "zero in");
        uint256 bal0Adj = bal0 * 10_000 - amount0In * 25;
        uint256 bal1Adj = bal1 * 10_000 - amount1In * 25;
        require(bal0Adj * bal1Adj >= uint256(_reserve0) * uint256(_reserve1) * 10_000 ** 2, "K");
        _updateReserves();
    }

    /// Test helper: the pair sends tokens it holds (simulates a buy fill).
    function sendToken(address token, address to, uint256 amount) external {
        require(IERC20(token).transfer(to, amount), "sendToken");
    }
}

/// @notice Mock Pancake V2 factory: real CREATE2 deployment, salt =
/// keccak256(token0, token1), exactly like the production factory — so
/// BOME's predictedPair check is exercised for real in tests.
contract MockPancakeFactory {
    mapping(address => mapping(address => address)) public getPair;
    bytes32 public immutable pairInitCodeHash;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    constructor() {
        pairInitCodeHash = keccak256(abi.encodePacked(type(MockPancakePair).creationCode));
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "identical");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(getPair[token0][token1] == address(0), "exists");
        bytes memory bytecode = type(MockPancakePair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        require(pair != address(0), "create2 failed");
        MockPancakePair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        emit PairCreated(token0, token1, pair, 1);
    }
}

/// @notice Mock WBNB interface for the router.
interface IMockWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice Mock Pancake V2 router: pulls tokens straight from the sender
/// into the pair (like the real router), swaps via pair.swap, unwraps
/// WBNB to BNB. addLiquidityETH uses the standard optimal-amount quote.
contract MockPancakeRouter {
    address public immutable factory;
    address public immutable wbnb;

    constructor(address factory_, address wbnb_) {
        factory = factory_;
        wbnb = wbnb_;
    }

    receive() external payable {}

    function _getReserves(address tokenA, address tokenB) internal view returns (uint256 rA, uint256 rB) {
        address pair = MockPancakeFactory(factory).getPair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = MockPancakePair(pair).getReserves();
        (rA, rB) = MockPancakePair(pair).token0() == tokenA ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 inWithFee = amountIn * 9975;
        return (inWithFee * reserveOut) / (reserveIn * 10_000 + inWithFee);
    }

    function _quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256) {
        return (amountA * reserveB) / reserveA;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(path.length == 2 && path[1] == wbnb, "path");
        require(block.timestamp <= deadline, "expired");
        address tokenIn = path[0];
        address pair = MockPancakeFactory(factory).getPair(tokenIn, wbnb);
        require(pair != address(0), "no pair");
        require(IERC20(tokenIn).transferFrom(msg.sender, pair, amountIn), "pull");
        // Like the real SupportingFeeOnTransfer router: reserves are read
        // AFTER the pull, and the input is measured against them — this
        // stays consistent even when the token's transfer hook ran nested
        // swaps (auto tax processing) during the pull.
        (uint256 rIn, uint256 rOut) = _getReserves(tokenIn, wbnb);
        uint256 arrived = IERC20(tokenIn).balanceOf(pair) - rIn;
        uint256 amountOut = _getAmountOut(arrived, rIn, rOut);
        require(amountOut >= amountOutMin, "insufficient out");
        (uint256 out0, uint256 out1) =
            MockPancakePair(pair).token0() == wbnb ? (amountOut, uint256(0)) : (uint256(0), amountOut);
        MockPancakePair(pair).swap(out0, out1, address(this));
        IMockWBNB(wbnb).withdraw(amountOut);
        (bool ok,) = to.call{value: amountOut}("");
        require(ok, "bnb out");
        // Real router returns NOTHING here (void) — mirrored deliberately
        // so tests exercise the production ABI, not a self-made one.
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        require(block.timestamp <= deadline, "expired");
        address pair = MockPancakeFactory(factory).getPair(token, wbnb);
        if (pair == address(0)) {
            pair = MockPancakeFactory(factory).createPair(token, wbnb);
        }
        (uint256 rToken, uint256 rWbnb) = _getReserves(token, wbnb);
        if (rToken == 0 && rWbnb == 0) {
            (amountToken, amountETH) = (amountTokenDesired, msg.value);
        } else {
            uint256 amountETHOptimal = _quote(amountTokenDesired, rToken, rWbnb);
            if (amountETHOptimal <= msg.value) {
                require(amountETHOptimal >= amountETHMin, "eth min");
                (amountToken, amountETH) = (amountTokenDesired, amountETHOptimal);
            } else {
                uint256 amountTokenOptimal = _quote(msg.value, rWbnb, rToken);
                require(amountTokenOptimal >= amountTokenMin, "token min");
                (amountToken, amountETH) = (amountTokenOptimal, msg.value);
            }
        }
        require(IERC20(token).transferFrom(msg.sender, pair, amountToken), "pull token");
        IMockWBNB(wbnb).deposit{value: amountETH}();
        require(IERC20(wbnb).transfer(pair, amountETH), "push wbnb");
        liquidity = MockPancakePair(pair).mint(to);
        if (msg.value > amountETH) {
            (bool ok,) = msg.sender.call{value: msg.value - amountETH}("");
            require(ok, "refund eth");
        }
    }
}

/// @notice Test wallet that can mint but rejects plain BNB transfers —
/// exercises the push-refund failure path (batch must skip, not stall).
contract RejectingMinter {
    receive() external payable {
        revert("no bnb");
    }

    function mintBome(address bome, uint256 lots, address inviter) external payable {
        (bool ok,) = bome.call{value: msg.value}(abi.encodeWithSignature("mint(uint256,address)", lots, inviter));
        require(ok, "mint failed");
    }
}
