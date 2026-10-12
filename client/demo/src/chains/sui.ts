import { bcs } from '@mysten/sui/bcs'
import type { Keypair } from '@mysten/sui/cryptography'
import { SuiGrpcClient } from '@mysten/sui/grpc'
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519'
import { Transaction } from '@mysten/sui/transactions'
import net from './sui/testnet.json'
import { connectWallet, restoreWallet, walletAddress, walletExecute } from './sui/wallet'
import type { Chain, Op, OpState, Tx } from './types'

// gRPC: the public testnet node allows it from browsers (JSON-RPC is blocked by CORS and deprecated).
const client = new SuiGrpcClient({ network: 'testnet', baseUrl: net.grpc })
const CLOCK = '0x6'
const DUSD = `${net.dusdPackage}::dusd::DUSD`
const UNIT = 1_000_000 // dUSD has 6 decimals, like USDC

/** The story's numbers: an hour in the queue, six more on hold, a week to send it before it expires. */
const CONFIG = {
  queueMs: 3_600_000,
  holdMs: 21_600_000,
  expiryMs: 604_800_000,
  dailyLimit: 500,
  start: 20_000,
  /** Testnet SUI sent to each demo key for gas, when it runs low. */
  gasMist: 50_000_000n,
  lowGasMist: 20_000_000n,
}

// ---------------------------------------------------------------- demo keys

/**
 * The agent and the watcher are throwaway keys made in this browser. Their only funds are a little
 * testnet SUI for gas, sent by the viewer's wallet during setup.
 */
function sessionKey(name: string): Ed25519Keypair {
  const k = `brake-sui-key:${name}`
  try {
    const saved = localStorage.getItem(k)
    if (saved) return Ed25519Keypair.fromSecretKey(saved)
    const fresh = Ed25519Keypair.generate()
    localStorage.setItem(k, fresh.getSecretKey())
    return fresh
  } catch {
    return Ed25519Keypair.generate()
  }
}
const AGENT = sessionKey('agent')
const WATCHER = sessionKey('watcher')

/** One run of the story: its vault and keys, and the people in it (Alex, Sam, the attacker). */
type World = {
  owner: string
  friend: string
  vault: string
  ownerCap: string
  phoneCap: string
  driverCap: string
  watcherCap: string
  sam: string
  attacker: string
  createdMs: number
}
let world: World | null = null

/**
 * The plain "Without Brake" wallet is simulated: it only shows what happens with no brake, which
 * nobody doubts. Its balance lives here and resets with each run; only Brake's side is on chain.
 */
let plain = { balance: 0, sentToAttacker: 0 }

const worldKey = (owner: string) => `brake-sui-world:${net.brakePackage}:${owner}`

function setWorld(w: World | null) {
  world = w
  plain = { balance: w ? CONFIG.start : 0, sentToAttacker: 0 }
  const owner = walletAddress()
  if (!owner) return
  try {
    if (w) localStorage.setItem(worldKey(owner), JSON.stringify(w))
    else localStorage.removeItem(worldKey(owner))
  } catch {
    /* the world still works for this page view */
  }
}

function need(): World {
  if (!world) throw new Error('Set up the demo first')
  return world
}

// ---------------------------------------------------------------- transactions

const toUnits = (amount: string) => BigInt(Math.round(Number(amount) * UNIT))
const fromUnits = (units: string | bigint) => (Number(BigInt(units)) / UNIT).toString()
const target = (fn: string) => `${net.brakePackage}::brake::${fn}` as const
const txListeners = new Set<(tx: Tx) => void>()

function logTx(who: string, call: string, digest: string) {
  txListeners.forEach((fn) => fn({ who, call, hash: digest, where: 'Sui testnet', url: `${net.explorer}/tx/${digest}` }))
}

/** Waits until `digest` is final; throws with the chain's reason if it failed. */
async function confirm(digest: string, call: string) {
  const res = await client.waitForTransaction({ digest, include: { effects: true, objectTypes: true } })
  const tx = res.Transaction ?? res.FailedTransaction
  if (!tx.status.success) throw new Error(`${call} failed: ${JSON.stringify(tx.status.error)}`)
  return tx
}

/** A demo key signs and sends. */
async function exec(signer: Keypair, tx: Transaction, who: string, call: string) {
  const res = await client.signAndExecuteTransaction({ transaction: tx, signer })
  const digest = (res.Transaction ?? res.FailedTransaction).digest
  await confirm(digest, call)
  logTx(who, call, digest)
}

