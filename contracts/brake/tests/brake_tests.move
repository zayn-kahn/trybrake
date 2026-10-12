#[test_only]
module brake::brake_tests;

use brake::brake::{Self, Vault, OwnerCap, DriverCap, BrakeCap, KeyIssued, KeyRevoked, Deposited, Withdrawn};
use std::string;
use sui::event;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

const OWNER: address = @0xA;
const AGENT: address = @0xB;
const PHONE: address = @0xC; // brake that may cancel
const WATCHER: address = @0xD; // brake that may only hold
const ALEX: address = @0xE; // trusted contact
const ATTACKER: address = @0xBAD;
const RELAYER: address = @0x123;
const AGENT2: address = @0xB2; // a second driver

const QUEUE: u64 = 60_000;
const HOLD: u64 = 120_000;
const EXPIRY: u64 = 300_000;
const LIMIT: u64 = 500;
const START: u64 = 10_000;
const DAY: u64 = 86_400_000;

// ---------------------------------------------------------------- helpers

fun setup(): (Scenario, Clock) {
    let mut sc = ts::begin(OWNER);
    let clock = clock::create_for_testing(sc.ctx());
    let owner = brake::create<SUI>(QUEUE, HOLD, EXPIRY, LIMIT, coin::mint_for_testing(START, sc.ctx()), sc.ctx());
    transfer::public_transfer(owner, OWNER);
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        transfer::public_transfer(brake::issue_driver(&owner, &mut vault, sc.ctx()), AGENT);
        transfer::public_transfer(brake::issue_brake(&owner, &mut vault, true, sc.ctx()), PHONE);
        transfer::public_transfer(brake::issue_brake(&owner, &mut vault, false, sc.ctx()), WATCHER);
        brake::set_trusted(&owner, &mut vault, ALEX, true);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    (sc, clock)
}

fun finish(sc: Scenario, clock: Clock) {
    clock.destroy_for_testing();
    sc.end();
}

fun propose(sc: &mut Scenario, clock: &Clock, to: address, amount: u64): u64 {
    sc.next_tx(AGENT);
    let driver = sc.take_from_sender<DriverCap>();
    let mut vault = sc.take_shared<Vault<SUI>>();
    let id = brake::propose(&driver, &mut vault, to, amount, string::utf8(b"test"), clock, sc.ctx());
    ts::return_shared(vault);
    sc.return_to_sender(driver);
    id
}

fun hold_as(sc: &mut Scenario, clock: &Clock, who: address, payment: u64) {
    sc.next_tx(who);
    let cap = sc.take_from_sender<BrakeCap>();
    let mut vault = sc.take_shared<Vault<SUI>>();
    brake::hold(&cap, &mut vault, payment, clock);
    ts::return_shared(vault);
    sc.return_to_sender(cap);
}

fun cancel_as_brake(sc: &mut Scenario, who: address, payment: u64) {
    sc.next_tx(who);
    let cap = sc.take_from_sender<BrakeCap>();
    let mut vault = sc.take_shared<Vault<SUI>>();
    brake::cancel_as_brake(&cap, &mut vault, payment);
    ts::return_shared(vault);
    sc.return_to_sender(cap);
}

fun execute(sc: &mut Scenario, clock: &Clock, payment: u64) {
    sc.next_tx(RELAYER);
    let mut vault = sc.take_shared<Vault<SUI>>();
    brake::execute(&mut vault, payment, clock, sc.ctx());
    ts::return_shared(vault);
}

/// Total value of coins `who` has received.
fun received(sc: &mut Scenario, who: address): u64 {
    sc.next_tx(who);
    let ids = ts::ids_for_address<Coin<SUI>>(who);
    let mut total = 0;
    ids.do!(|id| {
        let c = sc.take_from_address_by_id<Coin<SUI>>(who, id);
        total = total + c.value();
        ts::return_to_address(who, c);
    });
    total
}

