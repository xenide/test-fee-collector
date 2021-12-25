import { Framework } from "@vechain/connex-framework";
import { Driver, SimpleNet, SimpleWallet } from "@vechain/connex-driver";
import axios from "axios";
import { PRIVATE_KEY, FEE_COLLECTOR_ADDRESS, MAINNET_NODE_URL } from "./config.js";
import { GetERC20Balance } from "./utils.js";

const BREAK_APART_LP_ABI =
{
    "inputs": [
        {
            "internalType": "contract IVexchangeV2Pair",
            "name": "aPair",
            "type": "address"
        }
    ],
    "name": "BreakApartLP",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
};

async function BreakApartLP()
{
    const lPairs = new Map(Object.entries((await axios.get("https://api.vexchange.io/v1/pairs")).data));

    const lWallet = new SimpleWallet();
    lWallet.import(PRIVATE_KEY);
    const lNet = new SimpleNet(MAINNET_NODE_URL);
    const lDriver = await Driver.connect(lNet, lWallet);
    const lProvider = new Framework(lDriver);

    const lFeeCollectorContract = lProvider.thor.account(FEE_COLLECTOR_ADDRESS);
    const lMethod = lFeeCollectorContract.method(BREAK_APART_LP_ABI);

    for (const lPair of lPairs.keys())
    {
        const lBalance = await GetERC20Balance(lPair, FEE_COLLECTOR_ADDRESS, lProvider);
        if (lBalance.eq(0))
        {
            console.log("Balance for", lPair, "is zero. Skipping breaking apart for this LP");
            continue;
        }

        try
        {
            console.log("Attempting BreakApart for", lPair);
            const lClause = lMethod.asClause(lPair);
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
                console.log("BreakApart for", lPair, "was succcessful");
            }
        }
        catch(e)
        {
            console.error("Error", e);
        }
    }

    lDriver.close();
}

BreakApartLP();