/** The viewer's wallet approves and sends. */
async function execWallet(tx: Transaction, who: string, call: string) {
  const digest = await walletExecute(tx)
  await confirm(digest, call)
  logTx(who, call, digest)
}

function call(fn: string, args: (tx: Transaction) => Parameters<Transaction['moveCall']>[0]['arguments']) {
  const tx = new Transaction()
  tx.moveCall({ target: target(fn), typeArguments: [DUSD], arguments: args(tx) })
  return tx
}

async function propose(to: string, amount: string, note: string) {
  const w = need()
  const tx = call('propose', (t) => [
    t.object(w.driverCap),
    t.object(w.vault),
    t.pure.address(to),
    t.pure.u64(toUnits(amount)),
    t.pure.string(note),
    t.object(CLOCK),
  ])
  await exec(AGENT, tx, 'Agent', `brake::propose(${amount} dUSD)`)
}

async function preview(to: string, amount: string) {
  const w = need()
  const tx = call('preview', (t) => [t.object(w.vault), t.pure.address(to), t.pure.u64(toUnits(amount)), t.object(CLOCK)])
  tx.setSender(AGENT.toSuiAddress())
  const res = await client.simulateTransaction({ transaction: tx, include: { commandResults: true } })
  const values = res.commandResults?.[0]?.returnValues
  if (!values) throw new Error('preview failed')
  return { instant: bcs.bool().parse(values[0].bcs), wait: Number(bcs.u64().parse(values[1].bcs)) / 1000 }
}

async function trust(contact: string) {
  const w = need()
  const tx = call('set_trusted', (t) => [t.object(w.ownerCap), t.object(w.vault), t.pure.address(contact), t.pure.bool(true)])
  await execWallet(tx, 'You (wallet)', 'brake::set_trusted()')
}

async function hold(op: Op) {
  const w = need()
  const tx = call('hold', (t) => [t.object(w.watcherCap), t.object(w.vault), t.pure.u64(BigInt(op.id)), t.object(CLOCK)])
  await exec(WATCHER, tx, 'Watcher', 'brake::hold()')
}

/** "Your phone" is the viewer's wallet, which holds the brake key that may cancel. */
async function cancel(op: Op) {
  const w = need()
  const tx = call('cancel_as_brake', (t) => [t.object(w.phoneCap), t.object(w.vault), t.pure.u64(BigInt(op.id))])
  await execWallet(tx, 'Your phone (wallet)', 'brake::cancel_as_brake()')
}

// Open to anyone once the wait is over; the watcher's key pays the gas.
async function execute(op: Op) {
  const w = need()
  const tx = call('execute', (t) => [t.object(w.vault), t.pure.u64(BigInt(op.id)), t.object(CLOCK)])
  await exec(WATCHER, tx, 'Relayer', 'brake::execute()')
}

/** The plain wallet pays at once. Simulated: no transaction is sent. */
async function twinSend(to: string, amount: string) {
  need()
  await new Promise((r) => setTimeout(r, 400))
  plain.balance -= Number(amount)
  if (to === world?.attacker) plain.sentToAttacker += Number(amount)
  txListeners.forEach((fn) =>
    fn({ who: 'Agent (no Brake)', call: `transfer(${amount} dUSD), simulated`, hash: '—', where: 'simulated, not on chain' }),
  )
}

// ---------------------------------------------------------------- reads

async function chainTimeMs() {
  const clock = await client.getObject({ objectId: CLOCK, include: { json: true } })
  return Number((clock.object.json as { timestamp_ms?: string } | null)?.timestamp_ms ?? Date.now())
}

type Ev = { type: string; json: Record<string, unknown> }

/**
 * This vault's events. Looked up by who sent them (this browser's agent and watcher, and the
 * connected wallet), so other people's use of the same package on testnet never mixes in.
 */
async function vaultEvents(w: World): Promise<Ev[]> {
  const senders = [AGENT.toSuiAddress(), WATCHER.toSuiAddress(), w.owner]
  const pages = await Promise.all(
    senders.map((sender) => client.listEvents({ filter: { sender }, order: 'descending', limit: 50 })),
  )
  return pages
    .flatMap((p) => p.events)
    .filter((e) => e.packageId === net.brakePackage && e.module === 'brake' && e.json?.vault === w.vault)
    .map((e) => ({ type: e.eventType.split('::').pop()!.split('<')[0], json: e.json as Record<string, unknown> }))
}