fun vault_balance(sc: &mut Scenario): u64 {
    sc.next_tx(OWNER);
    let vault = sc.take_shared<Vault<SUI>>();
    let b = brake::balance(&vault);
    ts::return_shared(vault);
    b
}

fun state(sc: &mut Scenario, clock: &Clock, payment: u64): u8 {
    sc.next_tx(OWNER);
    let vault = sc.take_shared<Vault<SUI>>();
    let s = brake::payment_state(&vault, payment, clock);
    ts::return_shared(vault);
    s
}

fun revoke(sc: &mut Scenario, key: ID) {
    sc.next_tx(OWNER);
    let owner = sc.take_from_sender<OwnerCap>();
    let mut vault = sc.take_shared<Vault<SUI>>();
    brake::revoke(&owner, &mut vault, key);
    ts::return_shared(vault);
    sc.return_to_sender(owner);
}

fun key_of<Cap: key>(sc: &mut Scenario, who: address): ID {
    sc.next_tx(who);
    let cap = sc.take_from_sender<Cap>();
    let id = object::id(&cap);
    sc.return_to_sender(cap);
    id
}

fun set_trusted(sc: &mut Scenario, contact: address, trusted: bool) {
    sc.next_tx(OWNER);
    let owner = sc.take_from_sender<OwnerCap>();
    let mut vault = sc.take_shared<Vault<SUI>>();
    brake::set_trusted(&owner, &mut vault, contact, trusted);
    ts::return_shared(vault);
    sc.return_to_sender(owner);
}

// ---------------------------------------------------------------- the two lanes

#[test]
fun small_payment_to_trusted_contact_goes_out_at_once() {
    let (mut sc, clock) = setup();
    propose(&mut sc, &clock, ALEX, 100);
    assert!(received(&mut sc, ALEX) == 100);
    assert!(vault_balance(&mut sc) == START - 100);
    finish(sc, clock);
}

#[test]
fun payment_to_stranger_waits() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    assert!(received(&mut sc, ATTACKER) == 0);
    assert!(vault_balance(&mut sc) == START);
    assert!(state(&mut sc, &clock, id) == 0); // waiting
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::ENotReady)]
fun nobody_can_send_before_the_wait_is_over() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    execute(&mut sc, &clock, id);
    finish(sc, clock);
}

#[test]
fun anyone_can_send_once_the_wait_is_over() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    clock.increment_for_testing(QUEUE);
    execute(&mut sc, &clock, id);
    assert!(received(&mut sc, ATTACKER) == 5_000);
    assert!(state(&mut sc, &clock, id) == 2); // sent
    finish(sc, clock);
}

#[test]
fun daily_limit_is_a_budget_that_resets_each_day() {
    let (mut sc, mut clock) = setup();
    propose(&mut sc, &clock, ALEX, 300);
    propose(&mut sc, &clock, ALEX, 300); // 600 > 500 today: waits
    assert!(received(&mut sc, ALEX) == 300);
    clock.increment_for_testing(DAY);
    propose(&mut sc, &clock, ALEX, 300);
    assert!(received(&mut sc, ALEX) == 600);
    finish(sc, clock);
}

#[test]
fun untrusting_a_contact_makes_them_wait_again() {
    let (mut sc, clock) = setup();
    set_trusted(&mut sc, ALEX, false);
    propose(&mut sc, &clock, ALEX, 100);
    assert!(received(&mut sc, ALEX) == 0);
    finish(sc, clock);
}

#[test]
fun preview_tells_the_agent_its_limits_without_spending_budget() {
    let (mut sc, clock) = setup();
    sc.next_tx(AGENT);
    {
        let vault = sc.take_shared<Vault<SUI>>();
        let (instant, wait) = brake::preview(&vault, ALEX, 300, &clock);
        assert!(instant && wait == 0);
        let (instant, wait) = brake::preview(&vault, ATTACKER, 300, &clock);
        assert!(!instant && wait == QUEUE);
        ts::return_shared(vault);
    };
    propose(&mut sc, &clock, ALEX, 250);
    propose(&mut sc, &clock, ALEX, 250);
    assert!(received(&mut sc, ALEX) == 500); // both fit: preview spent nothing
    finish(sc, clock);
}

