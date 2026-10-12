/// Brake: a brake pedal for wallets run by AI agents.
///
/// A `Vault<T>` holds the coins. Three kinds of key, each an object:
/// - `DriverCap` (the agent): proposes payments.
/// - `BrakeCap` (phone, friend, watcher): holds a waiting payment once, or cancels it if allowed.
///   No function here lets a `BrakeCap` move coins.
/// - `OwnerCap` (you): trusted contacts, keys, withdrawals.
///
/// Small payments to trusted contacts within the daily limit go out at once. Anything else waits
/// `queue_ms` in the vault, where brakes can see it, and anyone can send it once the wait is over,
/// for `expiry_ms` after that. A payment nobody sends in time expires. Revoking a key voids every
/// payment it still has waiting, for good. Withdrawing does not: to defuse a queued payment, cancel
/// it or revoke the key that proposed it.
///
/// The queue carries payments (a recipient and an amount) and nothing else, so no key can change
/// the vault's rules by waiting out the queue. Only the `OwnerCap` changes the rules, directly, and
/// the owner is instant by design (a stolen owner key is game over, as with any wallet).
module brake::brake;

use std::string::String;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};
use sui::vec_set::{Self, VecSet};

const EWrongVault: u64 = 1;
const EKeyRevoked: u64 = 2;
const ENotReady: u64 = 3;
const ENotWaiting: u64 = 4;
const EAlreadyHeld: u64 = 5;
const ECannotCancel: u64 = 6;
const ENotProposer: u64 = 7;
const ENotEnoughFunds: u64 = 8;
const EExpired: u64 = 9;
const EInvalidConfig: u64 = 10;
const EStillLive: u64 = 11;
const ENoteTooLong: u64 = 12;

// Payment states. READY, EXPIRED and VOIDED are never stored: all three are WAITING plus time
// passed or a revoked key.
const WAITING: u8 = 0;
const READY: u8 = 1;
const SENT: u8 = 2;
const CANCELED: u8 = 3;
const EXPIRED: u8 = 4;
const VOIDED: u8 = 5;

const DAY_MS: u64 = 86_400_000;
/// Longest wait, hold or expiry accepted at creation: ten years. Keeps time arithmetic in range.
const MAX_MS: u64 = 315_360_000_000;
/// Longest note a driver may attach to a payment, in bytes. The note is free text written by the
/// driver: a watcher reading it with a language model must treat it as data, never as instructions.
const MAX_NOTE_BYTES: u64 = 256;

public struct Vault<phantom T> has key {
    id: UID,
    balance: Balance<T>,
    queue_ms: u64,
    max_hold_ms: u64,
    /// How long after its ready time a waiting payment can still be sent. After that it is dead.
    expiry_ms: u64,
    daily_limit: u64,
    spent_day: u64,
    spent_today: u64,
    trusted: Table<address, bool>,
    /// Driver and brake caps this vault still accepts. Removing an ID revokes that key.
    keys: VecSet<ID>,
    payments: Table<u64, Payment>,
    next_payment: u64,
}

public struct Payment has store {
    to: address,
    amount: u64,
    note: String,
    proposer: ID,
    created_ms: u64,
    ready_ms: u64,
    held_by: VecSet<ID>,
    state: u8,
}

/// The caps have `store` so an owner can wrap them (a future timelock around the owner key, a
/// Kiosk, a multisig object). The flip side: whoever signs `public_freeze_object` on an OwnerCap, or
/// `public_share_object` in the same transaction that created it, makes it usable by anyone. Treat
/// the OwnerCap like the seed phrase it effectively is, and check what a setup transaction does with
/// it before approving.
public struct OwnerCap has key, store { id: UID, vault: ID }

public struct DriverCap has key, store { id: UID, vault: ID }

public struct BrakeCap has key, store { id: UID, vault: ID, can_cancel: bool }

public struct Proposed has copy, drop {
    vault: ID,
    payment: u64,
    to: address,
    amount: u64,
    instant: bool,
    ready_ms: u64,
    note: String,
}

public struct Held has copy, drop { vault: ID, payment: u64, brake: ID, until_ms: u64 }

public struct Canceled has copy, drop { vault: ID, payment: u64 }

public struct Sent has copy, drop { vault: ID, payment: u64, to: address, amount: u64 }

public struct Pruned has copy, drop { vault: ID, payment: u64 }

public struct TrustedSet has copy, drop { vault: ID, contact: address, trusted: bool }

/// A driver or brake key was issued. `driver` false means a brake key.
public struct KeyIssued has copy, drop { vault: ID, key: ID, driver: bool, can_cancel: bool }