async function loadOps(): Promise<Op[]> {
  if (!world) return []
  const [events, nowMs] = await Promise.all([vaultEvents(world), chainTimeMs()])
  return events
    .filter((e) => e.type === 'Proposed')
    .sort((a, b) => Number(b.json.payment) - Number(a.json.payment))
    .map((p) => {
      const id = String(p.json.payment)
      const mine = events.filter((e) => String(e.json.payment) === id)
      const holds = mine.filter((e) => e.type === 'Held')
      const readyMs = Math.max(Number(p.json.ready_ms), ...holds.map((h) => Number(h.json.until_ms)))
      const state: OpState = mine.some((e) => e.type === 'Sent')
        ? 'sent'
        : mine.some((e) => e.type === 'Canceled')
          ? 'canceled'
          : nowMs >= readyMs + CONFIG.expiryMs
            ? 'expired'
            : nowMs >= readyMs
              ? 'ready'
              : 'waiting'
      return {
        id,
        to: String(p.json.to),
        amount: fromUnits(String(p.json.amount)),
        note: String(p.json.note),
        lane: p.json.instant ? 'instant' : 'queued',
        state,
        // gRPC events carry no timestamp; a queued payment was proposed one queue-length before it was due.
        scheduledAt: (Number(p.json.ready_ms) - (p.json.instant ? 0 : CONFIG.queueMs)) / 1000,
        readyAt: readyMs / 1000,
        heldBy: holds.map((h) => String(h.json.brake)),
        raw: null,
      } satisfies Op
    })
}

async function balances() {
  if (!world) return { account: '0', twin: '0', attacker: '0' }
  const vault = await client.getObject({ objectId: world.vault, include: { json: true } })
  // A Move Balance<T> comes back either as its value or as { value }.
  const raw = (vault.object.json as { balance?: string | { value?: string } } | null)?.balance
  const inVault = typeof raw === 'object' ? (raw?.value ?? '0') : (raw ?? '0')
  return { account: fromUnits(inVault), twin: String(plain.balance), attacker: String(plain.sentToAttacker) }
}

// ---------------------------------------------------------------- setup

/**
 * One wallet approval creates the whole run: mints 20,000 dUSD into a new Brake vault, hands the agent,
 * watcher and phone their keys, trusts Alex, and sends testnet SUI for gas to any demo key running low.
 */