// ---------------------------------------------------------------- brakes

#[test]
fun a_hold_pushes_the_payment_back_by_the_max_hold() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    hold_as(&mut sc, &clock, WATCHER, id);
    sc.next_tx(OWNER);
    let vault = sc.take_shared<Vault<SUI>>();
    assert!(brake::payment_ready_ms(&vault, id) == QUEUE + HOLD);
    ts::return_shared(vault);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::ENotReady)]
fun a_held_payment_cannot_be_sent_when_the_first_wait_ends() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    hold_as(&mut sc, &clock, WATCHER, id);
    clock.increment_for_testing(QUEUE);
    execute(&mut sc, &clock, id);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::EAlreadyHeld)]
fun each_brake_holds_a_payment_only_once() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    hold_as(&mut sc, &clock, WATCHER, id);
    hold_as(&mut sc, &clock, WATCHER, id);
    finish(sc, clock);
}

#[test]
fun a_brake_can_still_hold_a_payment_that_just_became_ready() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    clock.increment_for_testing(QUEUE);
    hold_as(&mut sc, &clock, WATCHER, id);
    assert!(state(&mut sc, &clock, id) == 0); // waiting again
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::ECannotCancel)]
fun a_hold_only_brake_cannot_cancel() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    cancel_as_brake(&mut sc, WATCHER, id);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::ENotWaiting)]
fun a_canceled_payment_can_never_be_sent() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    cancel_as_brake(&mut sc, PHONE, id);
    assert!(state(&mut sc, &clock, id) == 3); // canceled
    clock.increment_for_testing(QUEUE + HOLD);
    execute(&mut sc, &clock, id);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::ENotWaiting)]
fun a_payment_is_sent_only_once() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    clock.increment_for_testing(QUEUE);
    execute(&mut sc, &clock, id);
    execute(&mut sc, &clock, id);
    finish(sc, clock);
}

#[test]
fun the_agent_can_cancel_its_own_payment() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    sc.next_tx(AGENT);
    {
        let driver = sc.take_from_sender<DriverCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        brake::cancel_as_driver(&driver, &mut vault, id);
        ts::return_shared(vault);
        sc.return_to_sender(driver);
    };
    assert!(state(&mut sc, &clock, id) == 3);
    finish(sc, clock);
}

// ---------------------------------------------------------------- keys

#[test, expected_failure(abort_code = brake::EKeyRevoked)]
fun a_revoked_brake_cannot_hold() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    sc.next_tx(WATCHER);
    let watcher_cap = sc.take_from_sender<BrakeCap>();
    let watcher_id = object::id(&watcher_cap);
    sc.return_to_sender(watcher_cap);
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        brake::revoke(&owner, &mut vault, watcher_id);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    hold_as(&mut sc, &clock, WATCHER, id);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::EKeyRevoked)]
fun a_revoked_agent_cannot_propose() {
    let (mut sc, clock) = setup();
    sc.next_tx(AGENT);
    let driver = sc.take_from_sender<DriverCap>();
    let driver_id = object::id(&driver);
    sc.return_to_sender(driver);
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        brake::revoke(&owner, &mut vault, driver_id);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    propose(&mut sc, &clock, ALEX, 100);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::EWrongVault)]
fun a_key_from_another_vault_is_rejected() {
    let (mut sc, clock) = setup();
    sc.next_tx(OWNER);
    let mine = sc.take_shared<Vault<SUI>>();
    let my_vault = object::id(&mine);
    ts::return_shared(mine);
    // Someone else's vault and owner key.
    sc.next_tx(ATTACKER);
    let other_owner = brake::create<SUI>(QUEUE, HOLD, EXPIRY, LIMIT, coin::mint_for_testing(1, sc.ctx()), sc.ctx());
    sc.next_tx(ATTACKER);
    let mut vault = sc.take_shared_by_id<Vault<SUI>>(my_vault);
    brake::set_trusted(&other_owner, &mut vault, ATTACKER, true);
    ts::return_shared(vault);
    transfer::public_transfer(other_owner, ATTACKER);
    finish(sc, clock);
}

