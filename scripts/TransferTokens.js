import { Framework } from "@vechain/connex-framework";
import { Driver, SimpleNet, SimpleWallet } from "@vechain/connex-driver";
import axios from "axios";
import { PRIVATE_KEY, MAINNET_NODE_URL, DEPLOYER_ADDRESS, FEE_COLLECTOR_ADDRESS, VEX_ADDRESS } from "./config.js";
import { GetERC20Balance } from "./utils.js";
import { BigNumber as BN } from "ethers";

const TRANSFER_ABI =
{
  "type": "function",
  "name": "transfer",
  "inputs": [
    {
      "internalType": "address",
      "name": "recipient",
      "type": "address"
    },
    {
      "internalType": "uint256",
      "name": "amount",
      "type": "uint256"
    }
  ],
  "outputs": [
    {
      "internalType": "bool",
      "name": "",
      "type": "bool"
    }
  ],
  "constant": null,
  "stateMutability": "nonpayable"
};

async function Transfer()
{
    const lTokens = new Map(Object.entries((await axios.get("https://api.vexchange.io/v1/tokens")).data));

    const lWallet = new SimpleWallet();
    lWallet.import(PRIVATE_KEY);
    const lNet = new SimpleNet(MAINNET_NODE_URL);
    const lDriver = await Driver.connect(lNet, lWallet);
    const lProvider = new Framework(lDriver);

    for (const lToken of lTokens.keys())
    {
        console.log("Attempting Transfer for", lToken);
        if (lToken == VEX_ADDRESS)
        {
            console.log("skipping VEX");
            continue;
        }

        try
        {
            const lTokenContract = lProvider.thor.account(lToken);
            const lBalance = (await GetERC20Balance(lToken, DEPLOYER_ADDRESS, lProvider));

            if (lBalance.eq(0))
            {
                console.log("skipping 0 balance");
                continue;
            }

            console.log("transferring: ", lBalance.toString());

            const lTransferMethod = lTokenContract.method(TRANSFER_ABI);
            const lTransferClause = lTransferMethod.asClause(FEE_COLLECTOR_ADDRESS, lBalance.toString());
            const lTransferRes = await lProvider.vendor
                        .sign("tx", [lTransferClause])
                        .request();

            let lTxReceipt;
            const lTxVisitor = lProvider.thor.transaction(lTransferRes.txid);
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
                console.log("Transfer", lToken, "was succcessful");
            }
        }
        catch(e)
        {
            console.error("Error", e);
        }
    }

    lDriver.close();
}

Transfer();
