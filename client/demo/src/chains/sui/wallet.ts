import type { Transaction } from '@mysten/sui/transactions'
import {
  SUI_TESTNET_CHAIN,
  getWallets,
  isWalletWithRequiredFeatureSet,
  signAndExecuteTransaction,
  type WalletAccount,
  type WalletWithRequiredFeatures,
} from '@mysten/wallet-standard'

/** The viewer's own browser wallet (Slush or any Sui wallet), used as the vault's owner and as "your phone". */
let wallet: WalletWithRequiredFeatures | null = null
let account: WalletAccount | null = null
const REMEMBER = 'brake-sui-wallet'

function testnetWallets() {
  return getWallets()
    .get()
    .filter(
      (w): w is WalletWithRequiredFeatures =>
        isWalletWithRequiredFeatureSet(w, ['sui:signAndExecuteTransaction']) && w.chains.includes(SUI_TESTNET_CHAIN),
    )
}

async function connectTo(w: WalletWithRequiredFeatures, silent: boolean) {
  const res = await w.features['standard:connect'].connect({ silent })
  const acc = res.accounts.find((a) => a.chains.includes(SUI_TESTNET_CHAIN)) ?? res.accounts[0]
  if (!acc) throw new Error(`${w.name} didn’t share an account`)
  wallet = w
  account = acc
  try {
    localStorage.setItem(REMEMBER, w.name)
  } catch {
    /* reconnecting on reload is a convenience */
  }
  return acc.address
}

export async function connectWallet(): Promise<string> {
  const list = testnetWallets()
  if (list.length === 0) {
    throw new Error('No Sui wallet found. Install Slush (or another Sui wallet), switch it to testnet, then reload.')
  }
  return connectTo(list.find((w) => /slush/i.test(w.name)) ?? list[0], false)
}

/** Reconnects without a prompt if this browser connected before. */
export async function restoreWallet(): Promise<string | null> {
  let name: string | null = null
  try {
    name = localStorage.getItem(REMEMBER)
  } catch {
    return null
  }
  // Wallet extensions announce themselves shortly after the page loads.
  await new Promise((r) => setTimeout(r, 300))
  const w = testnetWallets().find((x) => x.name === name)
  if (!w) return null
  try {
    return await connectTo(w, true)
  } catch {
    return null
  }
}

export const walletAddress = () => account?.address ?? null

/** Asks the viewer's wallet to approve and send `tx` on testnet. Returns the digest. */
export async function walletExecute(tx: Transaction): Promise<string> {
  if (!wallet || !account) throw new Error('Connect your Sui wallet first')
  tx.setSenderIfNotSet(account.address)
  const out = await signAndExecuteTransaction(wallet, { transaction: tx, account, chain: SUI_TESTNET_CHAIN })
  return out.digest
}
