/**
 * Development only: a stand-in for a browser wallet, so the demo can be driven by automated tests and
 * screen recordings without a wallet extension. Loaded only by the dev server, and only when
 * VITE_DEV_WALLET_KEY is set in .env.local (gitignored). Throwaway testnet keys only.
 */
import { SuiGrpcClient } from '@mysten/sui/grpc'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import { toBase64 } from '@mysten/sui/utils'
import { ReadonlyWalletAccount, SUI_TESTNET_CHAIN, getWallets, type Wallet } from '@mysten/wallet-standard'
import net from '../chains/sui/testnet.json'

export function registerTestWallet(secret: string) {
  const key = Ed25519Keypair.fromSecretKey(secret)
  const client = new SuiGrpcClient({ network: 'testnet', baseUrl: net.grpc })
  const account = new ReadonlyWalletAccount({
    address: key.toSuiAddress(),
    publicKey: key.getPublicKey().toSuiBytes(),
    chains: [SUI_TESTNET_CHAIN],
    features: ['sui:signAndExecuteTransaction'],
  })
  const wallet: Wallet = {
    version: '1.0.0',
    name: 'Brake test wallet',
    icon: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxIDEiLz4=',
    chains: [SUI_TESTNET_CHAIN],
    accounts: [account],
    features: {
      'standard:connect': { version: '1.0.0', connect: async () => ({ accounts: [account] }) },
      'standard:events': { version: '1.0.0', on: () => () => {} },
      'sui:signAndExecuteTransaction': {
        version: '2.0.0',
        signAndExecuteTransaction: async ({ transaction }: { transaction: { toJSON: () => Promise<string> } }) => {
          const tx = Transaction.from(await transaction.toJSON())
          const bytes = await tx.build({ client })
          const { signature } = await key.signTransaction(bytes)
          const res = await client.executeTransaction({ transaction: bytes, signatures: [signature], include: { effects: true } })
          const done = res.Transaction ?? res.FailedTransaction
          return { digest: done.digest, bytes: toBase64(bytes), signature, effects: toBase64(done.effects?.bcs ?? new Uint8Array()) }
        },
      },
    },
  }
  getWallets().register(wallet)
}