public struct KeyRevoked has copy, drop { vault: ID, key: ID }

public struct Deposited has copy, drop { vault: ID, amount: u64 }

public struct Withdrawn has copy, drop { vault: ID, amount: u64 }

// ---------------------------------------------------------------- owner

/// Creates a vault holding `funds` and returns its owner key. The vault is shared.
public fun create<T>(
    queue_ms: u64,
    max_hold_ms: u64,
    expiry_ms: u64,
    daily_limit: u64,
    funds: Coin<T>,
    ctx: &mut TxContext,
): OwnerCap {
    let (vault, owner) = new(queue_ms, max_hold_ms, expiry_ms, daily_limit, funds, ctx);
    share(vault);
    owner
}

/// Like `create`, but leaves the vault unshared so the same transaction can hand out keys and add
/// trusted contacts before calling `share`. Lets a wallet set everything up with one approval.
public fun new<T>(
    queue_ms: u64,
    max_hold_ms: u64,
    expiry_ms: u64,
    daily_limit: u64,
    funds: Coin<T>,
    ctx: &mut TxContext,
): (Vault<T>, OwnerCap) {
    assert!(
        queue_ms > 0 && queue_ms <= MAX_MS &&
        max_hold_ms > 0 && max_hold_ms <= MAX_MS &&
        expiry_ms > 0 && expiry_ms <= MAX_MS,
        EInvalidConfig,
    );
    let vault = Vault<T> {
        id: object::new(ctx),
        balance: funds.into_balance(),
        queue_ms,
        max_hold_ms,
        expiry_ms,
        daily_limit,
        spent_day: 0,
        spent_today: 0,
        trusted: table::new(ctx),
        keys: vec_set::empty(),
        payments: table::new(ctx),
        next_payment: 0,
    };
    let owner = OwnerCap { id: object::new(ctx), vault: object::id(&vault) };
    (vault, owner)
}

/// Makes a vault from `new` usable by everyone's keys.
public fun share<T>(vault: Vault<T>) {
    transfer::share_object(vault);
}

public fun deposit<T>(vault: &mut Vault<T>, funds: Coin<T>) {
    let amount = funds.value();
    vault.balance.join(funds.into_balance());
    event::emit(Deposited { vault: object::id(vault), amount });
}

public fun withdraw<T>(owner: &OwnerCap, vault: &mut Vault<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    check_owner(owner, vault);
    assert!(vault.balance.value() >= amount, ENotEnoughFunds);
    event::emit(Withdrawn { vault: object::id(vault), amount });
    coin::take(&mut vault.balance, amount, ctx)
}

public fun issue_driver<T>(owner: &OwnerCap, vault: &mut Vault<T>, ctx: &mut TxContext): DriverCap {
    check_owner(owner, vault);
    let cap = DriverCap { id: object::new(ctx), vault: object::id(vault) };
    let key = object::id(&cap);
    vault.keys.insert(key);
    event::emit(KeyIssued { vault: object::id(vault), key, driver: true, can_cancel: false });
    cap
}

public fun issue_brake<T>(owner: &OwnerCap, vault: &mut Vault<T>, can_cancel: bool, ctx: &mut TxContext): BrakeCap {
    check_owner(owner, vault);
    let cap = BrakeCap { id: object::new(ctx), vault: object::id(vault), can_cancel };
    let key = object::id(&cap);
    vault.keys.insert(key);
    event::emit(KeyIssued { vault: object::id(vault), key, driver: false, can_cancel });
    cap
}

/// Stops the vault accepting a driver or brake key, e.g. a lost phone. The object can't be
/// taken back, so the vault forgets it instead. Payments a revoked driver still has waiting can
/// never be sent (see `execute`); the owner can cancel or prune them at leisure.
public fun revoke<T>(owner: &OwnerCap, vault: &mut Vault<T>, key: ID) {
    check_owner(owner, vault);
    if (vault.keys.contains(&key)) {
        vault.keys.remove(&key);
        event::emit(KeyRevoked { vault: object::id(vault), key });
    }
}

public fun set_trusted<T>(owner: &OwnerCap, vault: &mut Vault<T>, contact: address, trusted: bool) {
    check_owner(owner, vault);
    let known = vault.trusted.contains(contact);
    if (trusted && !known) vault.trusted.add(contact, true);
    if (!trusted && known) { vault.trusted.remove(contact); };
    event::emit(TrustedSet { vault: object::id(vault), contact, trusted });
}

