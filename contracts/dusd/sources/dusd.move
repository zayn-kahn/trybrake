/// dUSD: a test dollar for the Brake demo on testnet. Anyone can mint it; it is worthless by design.
/// It stands in for a stablecoin such as USDC, which is what agent wallets mostly hold.
module dusd::dusd;

use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry;

/// Most dUSD one call can mint: 100,000 (6 decimals).
const MAX_MINT: u64 = 100_000_000_000;

const ETooMuch: u64 = 1;

public struct DUSD has drop {}

/// Holds the mint authority, shared so anyone can mint on testnet.
public struct Faucet has key {
    id: UID,
    cap: TreasuryCap<DUSD>,
}

fun init(otw: DUSD, ctx: &mut TxContext) {
    let (currency, cap) = coin_registry::new_currency_with_otw(
        otw,
        6,
        b"dUSD".to_string(),
        b"Demo dollar".to_string(),
        b"A test dollar for the Brake demo. Worthless.".to_string(),
        b"".to_string(),
        ctx,
    );
    currency.finalize_and_delete_metadata_cap(ctx);
    transfer::share_object(Faucet { id: object::new(ctx), cap });
}

public fun mint(faucet: &mut Faucet, amount: u64, ctx: &mut TxContext): Coin<DUSD> {
    assert!(amount <= MAX_MINT, ETooMuch);
    coin::mint(&mut faucet.cap, amount, ctx)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(DUSD {}, ctx)
}
