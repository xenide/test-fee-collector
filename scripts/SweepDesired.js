import { Framework } from "@vechain/connex-framework";
import { Driver, SimpleNet, SimpleWallet } from "@vechain/connex-driver";
import { PRIVATE_KEY, FEE_COLLECTOR_ADDRESS, MAINNET_NODE_URL } from "./config.js";
import { isAddress } from "ethers/lib/utils.js";
import { GetERC20Balance } from "./utils.js";

const MDESIRED_TOKEN_ABI =
{
    "inputs": [],
    "name": "mDesiredToken",
    "outputs": [
        {
            "internalType": "contract IERC20",
            "name": "",
            "type": "address"
        }
    ],
    "stateMutability": "view",
    "type": "function"
}

const SWEEP_DESIRED_ABI =
{
    "inputs": [],
    "name": "SweepDesired",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
}

const SWEEP_DESIRED_MANUAL_ABI =
{
    "inputs": [
        {
            "internalType": "address",
            "name": "aToken",
            "type": "address"
        }
    ],
    "name": "SweepDesired",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
}

async function SweepDesired(aTokenAddress=undefined)
{
    const lWallet = new SimpleWallet();
    lWallet.import(PRIVATE_KEY);
    const lNet = new SimpleNet(MAINNET_NODE_URL);
    const lDriver = await Driver.connect(lNet, lWallet);
    const lProvider = new Framework(lDriver);

    const lFeeCollectorContract = lProvider.thor.account(FEE_COLLECTOR_ADDRESS);

    const lMethod = aTokenAddress ? lFeeCollectorContract.method(SWEEP_DESIRED_MANUAL_ABI)
                                  : lFeeCollectorContract.method(SWEEP_DESIRED_ABI);

    const lDefaultDesiredToken = (await lFeeCollectorContract.method(MDESIRED_TOKEN_ABI).call()).decoded['0'];
    const lTokenBalance = await GetERC20Balance(aTokenAddress ? aTokenAddress : lDefaultDesiredToken,
                                FEE_COLLECTOR_ADDRESS,
                                lProvider);

    if (lTokenBalance.eq(0))
    {
        console.log("Balance for", aTokenAddress ? aTokenAddress : lDefaultDesiredToken, "is zero. Not sweeping this token");
        return;
    }

    try
    {
        console.log("Attempting SweepDesired");
        const lClause = aTokenAddress ? lMethod.asClause(aTokenAddress)
                                     : lMethod.asClause();

        const lRes = await lProvider.vendor
            .sign("tx", [lClause])
            .request()

        let lTxReceipt;
        const lTxVisitor = lProvider.thor.transaction(lRes.txid);
        const lTicker = lProvider.thor.ticker();

        while(!lTxReceipt) {
            await lTicker.next();
            lTxReceipt = await lTxVisitor.getReceipt();
        }

        if (lTxReceipt.reverted)
        {
            console.log("tx was unsuccessful");
        }
        else
        {
            console.log("SweepDesired was succcessful");
        }
    }
    catch(e)
    {
        console.error("Error", e);
    }

    lDriver.close();
}

const TOKEN_ADDRESS = process.argv[2];
if (TOKEN_ADDRESS && !isAddress(TOKEN_ADDRESS))
{
    throw Error("Invalid Token Address Provided");
}

SweepDesired(TOKEN_ADDRESS);
