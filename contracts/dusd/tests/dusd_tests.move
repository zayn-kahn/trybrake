#[test_only]
module dusd::dusd_tests;

use dusd::dusd::{Self, Faucet};
use sui::test_scenario as ts;

#[test]
fun anyone_can_mint() {
    let mut sc = ts::begin(@0xA);
    dusd::init_for_testing(sc.ctx());
    sc.next_tx(@0xB);
    let mut faucet = sc.take_shared<Faucet>();
    let c = dusd::mint(&mut faucet, 20_000_000_000, sc.ctx());
    assert!(c.value() == 20_000_000_000);
    transfer::public_transfer(c, @0xB);
    ts::return_shared(faucet);
    sc.end();
}

#[test, expected_failure(abort_code = dusd::ETooMuch)]
fun minting_is_capped_per_call() {
    let mut sc = ts::begin(@0xA);
    dusd::init_for_testing(sc.ctx());
    sc.next_tx(@0xB);
    let mut faucet = sc.take_shared<Faucet>();
    let c = dusd::mint(&mut faucet, 100_000_000_001, sc.ctx());
    transfer::public_transfer(c, @0xB);
    ts::return_shared(faucet);
    sc.end();
}