#[test]
fun the_owner_can_withdraw() {
    let (mut sc, clock) = setup();
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        let out = brake::withdraw(&owner, &mut vault, 1_000, sc.ctx());
        assert!(out.value() == 1_000);
        transfer::public_transfer(out, OWNER);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    assert!(vault_balance(&mut sc) == START - 1_000);
    finish(sc, clock);
}

// ---------------------------------------------------------------- one-transaction setup

#[test]
fun a_wallet_can_set_everything_up_in_one_transaction() {
    let mut sc = ts::begin(OWNER);
    let clock = clock::create_for_testing(sc.ctx());
    {
        let (mut vault, owner) = brake::new<SUI>(QUEUE, HOLD, EXPIRY, LIMIT, coin::mint_for_testing(START, sc.ctx()), sc.ctx());
        transfer::public_transfer(brake::issue_driver(&owner, &mut vault, sc.ctx()), AGENT);
        transfer::public_transfer(brake::issue_brake(&owner, &mut vault, false, sc.ctx()), WATCHER);
        brake::set_trusted(&owner, &mut vault, ALEX, true);
        brake::share(vault);
        transfer::public_transfer(owner, OWNER);
    };
    propose(&mut sc, &clock, ALEX, 100);
    assert!(received(&mut sc, ALEX) == 100);
    finish(sc, clock);
}

// ---------------------------------------------------------------- holds count from the hold

#[test]
fun a_hold_on_a_ready_payment_counts_from_now() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    clock.increment_for_testing(QUEUE + 50_000); // ready for a while, nobody sent it
    hold_as(&mut sc, &clock, WATCHER, id);
    sc.next_tx(OWNER);
    let vault = sc.take_shared<Vault<SUI>>();
    assert!(brake::payment_ready_ms(&vault, id) == QUEUE + 50_000 + HOLD);
    ts::return_shared(vault);
    finish(sc, clock);
}

#[test]
fun a_second_brake_holds_from_the_end_of_the_first_hold() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    hold_as(&mut sc, &clock, WATCHER, id);
    hold_as(&mut sc, &clock, PHONE, id);
    sc.next_tx(OWNER);
    let vault = sc.take_shared<Vault<SUI>>();
    assert!(brake::payment_ready_ms(&vault, id) == QUEUE + 2 * HOLD);
    ts::return_shared(vault);
    finish(sc, clock);
}

// ---------------------------------------------------------------- expiry

#[test, expected_failure(abort_code = brake::EExpired)]
fun a_payment_nobody_sends_in_time_expires() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    clock.increment_for_testing(QUEUE + EXPIRY);
    execute(&mut sc, &clock, id);
    finish(sc, clock);
}

#[test]
fun an_expired_payment_reads_as_expired() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    clock.increment_for_testing(QUEUE + EXPIRY - 1);
    assert!(state(&mut sc, &clock, id) == 1); // ready
    clock.increment_for_testing(1);
    assert!(state(&mut sc, &clock, id) == 4); // expired
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::EExpired)]
fun an_expired_payment_cannot_be_held_back_to_life() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    clock.increment_for_testing(QUEUE + EXPIRY);
    hold_as(&mut sc, &clock, WATCHER, id);
    finish(sc, clock);
}

#[test]
fun a_hold_pushes_the_expiry_back_too() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    hold_as(&mut sc, &clock, WATCHER, id);
    clock.increment_for_testing(QUEUE + EXPIRY); // would have expired without the hold
    execute(&mut sc, &clock, id);
    assert!(received(&mut sc, ATTACKER) == 5_000);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::EInvalidConfig)]