public fun cancel_as_owner<T>(owner: &OwnerCap, vault: &mut Vault<T>, payment: u64) {
    check_owner(owner, vault);
    cancel(vault, payment);
}

/// Cancels every listed payment that is still waiting, in one transaction. Numbers that are
/// finished, pruned or unknown are skipped, so a list pasted in a hurry never aborts the batch.
public fun cancel_many_as_owner<T>(owner: &OwnerCap, vault: &mut Vault<T>, payments: vector<u64>) {
    check_owner(owner, vault);
    payments.do!(|n| if (vault.payments.contains(n) && vault.payments[n].state == WAITING) cancel(vault, n));
}

/// Removes the record of a payment that is sent, canceled, expired or voided, to reclaim storage.
/// Reads of a pruned number abort; `has_payment` tells a watcher whether a record still exists.
public fun prune<T>(owner: &OwnerCap, vault: &mut Vault<T>, payment: u64, clock: &Clock) {
    check_owner(owner, vault);
    let s = payment_state(vault, payment, clock);
    assert!(s == SENT || s == CANCELED || s == EXPIRED || s == VOIDED, EStillLive);
    let Payment { to: _, amount: _, note: _, proposer: _, created_ms: _, ready_ms: _, held_by: _, state: _ } =
        vault.payments.remove(payment);
    event::emit(Pruned { vault: object::id(vault), payment });
}

// ---------------------------------------------------------------- agent

/// Proposes a payment. Goes out at once if `to` is trusted and it fits today's limit; otherwise
/// it waits `queue_ms`. Returns the payment number.
public fun propose<T>(
    driver: &DriverCap,
    vault: &mut Vault<T>,
    to: address,
    amount: u64,
    note: String,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    check_key(vault, driver.vault, object::id(driver));
    assert!(note.length() <= MAX_NOTE_BYTES, ENoteTooLong);
    let now = clock.timestamp_ms();
    let (instant, spent_after) = lane(vault, to, amount, now);
    let number = vault.next_payment;
    vault.next_payment = number + 1;

    let (state, ready_ms) = if (instant) {
        assert!(vault.balance.value() >= amount, ENotEnoughFunds);
        vault.spent_day = now / DAY_MS;
        vault.spent_today = spent_after;
        transfer::public_transfer(coin::take(&mut vault.balance, amount, ctx), to);
        (SENT, now)
    } else {
        (WAITING, now + vault.queue_ms)
    };
    vault.payments.add(number, Payment {
        to,
        amount,
        note,
        proposer: object::id(driver),
        created_ms: now,
        ready_ms,
        held_by: vec_set::empty(),
        state,
    });
    event::emit(Proposed { vault: object::id(vault), payment: number, to, amount, instant, ready_ms, note });
    if (instant) event::emit(Sent { vault: object::id(vault), payment: number, to, amount });
    number
}

/// What would happen if the agent proposed this now: (goes out at once, milliseconds it would wait).
/// Read-only, so an agent can check its limits and ask the owner instead of queueing.
public fun preview<T>(vault: &Vault<T>, to: address, amount: u64, clock: &Clock): (bool, u64) {
    let (instant, _) = lane(vault, to, amount, clock.timestamp_ms());
    if (instant) (true, 0) else (false, vault.queue_ms)
}

public fun cancel_as_driver<T>(driver: &DriverCap, vault: &mut Vault<T>, payment: u64) {
    check_key(vault, driver.vault, object::id(driver));
    assert!(vault.payments[payment].proposer == object::id(driver), ENotProposer);
    cancel(vault, payment);
}

// ---------------------------------------------------------------- brakes

/// Pushes a waiting payment back by `max_hold_ms`, counted from now or from when it was due,
/// whichever is later. Each brake can hold a given payment once, so a bad brake can only delay.
/// An expired or voided payment cannot be held back to life.
public fun hold<T>(brake: &BrakeCap, vault: &mut Vault<T>, payment: u64, clock: &Clock) {
    let brake_id = object::id(brake);
    check_key(vault, brake.vault, brake_id);
    let max_hold = vault.max_hold_ms;
    let now = clock.timestamp_ms();
    let (proposer, state, ready_ms) = {
        let p = &vault.payments[payment];
        (p.proposer, p.state, p.ready_ms)
    };
    assert!(state == WAITING, ENotWaiting);
    assert!(now < ready_ms + vault.expiry_ms, EExpired);
    assert!(vault.keys.contains(&proposer), EKeyRevoked);
    let p = &mut vault.payments[payment];
    assert!(!p.held_by.contains(&brake_id), EAlreadyHeld);
    p.held_by.insert(brake_id);
    p.ready_ms = p.ready_ms.max(now) + max_hold;
    let until_ms = p.ready_ms;
    event::emit(Held { vault: object::id(vault), payment, brake: brake_id, until_ms });
}