async function setUp() {
  const owner = walletAddress()
  if (!owner) throw new Error('Connect your Sui wallet first')
  const fresh = {
    friend: Ed25519Keypair.generate().toSuiAddress(),
    sam: Ed25519Keypair.generate().toSuiAddress(),
    attacker: Ed25519Keypair.generate().toSuiAddress(),
  }
  const needGas: string[] = []
  for (const k of [AGENT, WATCHER]) {
    const b = BigInt((await client.getBalance({ owner: k.toSuiAddress() })).balance.balance)
    if (b < CONFIG.lowGasMist) needGas.push(k.toSuiAddress())
  }

  const tx = new Transaction()
  const mint = (amount: number) =>
    tx.moveCall({ target: `${net.dusdPackage}::dusd::mint`, arguments: [tx.object(net.dusdFaucet), tx.pure.u64(BigInt(amount) * BigInt(UNIT))] })
  const [vault, ownerCap] = tx.moveCall({
    target: target('new'),
    typeArguments: [DUSD],
    arguments: [
      tx.pure.u64(CONFIG.queueMs),
      tx.pure.u64(CONFIG.holdMs),
      tx.pure.u64(CONFIG.expiryMs),
      tx.pure.u64(BigInt(CONFIG.dailyLimit) * BigInt(UNIT)),
      mint(CONFIG.start),
    ],
  })
  const issue = (fn: string, extra: Parameters<Transaction['moveCall']>[0]['arguments'] = []) =>
    tx.moveCall({ target: target(fn), typeArguments: [DUSD], arguments: [ownerCap, vault, ...(extra ?? [])] })
  tx.transferObjects([issue('issue_driver')], AGENT.toSuiAddress())
  tx.transferObjects([issue('issue_brake', [tx.pure.bool(false)])], WATCHER.toSuiAddress())
  tx.transferObjects([issue('issue_brake', [tx.pure.bool(true)])], owner) // your phone
  tx.moveCall({ target: target('set_trusted'), typeArguments: [DUSD], arguments: [ownerCap, vault, tx.pure.address(fresh.friend), tx.pure.bool(true)] })
  tx.moveCall({ target: target('share'), typeArguments: [DUSD], arguments: [vault] })
  tx.transferObjects([ownerCap], owner)
  if (needGas.length) {
    const gas = tx.splitCoins(tx.gas, needGas.map(() => CONFIG.gasMist))
    needGas.forEach((addr, i) => tx.transferObjects([gas[i]], addr))
  }

  const digest = await walletExecute(tx)
  const done = await confirm(digest, 'Setup')
  logTx('You (wallet)', 'set up the demo (mint, vault, keys)', digest)

  const types = done.objectTypes ?? {}
  const created = (done.effects?.changedObjects ?? []).filter((o) => o.idOperation === 'Created')
  const find = (suffix: string, ownedBy?: string) => {
    const c = created.find(
      (o) =>
        (types[o.objectId] ?? '').endsWith(suffix) &&
        (!ownedBy || (o.outputOwner?.$kind === 'AddressOwner' && o.outputOwner.AddressOwner === ownedBy)),
    )
    if (!c) throw new Error(`Setup didn’t create ${suffix}`)
    return c.objectId
  }
  setWorld({
    owner,
    vault: find(`::brake::Vault<${DUSD}>`),
    ownerCap: find('::brake::OwnerCap', owner),
    phoneCap: find('::brake::BrakeCap', owner),
    driverCap: find('::brake::DriverCap', AGENT.toSuiAddress()),
    watcherCap: find('::brake::BrakeCap', WATCHER.toSuiAddress()),
    ...fresh,
    createdMs: await chainTimeMs(),
  })
}

/** Picks up this wallet's last run if it is still untouched; otherwise the viewer sets up a new one. */
async function prepare() {
  const owner = walletAddress() ?? (await restoreWallet())
  if (!owner) return
  let saved: World | null = null
  try {
    saved = JSON.parse(localStorage.getItem(worldKey(owner)) ?? 'null') as World | null
  } catch {
    saved = null
  }
  if (!saved?.friend) return setWorld(null)
  setWorld(saved)
  const [b, ops] = await Promise.all([balances(), loadOps()])
  const start = String(CONFIG.start)
  if (ops.length > 0 || b.account !== start) setWorld(null)
}

export const sui: Chain = {
  id: 'sui',
  name: 'Sui',
  network: 'Sui testnet',
  explorerName: 'Suiscan',
  symbol: 'dUSD',
  priceId: '',
  usdPrice: 1,
  priceNote: 'dUSD is a test dollar on Sui testnet',
  plainSimulated: true,
  amounts: {
    start: String(CONFIG.start),
    friend: '100',
    theft: '10000',
    dailyLimit: String(CONFIG.dailyLimit),
  },
  people: {
    get friend() {
      return world?.friend ?? ''
    },
    get sam() {
      return world?.sam ?? ''
    },
    get attacker() {
      return world?.attacker ?? ''
    },
  },
  waits: { queue: CONFIG.queueMs / 1000, hold: CONFIG.holdMs / 1000 },
  canSkipTime: false,
  propose,
  preview,
  trust,
  hold,
  cancel,
  execute,
  twinSend,
  skip: async () => {
    throw new Error('Sui testnet can’t skip time')
  },
  loadOps,
  balances,
  chainTime: async () => (await chainTimeMs()) / 1000,
  onTx: (fn) => {
    txListeners.add(fn)
    return () => void txListeners.delete(fn)
  },
  prepare,
  resetDemo: async () => setWorld(null),
  wallet: {
    label: 'Sui wallet',
    setupSteps: [
      `Mints ${CONFIG.start.toLocaleString()} test dollars (dUSD) into a new Brake wallet`,
      'Gives the agent and the watcher their keys, and your wallet the owner and phone keys',
      'Sends a little testnet SUI to the agent and watcher for gas, if they’re low',
    ],
    connect: connectWallet,
    restore: restoreWallet,
    address: walletAddress,
    ready: () => world !== null,
    setUp,
  },
}