fun a_vault_needs_a_wait_a_hold_and_an_expiry() {
    let mut sc = ts::begin(OWNER);
    let owner = brake::create<SUI>(0, HOLD, EXPIRY, LIMIT, coin::mint_for_testing(1, sc.ctx()), sc.ctx());
    transfer::public_transfer(owner, OWNER);
    sc.end();
}

// ---------------------------------------------------------------- revocation voids the queue

#[test, expected_failure(abort_code = brake::EKeyRevoked)]
fun revoking_the_agent_voids_what_it_queued() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    let driver = key_of<DriverCap>(&mut sc, AGENT);
    revoke(&mut sc, driver);
    clock.increment_for_testing(QUEUE);
    execute(&mut sc, &clock, id);
    finish(sc, clock);
}

#[test]
fun a_voided_payment_reads_as_voided_and_can_be_pruned() {
    let (mut sc, mut clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    let driver = key_of<DriverCap>(&mut sc, AGENT);
    revoke(&mut sc, driver);
    clock.increment_for_testing(QUEUE);
    assert!(state(&mut sc, &clock, id) == 5);
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        brake::prune(&owner, &mut vault, id, &clock);
        assert!(brake::payment_count(&vault) == 0);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    finish(sc, clock);
}

#[test]
fun the_owner_cancels_many_at_once_and_skips_the_finished_ones() {
    let (mut sc, clock) = setup();
    let sent = propose(&mut sc, &clock, ALEX, 100); // instant: already sent
    let a = propose(&mut sc, &clock, ATTACKER, 1_000);
    let b = propose(&mut sc, &clock, ATTACKER, 2_000);
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        brake::cancel_many_as_owner(&owner, &mut vault, vector[sent, a, b]);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    assert!(state(&mut sc, &clock, sent) == 2);
    assert!(state(&mut sc, &clock, a) == 3);
    assert!(state(&mut sc, &clock, b) == 3);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::EStillLive)]
fun a_live_payment_cannot_be_pruned() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    sc.next_tx(OWNER);
    let owner = sc.take_from_sender<OwnerCap>();
    let mut vault = sc.take_shared<Vault<SUI>>();
    brake::prune(&owner, &mut vault, id, &clock);
    ts::return_shared(vault);
    sc.return_to_sender(owner);
    finish(sc, clock);
}

// ---------------------------------------------------------------- keys from another vault

#[test, expected_failure(abort_code = brake::EWrongVault)]
fun a_brake_from_another_vault_cannot_hold() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    sc.next_tx(OWNER);
    let mine = sc.take_shared<Vault<SUI>>();
    let my_vault = object::id(&mine);
    ts::return_shared(mine);
    // The attacker makes a vault of their own and issues themselves a brake key for it.
    sc.next_tx(ATTACKER);
    let other_owner = brake::create<SUI>(QUEUE, HOLD, EXPIRY, LIMIT, coin::mint_for_testing(1, sc.ctx()), sc.ctx());
    sc.next_tx(ATTACKER);
    let other_id = ts::most_recent_id_shared<Vault<SUI>>().destroy_some();
    let mut other = sc.take_shared_by_id<Vault<SUI>>(other_id);
    let evil = brake::issue_brake(&other_owner, &mut other, true, sc.ctx());
    ts::return_shared(other);
    // ... and tries it on mine.
    let mut mine = sc.take_shared_by_id<Vault<SUI>>(my_vault);
    brake::hold(&evil, &mut mine, id, &clock);
    ts::return_shared(mine);
    transfer::public_transfer(evil, ATTACKER);
    transfer::public_transfer(other_owner, ATTACKER);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::EWrongVault)]
