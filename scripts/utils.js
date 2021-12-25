import { BigNumber } from "ethers";

const BALANCE_OF_ABI =
{
    "inputs": [
        {
            "internalType": "address",
            "name": "account",
            "type": "address"
        }
    ],
    "name": "balanceOf",
    "outputs": [
        {
            "internalType": "uint256",
            "name": "",
            "type": "uint256"
        }
    ],
    "stateMutability": "view",
    "type": "function"
}

/***
 *
 * @param aToken contract address of the ERC20 token
 * @param aHolder address of the holder
 * @param aProvider the vechain connex provider
 * @returns {Promise<BigNumber>} BigNumber of the balance for aHolder
 * @constructor
 */
export async function GetERC20Balance(aToken, aHolder, aProvider)
{
    const lTokenContract = aProvider.thor.account(aToken);
    const lMethod = lTokenContract.method(BALANCE_OF_ABI);
    const lRes = await lMethod.call(aHolder);

    return BigNumber.from(lRes.data);
}