public fun cancel_as_brake<T>(brake: &BrakeCap, vault: &mut Vault<T>, payment: u64) {
    check_key(vault, brake.vault, object::id(brake));
    assert!(brake.can_cancel, ECannotCancel);
    cancel(vault, payment);
}

// ---------------------------------------------------------------- anyone

/// Sends a payment whose wait is over and whose expiry has not passed. Anyone can call it, so
/// nobody has to be awake for it. A payment whose proposer key was revoked is never sent.
public fun execute<T>(vault: &mut Vault<T>, payment: u64, clock: &Clock, ctx: &mut TxContext) {
    let now = clock.timestamp_ms();
    let (proposer, state, ready_ms) = {
        let p = &vault.payments[payment];
        (p.proposer, p.state, p.ready_ms)
    };
    assert!(state == WAITING, ENotWaiting);
    assert!(now >= ready_ms, ENotReady);
    assert!(now < ready_ms + vault.expiry_ms, EExpired);
    assert!(vault.keys.contains(&proposer), EKeyRevoked);
    let p = &mut vault.payments[payment];
    p.state = SENT;
    let (to, amount) = (p.to, p.amount);
    assert!(vault.balance.value() >= amount, ENotEnoughFunds);
    transfer::public_transfer(coin::take(&mut vault.balance, amount, ctx), to);
    event::emit(Sent { vault: object::id(vault), payment, to, amount });
}

// ---------------------------------------------------------------- reads

public fun balance<T>(vault: &Vault<T>): u64 { vault.balance.value() }

public fun is_trusted<T>(vault: &Vault<T>, contact: address): bool { vault.trusted.contains(contact) }

/// Whether the vault still accepts this driver or brake key.
public fun is_key<T>(vault: &Vault<T>, key: ID): bool { vault.keys.contains(&key) }

/// (queue_ms, max_hold_ms, expiry_ms, daily_limit)
public fun config<T>(vault: &Vault<T>): (u64, u64, u64, u64) {
    (vault.queue_ms, vault.max_hold_ms, vault.expiry_ms, vault.daily_limit)
}

/// How many payment records the vault holds (sent and canceled ones included, until pruned).
public fun payment_count<T>(vault: &Vault<T>): u64 { vault.payments.length() }

/// Whether a record exists for this payment number (false once pruned, or never issued).
public fun has_payment<T>(vault: &Vault<T>, payment: u64): bool { vault.payments.contains(payment) }

/// 0 waiting, 1 ready, 2 sent, 3 canceled, 4 expired, 5 voided (still waiting, but its proposer key
/// was revoked, so it can never be sent).
public fun payment_state<T>(vault: &Vault<T>, payment: u64, clock: &Clock): u8 {
    let p = &vault.payments[payment];
    if (p.state != WAITING) return p.state;
    if (!vault.keys.contains(&p.proposer)) return VOIDED;
    let now = clock.timestamp_ms();
    if (now >= p.ready_ms + vault.expiry_ms) EXPIRED
    else if (now >= p.ready_ms) READY
    else WAITING
}

public fun payment_ready_ms<T>(vault: &Vault<T>, payment: u64): u64 { vault.payments[payment].ready_ms }

// ---------------------------------------------------------------- internal

fun check_owner<T>(owner: &OwnerCap, vault: &Vault<T>) {
    assert!(owner.vault == object::id(vault), EWrongVault);
}

fun check_key<T>(vault: &Vault<T>, key_vault: ID, key: ID) {
    assert!(key_vault == object::id(vault), EWrongVault);
    assert!(vault.keys.contains(&key), EKeyRevoked);
}

/// (goes out at once, today's spend if it does). Trusted contact and within today's limit.
fun lane<T>(vault: &Vault<T>, to: address, amount: u64, now: u64): (bool, u64) {
    if (!vault.trusted.contains(to)) return (false, 0);
    let spent = if (now / DAY_MS == vault.spent_day) vault.spent_today else 0;
    let after = spent + amount;
    if (after > vault.daily_limit) (false, 0) else (true, after)
}

fun cancel<T>(vault: &mut Vault<T>, payment: u64) {
    let p = &mut vault.payments[payment];
    assert!(p.state == WAITING, ENotWaiting);
    p.state = CANCELED;
    event::emit(Canceled { vault: object::id(vault), payment });
}