fun a_driver_from_another_vault_cannot_propose() {
    let (mut sc, clock) = setup();
    sc.next_tx(OWNER);
    let mine = sc.take_shared<Vault<SUI>>();
    let my_vault = object::id(&mine);
    ts::return_shared(mine);
    sc.next_tx(ATTACKER);
    let other_owner = brake::create<SUI>(QUEUE, HOLD, EXPIRY, LIMIT, coin::mint_for_testing(1, sc.ctx()), sc.ctx());
    sc.next_tx(ATTACKER);
    let other_id = ts::most_recent_id_shared<Vault<SUI>>().destroy_some();
    let mut other = sc.take_shared_by_id<Vault<SUI>>(other_id);
    let evil = brake::issue_driver(&other_owner, &mut other, sc.ctx());
    ts::return_shared(other);
    let mut mine = sc.take_shared_by_id<Vault<SUI>>(my_vault);
    brake::propose(&evil, &mut mine, ATTACKER, 1, string::utf8(b"x"), &clock, sc.ctx());
    ts::return_shared(mine);
    transfer::public_transfer(evil, ATTACKER);
    transfer::public_transfer(other_owner, ATTACKER);
    finish(sc, clock);
}

// ---------------------------------------------------------------- config

#[test, expected_failure(abort_code = brake::EInvalidConfig)]
fun a_vault_needs_a_hold() {
    let mut sc = ts::begin(OWNER);
    let owner = brake::create<SUI>(QUEUE, 0, EXPIRY, LIMIT, coin::mint_for_testing(1, sc.ctx()), sc.ctx());
    transfer::public_transfer(owner, OWNER);
    sc.end();
}

#[test, expected_failure(abort_code = brake::EInvalidConfig)]
fun a_vault_needs_an_expiry() {
    let mut sc = ts::begin(OWNER);
    let owner = brake::create<SUI>(QUEUE, HOLD, 0, LIMIT, coin::mint_for_testing(1, sc.ctx()), sc.ctx());
    transfer::public_transfer(owner, OWNER);
    sc.end();
}

#[test, expected_failure(abort_code = brake::EInvalidConfig)]
fun a_wait_over_ten_years_is_refused() {
    let mut sc = ts::begin(OWNER);
    let owner = brake::create<SUI>(315_360_000_001, HOLD, EXPIRY, LIMIT, coin::mint_for_testing(1, sc.ctx()), sc.ctx());
    transfer::public_transfer(owner, OWNER);
    sc.end();
}

#[test]
fun config_and_key_views_read_back() {
    let (mut sc, clock) = setup();
    let driver = key_of<DriverCap>(&mut sc, AGENT);
    sc.next_tx(OWNER);
    let vault = sc.take_shared<Vault<SUI>>();
    let (q, h, e, l) = brake::config(&vault);
    assert!(q == QUEUE && h == HOLD && e == EXPIRY && l == LIMIT);
    assert!(brake::is_key(&vault, driver));
    assert!(!brake::has_payment(&vault, 0));
    ts::return_shared(vault);
    finish(sc, clock);
}

// ---------------------------------------------------------------- events

#[test]
fun key_deposit_and_withdraw_events_are_emitted() {
    let (mut sc, clock) = setup();
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        let cap = brake::issue_brake(&owner, &mut vault, false, sc.ctx());
        let key = object::id(&cap);
        brake::revoke(&owner, &mut vault, key);
        brake::revoke(&owner, &mut vault, key); // a second revoke of the same key is a silent no-op
        brake::deposit(&mut vault, coin::mint_for_testing(50, sc.ctx()));
        let out = brake::withdraw(&owner, &mut vault, 20, sc.ctx());
        assert!(event::events_by_type<KeyIssued>().length() == 1);
        assert!(event::events_by_type<KeyRevoked>().length() == 1);
        assert!(event::events_by_type<Deposited>().length() == 1);
        assert!(event::events_by_type<Withdrawn>().length() == 1);
        transfer::public_transfer(out, OWNER);
        transfer::public_transfer(cap, WATCHER);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    assert!(vault_balance(&mut sc) == START + 50 - 20);
    finish(sc, clock);
}

