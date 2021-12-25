// SPDX-License-Identifier: UNLICENSED
/* solhint-disable not-rely-on-time */
pragma solidity =0.8.11;

import "@openzeppelin/access/Ownable.sol";
import "@openzeppelin/interfaces/IERC20.sol";
import "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "@vexchange-contracts/vexchange-v2-core/contracts/interfaces/IVexchangeV2Pair.sol";
import "@vexchange-contracts/vexchange-v2-core/contracts/interfaces/IVexchangeV2Factory.sol";

struct TokenConfig
{
    bool    IsDesired;     // flag to disable selling of desirable assets
    IERC20  SwapTo;        // if not set, will swap to mDesiredToken
    uint256 LastSaleTime;  // used to throttle sale speed
}

contract FeeCollector is Ownable
{
    using SafeERC20 for IERC20;

    IVexchangeV2Factory public immutable mVexchangeFactory;
    IERC20              public immutable mDesiredToken;
    address             public immutable mRecipient;

    mapping(IERC20 => TokenConfig)    public  mConfig;
    mapping(IVexchangeV2Pair => bool) public  mDesiredLps;

    constructor(
        IVexchangeV2Factory aVexchangeFactory,
        IERC20 aDesiredToken,
        address aRecipient
    )
    {
        mVexchangeFactory = aVexchangeFactory;
        mDesiredToken = aDesiredToken;
        mRecipient = aRecipient;
    }

    function CalcMaxSaleImpact(IVexchangeV2Pair aPair, address aTokenToSell) private view returns (uint256)
    {
        address lToken0 = aPair.token0();
        uint256 lSwapFee = aPair.swapFee();
        uint256 lPlatformFee = aPair.platformFee();
        if (lPlatformFee == 0)
        {
            // assume the full swap fee as rake if platform fee is zero
            lPlatformFee = 10_000;
        }

        uint256 lTokenHoldings;
        if (lToken0 == aTokenToSell)
        {
            // token to sell is token0 && reserve0
            (lTokenHoldings, ,) = aPair.getReserves();
        }
        else
        {
            // token to sell is token1 && reserve1
            (, lTokenHoldings,) = aPair.getReserves();
        }

        uint256 lPlatformRake = lSwapFee * lPlatformFee;

        return lPlatformRake * lTokenHoldings / 1e8;  // swapFee * platformFee are scaled 1e4
    }

    function Min(uint256 a, uint256 b) private pure returns (uint256)
    {
        return a < b ? a : b;
    }

    function Swap(
        IVexchangeV2Pair aPair,
        IERC20 aFromToken,
        IERC20 aToToken,
        uint256 aAmountIn,
        uint256 aSwapFee
    ) private
    {
        (uint256 lReserve0, uint256 lReserve1, ) = aPair.getReserves();

        if (aToToken > aFromToken)
        {
            uint256 lReserveIn = lReserve0;
            uint256 lReserveOut = lReserve1;

            uint256 lAmountInWithFee = aAmountIn * (10_000 - aSwapFee);
            uint256 lNumerator = lAmountInWithFee * lReserveOut;
            uint256 lDenominator = 10_000 * lReserveIn + lAmountInWithFee;

            uint256 lAmountOut = lNumerator / lDenominator;

            // external
            IERC20(aFromToken).safeTransfer(address(aPair), aAmountIn);
            aPair.swap(0, lAmountOut, address(this), "");
        }
        else
        {
            uint256 lReserveIn = lReserve1;
            uint256 lReserveOut = lReserve0;

            uint256 lAmountInWithFee = aAmountIn * (10_000 - aSwapFee);
            uint256 lNumerator = lAmountInWithFee * lReserveOut;
            uint256 lDenominator = 10_000 * lReserveIn + lAmountInWithFee;

            uint256 lAmountOut = lNumerator / lDenominator;

            // external
            IERC20(aFromToken).safeTransfer(address(aPair), aAmountIn);
            aPair.swap(lAmountOut, 0, address(this), "");
        }
    }

    // ***** Admin Functions *****
    function WithdrawToken(IERC20 aToken, address aRecipient) external onlyOwner
    {
        aToken.transfer(aRecipient, aToken.balanceOf(address(this)));
    }

    function UpdateConfig(IERC20 aToken, TokenConfig calldata aConfig) external onlyOwner
    {
        mConfig[aToken] = aConfig;
    }

    function SetDesiredLp(IVexchangeV2Pair aPair, bool aDesired) external onlyOwner
    {
        mDesiredLps[aPair] = aDesired;
    }

    // ***** Public Functions *****
    function BreakApartLP(IVexchangeV2Pair aPair) external
    {
        // checks
        require(mDesiredLps[aPair] == false, "target LP token is desired");

        uint256 lOurHolding = aPair.balanceOf(address(this));

        // external
        aPair.transfer(address(aPair), lOurHolding);
        aPair.burn(address(this));
    }

    function SellHolding(IERC20 aToken) external
    {
        require(aToken != mDesiredToken, "cannot sell desired token");

        TokenConfig storage lConfig = mConfig[aToken];
        require(lConfig.IsDesired == false, "target token is desired");
        require(lConfig.LastSaleTime + 8 hours < block.timestamp, "sale too soon");

        IERC20 lTargetToken;
        if (address(lConfig.SwapTo) == address(0))
        {
            lTargetToken = mDesiredToken;
        }
        else
        {
            lTargetToken = lConfig.SwapTo;
        }

        // compute the sale
        IVexchangeV2Pair lSwapPair = IVexchangeV2Pair(mVexchangeFactory.getPair(address(aToken), address(lTargetToken)));  // can be optimized
        uint256 lCurrentHolding = IERC20(aToken).balanceOf(address(this));
        uint256 lMaxImpact = CalcMaxSaleImpact(lSwapPair, address(aToken));
        uint256 lAmountToSell = Min(lCurrentHolding, lMaxImpact);

        // update state
        lConfig.LastSaleTime = block.timestamp;

        // external
        Swap(lSwapPair, aToken, lTargetToken, lAmountToSell, lSwapPair.swapFee());
    }

    function SweepDesired(address aToken) external
    {
        require(
            mConfig[IERC20(aToken)].IsDesired == true || mDesiredLps[IVexchangeV2Pair(aToken)] == true,
            "cannot sweep undesired lp / token"
        );

        IERC20(aToken).transfer(mRecipient, IERC20(aToken).balanceOf(address(this)));
    }

    function SweepDesired() external
    {
        mDesiredToken.transfer(mRecipient, mDesiredToken.balanceOf(address(this)));
    }
}

// TODO:
// - Replace Min() with external library method
// - Investigate solmate
// - Gas optimization
