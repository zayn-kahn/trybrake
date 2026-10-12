# Brake on Sui: technical demo

Live: https://trybrake.vercel.app

The nine-step Brake story running on **Sui testnet**, with your own browser wallet. Everything on the
Brake side is a real transaction you can open on Suiscan; the plain "Without Brake" wallet is simulated
for comparison and labelled so.

## Run it

```sh
npm install
npm run dev
```

Open the URL Vite prints in a browser with a Sui wallet (Slush) **switched to testnet**, holding about
0.2 testnet SUI for gas.

1. **Connect your Sui wallet.** It plays you: the vault's owner, and "your phone".
2. **Set up the demo** (one approval). It mints 20,000 dUSD (a test dollar) into a new Brake vault,
   gives the agent and the watcher their keys, gives your wallet the owner and phone keys, trusts
   Alex, and sends the agent and watcher a little SUI for gas if they're low.
3. Follow the story. Adding Sam and cancelling the payment are approvals in your wallet; the rest is
   done by the demo's agent and watcher.

Replay asks for a new setup (one approval).

## Who holds which key

| Role | Key | Where it lives |
|---|---|---|
| You (owner) | `OwnerCap` | Your wallet |
| Your phone | `BrakeCap`, may cancel | Your wallet |
| Agent | `DriverCap` | A key generated in this browser at runtime |
| Watcher | `BrakeCap`, hold only | A key generated in this browser at runtime |

The agent and watcher keys stay in this browser's storage. Fine for testnet; never for real funds.

## How it talks to Sui

- gRPC (`SuiGrpcClient`): Sui's public testnet node blocks JSON-RPC from browsers, and JSON-RPC is
  deprecated in the SDK.
- Wallet: `@mysten/wallet-standard`, `sui:signAndExecuteTransaction` on `sui:testnet`.
- Contract IDs: `src/chains/sui/testnet.json`. Source: [../../contracts/brake](../../contracts/brake) and [../../contracts/dusd](../../contracts/dusd).

## Testing without a wallet extension (development only)

Put a throwaway testnet key in `.env.local` (gitignored) as `VITE_DEV_WALLET_KEY=suiprivkey…` and
`npm run dev` registers a stand-in wallet that signs with it, only in a browser where `localStorage["brake-dev-wallet"]` is `"on"` (so your own browser always uses your real wallet). Never put keys in URLs or commits.