// ---------------------------------------------------------------- more rules

#[test]
fun cancel_many_skips_unknown_and_pruned_numbers() {
    let (mut sc, clock) = setup();
    let a = propose(&mut sc, &clock, ATTACKER, 1_000);
    let b = propose(&mut sc, &clock, ATTACKER, 2_000);
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        brake::cancel_as_owner(&owner, &mut vault, b);
        brake::prune(&owner, &mut vault, b, &clock);
        brake::cancel_many_as_owner(&owner, &mut vault, vector[a, b, 999]); // pruned and unknown: skipped
        assert!(!brake::has_payment(&vault, b));
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    assert!(state(&mut sc, &clock, a) == 3);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::EKeyRevoked)]
fun a_brake_cannot_hold_a_voided_payment() {
    let (mut sc, clock) = setup();
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    let driver = key_of<DriverCap>(&mut sc, AGENT);
    revoke(&mut sc, driver);
    hold_as(&mut sc, &clock, WATCHER, id);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::ENotEnoughFunds)]
fun an_instant_payment_above_the_balance_aborts_with_brakes_own_code() {
    let (mut sc, clock) = setup();
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        let out = brake::withdraw(&owner, &mut vault, START - 10, sc.ctx());
        transfer::public_transfer(out, OWNER);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    propose(&mut sc, &clock, ALEX, 100); // trusted and within the limit, but the vault holds 10
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::ENoteTooLong)]
fun a_note_over_256_bytes_is_refused() {
    let (mut sc, clock) = setup();
    sc.next_tx(AGENT);
    let driver = sc.take_from_sender<DriverCap>();
    let mut vault = sc.take_shared<Vault<SUI>>();
    let mut note = vector[];
    257u64.do!(|_| note.push_back(97u8));
    brake::propose(&driver, &mut vault, ATTACKER, 1, string::utf8(note), &clock, sc.ctx());
    ts::return_shared(vault);
    sc.return_to_sender(driver);
    finish(sc, clock);
}

#[test, expected_failure(abort_code = brake::ENotProposer)]
fun a_driver_cannot_cancel_another_drivers_payment() {
    let (mut sc, clock) = setup();
    sc.next_tx(OWNER);
    {
        let owner = sc.take_from_sender<OwnerCap>();
        let mut vault = sc.take_shared<Vault<SUI>>();
        transfer::public_transfer(brake::issue_driver(&owner, &mut vault, sc.ctx()), AGENT2);
        ts::return_shared(vault);
        sc.return_to_sender(owner);
    };
    let id = propose(&mut sc, &clock, ATTACKER, 5_000);
    sc.next_tx(AGENT2);
    let other = sc.take_from_sender<DriverCap>();
    let mut vault = sc.take_shared<Vault<SUI>>();
    brake::cancel_as_driver(&other, &mut vault, id);
    ts::return_shared(vault);
    sc.return_to_sender(other);
    finish(sc, clock);
}

#[test]
fun daily_limit_is_per_utc_day_not_rolling() {
    let (mut sc, mut clock) = setup();
    clock.increment_for_testing(DAY - 1);
    propose(&mut sc, &clock, ALEX, LIMIT);
    clock.increment_for_testing(1); // midnight
    propose(&mut sc, &clock, ALEX, LIMIT);
    assert!(received(&mut sc, ALEX) == 2 * LIMIT); // twice the limit, one second apart: documented
    finish(sc, clock);
}

#[test]
fun anyone_can_deposit() {
    let (mut sc, clock) = setup();
    sc.next_tx(RELAYER);
    let mut vault = sc.take_shared<Vault<SUI>>();
    brake::deposit(&mut vault, coin::mint_for_testing(1_000, sc.ctx()));
    ts::return_shared(vault);
    assert!(vault_balance(&mut sc) == START + 1_000);
    finish(sc, clock);
}
