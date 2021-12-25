// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.11;

import "ds-test/test.sol";
import "src/FeeCollector.sol";
import "src/test/__fixtures/MintableERC20.sol";
import "@vexchange-contracts/vexchange-v2-core/contracts/interfaces/IVexchangeV2Pair.sol";
import "@vexchange-contracts/vexchange-v2-core/contracts/interfaces/IVexchangeV2Factory.sol";

interface HEVM {
    function ffi(string[] calldata) external returns (bytes memory);
    function warp(uint256 timestamp) external;
}

contract FeeCollectorTest is DSTest
{
    // ***** Test State *****
    // this is the cheat code address. HEVM exposes certain cheat codes to test contracts. one of these is the ffi
    // cheat code that lets you execute arbitrary shell commands (in this case loading the bytecode of Vexchange V2)
    HEVM private hevm = HEVM(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MintableERC20 private mExternalToken = new MintableERC20("External", "EXT");
    MintableERC20 private mDesiredToken = new MintableERC20("Desired", "DES");

    IVexchangeV2Factory private mVexFactory;
    IVexchangeV2Pair private mTestPair;

    FeeCollector private mFeeCollector;

    // ***** Helpers *****
    function deployContract(bytes memory code) private returns (address addr)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly
        {
            addr := create(0, add(code, 0x20), mload(code))
            if iszero(addr)
            {
                revert (0, 0)
            }
        }
    }

    function getVexchangeBytecode() private returns (bytes memory)
    {
        string[] memory cmds = new string[](2);
        cmds[0] = "node";
        cmds[1] = "scripts/getBytecode.js";

        return hevm.ffi(cmds);
    }

    function calculateMaxSale(IVexchangeV2Pair aPair, IERC20 aToken) private view returns (uint256 rMaxInput)
    {
        // pair state
        uint256 lSwapFee = aPair.swapFee();
        uint256 lPlatformFee = aPair.platformFee();
        if (lPlatformFee == 0)
        {
            lPlatformFee = 10_000;
        }

        uint256 lPlatformRake = lSwapFee * lPlatformFee;  // has been scaled by 1e8

        // balances
        uint256 lCollectorBal = aToken.balanceOf(address(mFeeCollector));
        uint256 lPairLiqProxy = aToken.balanceOf(address(aPair));

        uint256 lMaxImpact = lPairLiqProxy * lPlatformRake / 1e8;

        return lMaxImpact < lCollectorBal
            ? lMaxImpact
            : lCollectorBal;
    }

    function CalculateOutput(
        uint256 aReserveIn,
        uint256 aReserveOut,
        uint256 aTokenIn,
        uint256 aFee
    ) private pure returns (uint256 rExpectedOut)
    {
        // the following formula is taken from VexchangeV2Library, using 1% as the fee, see:
        //
        // https://github.com/vexchange/vexchange-contracts/blob/183e8eef29dc9a28e0f84539bc2c66bb3f6103bf/
        // vexchange-v2-periphery/contracts/libraries/VexchangeV2Library.sol#L49
        uint256 lAmountInWithFee = aTokenIn * (10_000 - aFee);
        uint256 lNumerator = lAmountInWithFee * aReserveOut;
        uint256 lDenominator = aReserveIn * 10_000 + lAmountInWithFee;

        rExpectedOut = lNumerator / lDenominator;
    }

    // ***** Setup *****
    function setUp() public
    {
        bytes memory lBytecodeWithArgs = abi.encodePacked(
            getVexchangeBytecode(),
            abi.encode(100),            // swapFee
            abi.encode(2_500),          // platformFee
            abi.encode(address(this)),  // platformFeeTo
            abi.encode(address(this))   // defaultRecoverer
        );

        mVexFactory = IVexchangeV2Factory(deployContract(lBytecodeWithArgs));
        mTestPair = IVexchangeV2Pair(mVexFactory.createPair(
            address(mDesiredToken),
            address(mExternalToken)
        ));

        mFeeCollector = new FeeCollector(mVexFactory, mDesiredToken, address(this));

        // set timezone to 24 hours in the future to get passed 8 hour sale rate limit
        hevm.warp(24 hours);
    }

    // ***** Tests *****
    function test_withdraw() public
    {
        // sanity
        mExternalToken.Mint(address(mFeeCollector), 10e18);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 10e18);

        // act
        mFeeCollector.WithdrawToken(mExternalToken, address(this));

        // assert
        assertEq(mExternalToken.balanceOf(address(this)), 10e18);
    }

    function testFail_disable_sales() public
    {
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(1));

        // sanity
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(mTestPair);
        assertEq(mTestPair.balanceOf(address(mFeeCollector)),      0);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 100e18);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  50e18);
        assertEq(mDesiredToken.balanceOf(address(this)),           0);

        // act
        mFeeCollector.UpdateConfig(
            mExternalToken,
            TokenConfig({ IsDesired: true, SwapTo: IERC20(address(0)), LastSaleTime: 0 })
        );
        mFeeCollector.SellHolding(mExternalToken);
    }

    function testFail_disable_pair() public
    {
        // arrange
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(mFeeCollector));

        // act
        mFeeCollector.SetDesiredLp(mTestPair, true);
        mFeeCollector.BreakApartLP(mTestPair);
    }

    function test_withdraw_lp() public
    {
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);

        // sanity
        uint256 lLiquidityMinted = mTestPair.mint(address(mFeeCollector));
        assertEq(mTestPair.balanceOf(address(mFeeCollector)), lLiquidityMinted);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 0);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  0);

        // act
        mFeeCollector.BreakApartLP(mTestPair);

        // assert
        assertEq(mTestPair.balanceOf(address(mFeeCollector)),      0);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 99999999999999998585);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  49999999999999999292);
    }

    function test_sell_holding() public
    {
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(1));

        // sanity
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(mTestPair);
        assertEq(mTestPair.balanceOf(address(mFeeCollector)),      0);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 100e18);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  50e18);
        assertEq(mDesiredToken.balanceOf(address(this)),           0);

        // act
        uint256 lMaxSale = calculateMaxSale(mTestPair, mExternalToken);
        mFeeCollector.SellHolding(mExternalToken);
        mFeeCollector.SweepDesired();

        // assert
        uint256 lOurBal = mDesiredToken.balanceOf(address(this));
        uint256 lCollectorBal = mDesiredToken.balanceOf(address(mFeeCollector));
        uint256 lTestPairBal = mDesiredToken.balanceOf(address(mTestPair));

        assertEq(lCollectorBal, 0); // we sweeped all
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 100e18 - lMaxSale); // we sold lMaxSale
        assertEq(lOurBal, 100e18 - lTestPairBal); // we received the result of the swap & sweep
    }

    function testFail_sell_holding() public
    {
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(1));

        // sanity
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(mTestPair);

        // act
        mFeeCollector.SellHolding(mDesiredToken);
    }

    function test_sweep_holding() public
    {
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);

        // sanity
        mTestPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(mTestPair);
        assertEq(mTestPair.balanceOf(address(mFeeCollector)),      0);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 99999999999999998585);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  49999999999999999292);

        // act
        mFeeCollector.SweepDesired();

        // assert
        uint256 lOurBal = mDesiredToken.balanceOf(address(this));
        uint256 lCollectorBal = mDesiredToken.balanceOf(address(mFeeCollector));
        uint256 lTestPairBal = mDesiredToken.balanceOf(address(mTestPair));

        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 99999999999999998585);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  0);
        assertEq(lOurBal + lCollectorBal + lTestPairBal, 50e18);
    }

    function test_sell_and_sweep_holding() public
    {
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(1));

        // sanity
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(mTestPair);
        assertEq(mTestPair.balanceOf(address(mFeeCollector)),      0);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 100e18);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  50e18);

        // act
        uint256 lMaxSale = calculateMaxSale(mTestPair, mExternalToken);
        mFeeCollector.SellHolding(mExternalToken);
        mFeeCollector.SweepDesired();

        // assert
        uint256 lOurBal = mDesiredToken.balanceOf(address(this));
        uint256 lTestPairBal = mDesiredToken.balanceOf(address(mTestPair));

        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 100e18 - lMaxSale);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  0);
        assertEq(lOurBal, 100e18 - lTestPairBal);  // we have all desired outside of test pair
    }

    function test_swap_to_other() public
    {
        // arrange
        MintableERC20 lOtherToken = new MintableERC20("Other Token", "OTHER");
        IVexchangeV2Pair lOtherPair = IVexchangeV2Pair(mVexFactory.createPair(
            address(mExternalToken),
            address(lOtherToken)
        ));

        lOtherToken.Mint(address(lOtherPair), 2e18);  // this is a more expensive token
        mExternalToken.Mint(address(lOtherPair), 50e18);
        lOtherPair.mint(address(1));

        // sanity
        lOtherToken.Mint(address(lOtherPair), 2e18);
        mExternalToken.Mint(address(lOtherPair), 50e18);
        lOtherPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(lOtherPair);
        assertEq(lOtherPair.balanceOf(address(mFeeCollector)),     0);
        assertEq(lOtherToken.balanceOf(address(mFeeCollector)),    2e18);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 50e18);

        // act
        uint256 lMaxSale = calculateMaxSale(lOtherPair, lOtherToken);
        mFeeCollector.UpdateConfig(
            lOtherToken,
            TokenConfig({ IsDesired: false, SwapTo: mExternalToken, LastSaleTime: 0 })
        );
        mFeeCollector.SellHolding(lOtherToken);
        mFeeCollector.SweepDesired();

        // assert
        uint256 lOtherPairBal = mExternalToken.balanceOf(address(lOtherPair));
        uint256 lCollectorBal = mExternalToken.balanceOf(address(mFeeCollector));
        uint256 lRecipientBal = mExternalToken.balanceOf(address(this));

        assertEq(lRecipientBal, 0);
        assertEq(lOtherToken.balanceOf(address(mFeeCollector)), 2e18 - lMaxSale);  // we sold as much as we could
        assertEq(lCollectorBal, 100e18 - lOtherPairBal);  // we have all external outside of other pair
    }

    function testFail_swap_too_quickly() public
    {
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(1));

        // sanity
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(mTestPair);
        assertEq(mTestPair.balanceOf(address(mFeeCollector)),      0);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 100e18);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  50e18);
        assertEq(mDesiredToken.balanceOf(address(this)),           0);

        // act
        mFeeCollector.SellHolding(mExternalToken);
        mFeeCollector.SellHolding(mExternalToken);
    }

    function test_sell_two_different() public
    {
        MintableERC20 lOtherToken = new MintableERC20("Other Token", "OTHER");
        IVexchangeV2Pair lOtherPair = IVexchangeV2Pair(mVexFactory.createPair(
            address(mExternalToken),
            address(lOtherToken)
        ));

        // pair 1 with 2 other & 50 external
        lOtherToken.Mint(address(lOtherPair), 2e18);
        mExternalToken.Mint(address(lOtherPair), 50e18);
        lOtherPair.mint(address(1));

        // pair 2 with 50 desired & 100 external
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(1));

        // sanity
        // pair 1
        lOtherToken.Mint(address(lOtherPair), 2e18);
        mExternalToken.Mint(address(lOtherPair), 50e18);
        lOtherPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(lOtherPair);
        assertEq(lOtherPair.balanceOf(address(mFeeCollector)),     0);
        assertEq(lOtherToken.balanceOf(address(mFeeCollector)),    2e18);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 50e18);

        // pair 2
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(mTestPair);
        assertEq(mTestPair.balanceOf(address(mFeeCollector)),      0);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 150e18);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  50e18);
        assertEq(mDesiredToken.balanceOf(address(this)),           0);

        // act
        // for this scenario we will do two things:
        //
        // 1. sell mExternal for mDesired
        // 2. sell lOther for mExternal
        mFeeCollector.UpdateConfig(
            lOtherToken,
            TokenConfig({ IsDesired: false, SwapTo: mExternalToken, LastSaleTime: 0 })
        );
        uint256 lMaxSaleExternal = calculateMaxSale(mTestPair, mExternalToken);
        uint256 lMaxSaleOther = calculateMaxSale(lOtherPair, lOtherToken);
        mFeeCollector.SellHolding(mExternalToken);
        mFeeCollector.SellHolding(lOtherToken);
        mFeeCollector.SweepDesired();

        // assert
        uint256 lOurBal = mDesiredToken.balanceOf(address(this));
        uint256 lTestPairBalDesired = mDesiredToken.balanceOf(address(mTestPair));
        uint256 lCollectorBalDesired = mDesiredToken.balanceOf(address(mFeeCollector));

        assertEq(lOtherToken.balanceOf(address(mFeeCollector)), 2e18 - lMaxSaleOther);  // we sold as much as we could
        assertEq(lCollectorBalDesired, 0);  // we swept collector
        assertEq(lOurBal, 100e18 - lTestPairBalDesired);  // we received the result of the swap & sweep

        // we sold lMaxSale and received expected
        uint256 lOtherSaleReceived = CalculateOutput(
            2e18,
            50e18,
            lMaxSaleOther,
            100
        );
        uint256 lExpected = 150e18 - lMaxSaleExternal + lOtherSaleReceived;
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), lExpected);
    }

    function test_sell_holding_no_platform_fee() public
    {
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(1));

        // sanity
        mExternalToken.Mint(address(mTestPair), 100e18);
        mDesiredToken.Mint(address(mTestPair), 50e18);
        mTestPair.mint(address(mFeeCollector));
        mFeeCollector.BreakApartLP(mTestPair);
        assertEq(mTestPair.balanceOf(address(mFeeCollector)),      0);
        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 100e18);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)),  50e18);
        assertEq(mDesiredToken.balanceOf(address(this)),           0);

        // act
        mVexFactory.setPlatformFeeForPair(address(mTestPair), 0);

        uint256 lMaxSale = calculateMaxSale(mTestPair, mExternalToken);
        mFeeCollector.SellHolding(mExternalToken);
        mFeeCollector.SweepDesired();

        // assert
        uint256 lOurBal = mDesiredToken.balanceOf(address(this));
        uint256 lTestPairBal = mDesiredToken.balanceOf(address(mTestPair));

        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 100e18 - lMaxSale);  // we sold lMaxSale
        assertEq(lOurBal, 100e18 - lTestPairBal);  // we received the result of the swap & sweep
    }

    function test_sell_profitable() public
    {
        // create new pool with 10x and 10y
        mExternalToken.Mint(address(mTestPair), 10e18);
        mDesiredToken.Mint(address(mTestPair), 10e18);
        mTestPair.mint(address(1));

        // give FeeCollector 25bips * 10 of y
        uint256 lAmountToSell = 0.025e18;
        mExternalToken.Mint(address(mFeeCollector), lAmountToSell);

        // act
        mFeeCollector.SellHolding(mExternalToken);

        // assert
        uint256 lExpectedOut = CalculateOutput(
            10e18,
            10e18,
            0.025e18,
            100
        );

        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 0);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)), lExpectedOut);
    }

    function test_sell_profitable_other() public
    {
        // create other token
        MintableERC20 lOtherToken = new MintableERC20("Other Token", "OTHER");
        IVexchangeV2Pair lOtherPair = IVexchangeV2Pair(mVexFactory.createPair(
            address(mExternalToken),
            address(lOtherToken)
        ));

        // create new pool with 10x and 10y
        mExternalToken.Mint(address(lOtherPair), 10e18);
        lOtherToken.Mint(address(lOtherPair), 2.5e18);
        lOtherPair.mint(address(1));

        // give FeeCollector 25bips * 10 of y
        uint256 lAmountToSell = 0.025e18;
        mExternalToken.Mint(address(mFeeCollector), lAmountToSell);

        // act
        mFeeCollector.UpdateConfig(
            mExternalToken,
            TokenConfig({ IsDesired: false, SwapTo: lOtherToken, LastSaleTime: 0 })
        );
        mFeeCollector.SellHolding(mExternalToken);

        // assert
        uint256 lExpectedOut = CalculateOutput(
            10e18,
            2.5e18,
            0.025e18,
            100
        );

        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 0);
        assertEq(lOtherToken.balanceOf(address(mFeeCollector)), lExpectedOut);
    }

    function test_sell_profitable_no_helper() public
    {
        // create new pool with 10x and 10y
        mExternalToken.Mint(address(mTestPair), 10e18);
        mDesiredToken.Mint(address(mTestPair), 10e18);
        mTestPair.mint(address(1));

        // give FeeCollector 25bips * 10 of y
        uint256 lAmountToSell = 0.025e18;
        mExternalToken.Mint(address(mFeeCollector), lAmountToSell);

        // initiate sale, expecting all to be sold for roughly equivalent amount of y
        mFeeCollector.SellHolding(mExternalToken);

        // assert
        // the following formula is taken from VexchangeV2Library, using 1% as the fee, see:
        //
        // https://github.com/vexchange/vexchange-contracts/blob/183e8eef29dc9a28e0f84539bc2c66bb3f6103bf/
        // vexchange-v2-periphery/contracts/libraries/VexchangeV2Library.sol#L49
        // NB: we re-implement the helper function here for redundancy
        uint256 lAmountInWithFee = lAmountToSell * (100 - 1);
        uint256 lNumerator = lAmountInWithFee * 10e18;
        uint256 lDenominator = 10e18 * 100 + lAmountInWithFee;

        uint256 lExpectedOut = lNumerator / lDenominator;

        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 0);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)), lExpectedOut);
    }

    function test_withdraw_other_desired() public
    {
        // arrange
        MintableERC20 lOtherToken = new MintableERC20("Other Token", "OTHER");
        IVexchangeV2Pair lOtherPair = IVexchangeV2Pair(mVexFactory.createPair(
            address(mExternalToken),
            address(lOtherToken)
        ));

        // mint initial liquidity and send to locked addr
        lOtherToken.Mint(address(lOtherPair), 2e18);
        mExternalToken.Mint(address(lOtherPair), 50e18);
        lOtherPair.mint(address(1));

        // give the mFeeCollector some LP tokens
        lOtherToken.Mint(address(lOtherPair), 2e18);
        mExternalToken.Mint(address(lOtherPair), 50e18);
        lOtherPair.mint(address(mFeeCollector));
        
        // sanity
        uint256 lFeeCollectorBal = lOtherPair.balanceOf(address(mFeeCollector));
        assertEq(lOtherPair.balanceOf(address(this)), 0);

        // act
        mFeeCollector.SetDesiredLp(lOtherPair, true);
        mFeeCollector.SweepDesired(address(lOtherPair));

        // assert - all bal has moved to us from fee collector
        assertEq(lOtherPair.balanceOf(address(mFeeCollector)), 0);
        assertEq(lOtherPair.balanceOf(address(this)), lFeeCollectorBal);
    }

    function testFail_withdraw_other_undesired() public
    {
        // arrange
        MintableERC20 lOtherToken = new MintableERC20("Other Token", "OTHER");
        IVexchangeV2Pair lOtherPair = IVexchangeV2Pair(mVexFactory.createPair(
            address(mExternalToken),
            address(lOtherToken)
        ));

        // mint initial liquidity and send to locked addr
        lOtherToken.Mint(address(lOtherPair), 2e18);
        mExternalToken.Mint(address(lOtherPair), 50e18);
        lOtherPair.mint(address(1));

        // give the mFeeCollector some LP tokens
        lOtherToken.Mint(address(lOtherPair), 2e18);
        mExternalToken.Mint(address(lOtherPair), 50e18);
        lOtherPair.mint(address(mFeeCollector));

        // act
        mFeeCollector.SweepDesired(address(lOtherPair));
    }

    // fuzz testing
    function test_sell_amount_is_optimal(uint256 aSellAmount) public
    {
        // create new pool with 10x and 10y
        mExternalToken.Mint(address(mTestPair), 10e18);
        mDesiredToken.Mint(address(mTestPair), 10e18);
        mTestPair.mint(address(1));

        // give FeeCollector 25bips * 10 of y
        uint256 lMaxSaleAmount = 0.025e18;
        if (aSellAmount > lMaxSaleAmount) { return; }

        uint256 lExpectedOut = CalculateOutput(
            10e18,
            10e18,
            aSellAmount,
            100
        );
        if (lExpectedOut == 0) { return; }

        mExternalToken.Mint(address(mFeeCollector), aSellAmount);

        // act
        mFeeCollector.SellHolding(mExternalToken);

        // assert

        assertEq(mExternalToken.balanceOf(address(mFeeCollector)), 0);
        assertEq(mDesiredToken.balanceOf(address(mFeeCollector)), lExpectedOut);
    }

    // testing the test helpers
    function test_output_calc() public
    {
        uint256 lReserve0 = 10e18;
        uint256 lReserve1 = 10e18;
        uint256 lAmountIn = 10e18;

        uint256 lAmountOut = CalculateOutput(lReserve0, lReserve1, lAmountIn, 0);

        assertEq(lAmountOut, 5e18);
    }
}
