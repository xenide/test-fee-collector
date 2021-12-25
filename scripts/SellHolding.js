import { Framework } from "@vechain/connex-framework";
import { Driver, SimpleNet, SimpleWallet } from "@vechain/connex-driver";
import axios from "axios";
import { FEE_COLLECTOR_ADDRESS, WVET_ADDRESS, PRIVATE_KEY, MAINNET_NODE_URL } from "./config.js";
import { GetERC20Balance } from "./utils.js";
import {formatUnits} from "ethers/lib/utils.js";

const SELL_HOLDING_ABI =
{
    "inputs": [
        {
            "internalType": "contract IERC20",
            "name": "aToken",
            "type": "address"
        }
    ],
    "name": "SellHolding",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
};

async function SellHolding()
{
    const lTokens = new Map(Object.entries((await axios.get("https://api.vexchange.io/v1/tokens")).data));

    const lWallet = new SimpleWallet();
    lWallet.import(PRIVATE_KEY);
    console.log("Using wallet address:", lWallet.list[0].address)
    const lNet = new SimpleNet(MAINNET_NODE_URL);
    const lDriver = await Driver.connect(lNet, lWallet);
    const lProvider = new Framework(lDriver);

    const lFeeCollectorContract = lProvider.thor.account(FEE_COLLECTOR_ADDRESS);
    const lMethod = lFeeCollectorContract.method(SELL_HOLDING_ABI);

    for (const lToken of lTokens.keys())
    {


        const lTokenBalance = await GetERC20Balance(lToken, FEE_COLLECTOR_ADDRESS, lProvider);
        const lTokenName = lTokens.get(lToken).name;
        if (lTokenBalance.eq(0))
        {
            console.log("Balance for", lTokenName, "is zero. Skipping selling for this token");
            continue;
        }

        try
        {
            console.log("Attempting SellHolding for", lTokenName);
            console.log("Balance", formatUnits(lTokenBalance.toString()));

            const res = await lMethod.call(lToken);

            if (res.reverted)
            {
                console.log("Skipping this because", res.revertReason);
                continue;
            }

            const lClause = lMethod.asClause(lToken);
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
                console.log("Selling", lTokenName, "was succcessful");
            }
        }
        catch(e)
        {
            console.error("Error", e);
        }
    }

    lDriver.close();
}

SellHolding();
