import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  http,
  formatEther,
  decodeFunctionData,
  BaseError,
  ContractFunctionRevertedError,
} from 'viem'
import { foundry } from 'viem/chains'
import { privateKeyToAccount } from 'viem/accounts'

const RPC_URL = 'http://127.0.0.1:8545'
const POLL_INTERVAL = 2000
const MAX_BLOCKS_SHOWN = 40
const DISPUTE_WINDOW = 14n * 24n * 3600n

const STATUS = ['None', 'Open', 'Awaiting sign-off', 'Ready', 'Disputed', 'Minted']
const TIERS = ['General', 'Skilled', 'Professional']
const ROLE_BITS = { coordinator: 1, beneficiary: 2, peer: 3 }

// Plain-English explanations for the contract's custom errors.
const ERROR_TEXT = {
  NotAdmin: 'Only the platform operator can do this.',
  NotVerifiedVolunteer: 'This wallet is not a verified volunteer.',
  IdentityAlreadyUsed: 'This ID is already linked to another wallet.',
  UnknownOrg: 'That organisation is not registered.',
  TagNotInOrg: 'That NFC tag does not belong to this organisation.',
  MissingCredential: 'You need a verified certificate or licence for this tier.',
  UnknownTier: 'Unknown skill tier.',
  SessionAlreadyOpen: 'You already have an open session. Tap out first.',
  BadSessionState: 'This session cannot do that in its current state.',
  NotSessionOwner: 'Only the volunteer who tapped in can tap out.',
  SessionTooShort: 'Sessions must be at least 15 minutes. Use the time machine to move the clock forward.',
  SessionTooLong: 'Sessions longer than 8 hours are refused. Split the work into two sessions.',
  SelfSign: 'Volunteers cannot sign their own hours.',
  FamilyCannotSign: 'Family members cannot sign for each other.',
  AlreadySigned: 'You have already signed this session.',
  NotCoordinator: 'Only a coordinator of this organisation can sign as coordinator.',
  UnknownRole: 'Unknown signing role.',
  DisputeWindowClosed: 'The 14-day dispute window has closed.',
  DisputeWindowOpen: 'Credits mint only after the 14-day dispute window. Use the time machine (+14 days).',
  NotAllowedToDispute: 'Only the operator or a coordinator of this organisation can dispute.',
  UnknownPartner: 'Unknown partner.',
  UnknownPool: 'Unknown pool.',
  NotFamily: 'Credits can only be gifted to a registered family member.',
  InvalidAmount: 'Enter an amount greater than zero.',
  InsufficientCredits: 'Not enough credits.',
}

let cfg = null
let publicClient = null
let testClient = null
let walletClient = null
let account = null
let contractReady = false
let highestBlock = -1n
let chainNow = 0n
const nameByAddress = new Map()

const $ = (id) => document.getElementById(id)
const fmtCredits = (v) => (Number(v) / 100).toFixed(2)
const short = (h, a = 6, b = 4) => (h && h.length > a + b + 2 ? `${h.slice(0, a)}…${h.slice(-b)}` : h || '')
const who = (addr) => (addr ? nameByAddress.get(addr.toLowerCase()) || short(addr) : '')
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
const sgt = (ts) => new Date((Number(ts) + 8 * 3600) * 1000).toISOString().replace('T', ' ').slice(0, 16)

function explain(error) {
  if (error instanceof BaseError) {
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError)
    const name = revert?.data?.errorName
    if (name) return `${ERROR_TEXT[name] || 'The contract refused this.'} (${name})`
    return error.shortMessage || error.message
  }
  return error?.message || String(error)
}

function setMsg(statusId, errorId, status = '', err = '') {
  if (statusId) $(statusId).textContent = status
  if (errorId) $(errorId).textContent = err
}

// ---------- reads ----------

const read = (functionName, args = []) =>
  publicClient.readContract({ address: cfg.address, abi: cfg.abi, functionName, args })

async function readSessions() {
  const count = Number(await read('sessionCount'))
  const ids = Array.from({ length: count }, (_, i) => BigInt(i + 1))
  const rows = await Promise.all(ids.map((id) => read('sessions', [id])))
  return rows.map((r, i) => ({
    id: ids[i],
    volunteer: r[0], orgId: r[1], tier: Number(r[2]), tapIn: r[3], tapOut: r[4], readyAt: r[5],
    quarters: Number(r[6]), roleMask: Number(r[7]), credits: r[8], capped: r[9], status: Number(r[10]),
  }))
}

// ---------- writes ----------

async function send(functionName, args, { statusId, errorId, success }) {
  if (!walletClient) {
    setMsg(statusId, errorId, '', 'Log in with a demo wallet first.')
    return false
  }
  setMsg(statusId, errorId, 'Sending transaction…', '')
  try {
    // simulate first, so a refusal is explained before anything is broadcast
    const { request } = await publicClient.simulateContract({
      address: cfg.address, abi: cfg.abi, functionName, args, account,
    })
    const hash = await walletClient.writeContract(request)
    setMsg(statusId, errorId, 'Waiting for confirmation…', '')
    const receipt = await publicClient.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success') throw new Error('Transaction reverted')
    setMsg(statusId, errorId, `${success} Block #${receipt.blockNumber}.`, '')
    await refresh()
    return true
  } catch (error) {
    setMsg(statusId, errorId, '', explain(error))
    return false
  }
}

// ---------- chain + contract status ----------

async function connect() {
  publicClient = createPublicClient({ chain: foundry, transport: http(RPC_URL) })
  testClient = createTestClient({ chain: foundry, mode: 'anvil', transport: http(RPC_URL) })
  try {
    $('chain-id').textContent = await publicClient.getChainId()
    setRpc(true)
    return true
  } catch {
    setRpc(false)
    return false
  }
}

function setRpc(ok) {
  $('rpc-status').textContent = ok ? 'Connected' : 'Disconnected'
  $('rpc-status').className = `pill${ok ? '' : ' bad'}`
  $('explorer-live').classList.toggle('offline', !ok)
}

async function loadConfig() {
  try {
    const res = await fetch(`./contract.json?t=${Date.now()}`, { cache: 'no-store' })
    if (!res.ok) throw new Error('missing')
    const c = await res.json()
    const code = await publicClient.getCode({ address: c.address })
    if (!code || code === '0x') {
      $('contract-status').textContent = 'Stale: run yarn deploy'
      $('contract-status').className = 'pill bad'
      return false
    }
    cfg = c
    contractReady = true
    nameByAddress.clear()
    for (const p of cfg.people) nameByAddress.set(p.address.toLowerCase(), p.name)
    nameByAddress.set(cfg.address.toLowerCase(), 'SGTimeCredit contract')
    $('contract-status').textContent = short(cfg.address)
    $('contract-status').title = cfg.address
    $('contract-status').className = 'pill'
    fillStaticSelects()
    return true
  } catch {
    $('contract-status').textContent = 'Not deployed: run yarn deploy'
    $('contract-status').className = 'pill bad'
    return false
  }
}

function fillStaticSelects() {
  $('persona').innerHTML = '<option value="">Choose…</option>' +
    cfg.people.map((p, i) => `<option value="${i}">${esc(p.name)} (${esc(p.role)})</option>`).join('')
  $('tap-tag').innerHTML = cfg.orgs.flatMap((o) =>
    o.tags.map((t) => `<option value="${o.id}|${t.hash}">${esc(t.label)}</option>`)).join('')
  $('redeem-partner').innerHTML = cfg.partners.map((p) =>
    `<option value="${p.id}">${esc(p.name)}${p.loyaltyOn ? ' (loyalty rate)' : ''}</option>`).join('')
  $('donate-pool').innerHTML = cfg.pools.map((p) => `<option value="${p.id}">${esc(p.name)}</option>`).join('')
}

// ---------- wallet ----------

function choosePersona() {
  const i = $('persona').value
  if (i === '') return
  const p = cfg.people[Number(i)]
  $('wallet-address').value = p.address
  $('private-key').value = p.privateKey
}

const MESSAGE_IDS = ['tap-status', 'tap-error', 'session-status', 'session-error', 'spend-status', 'spend-error', 'login-error']
const clearMessages = () => MESSAGE_IDS.forEach((id) => { $(id).textContent = '' })

function login() {
  clearMessages()
  const addr = $('wallet-address').value.trim()
  let pk = $('private-key').value.trim()
  $('login-error').textContent = ''
  if (!addr || !pk) return void ($('login-error').textContent = 'Enter both the address and the private key, or choose a demo person.')
  if (!pk.startsWith('0x')) pk = `0x${pk}`
  let acct
  try { acct = privateKeyToAccount(pk) } catch { return void ($('login-error').textContent = 'Invalid private key format.') }
  if (acct.address.toLowerCase() !== addr.toLowerCase()) return void ($('login-error').textContent = 'This private key does not match the wallet address.')
  account = acct
  walletClient = createWalletClient({ account, chain: foundry, transport: http(RPC_URL) })
  $('login-form').classList.add('hidden')
  $('wallet-info').classList.remove('hidden')
  $('connected-name').textContent = who(account.address)
  $('connected-address').textContent = account.address
  void refresh()
}

function logout() {
  clearMessages()
  account = null
  walletClient = null
  $('login-form').classList.remove('hidden')
  $('wallet-info').classList.add('hidden')
  $('private-key').value = ''
  $('wallet-address').value = ''
  $('persona').value = ''
  void refresh()
}

async function renderAccount() {
  if (!account) {
    $('time-balance').textContent = '--'
    $('eth-balance').textContent = '--'
    $('hours-org-1').textContent = '--'
    $('hours-org-2').textContent = '--'
    $('role-chips').innerHTML = ''
    $('gift-to').innerHTML = '<option value="">Log in first</option>'
    $('redeem-quote').textContent = 'Log in to see your rate.'
    return
  }
  const a = account.address
  const [bal, eth, verified, cert, lic, q1, q2, c1, c2] = await Promise.all([
    read('balanceOf', [a]), publicClient.getBalance({ address: a }),
    read('isVerifiedVolunteer', [a]), read('hasSkillCert', [a]), read('hasLicence', [a]),
    read('verifiedQuartersAt', [a, 1n]), read('verifiedQuartersAt', [a, 2n]),
    read('isCoordinator', [1n, a]), read('isCoordinator', [2n, a]),
  ])
  $('time-balance').textContent = fmtCredits(bal)
  $('eth-balance').textContent = `${Number(formatEther(eth)).toFixed(4)} ETH (test)`
  $('hours-org-1').textContent = `${Number(q1) / 4} h`
  $('hours-org-2').textContent = `${Number(q2) / 4} h`

  const chips = []
  if (a.toLowerCase() === cfg.deployer.toLowerCase()) chips.push('<span class="pill warn">Operator</span>')
  if (verified) chips.push('<span class="pill">Verified volunteer</span>')
  if (cert) chips.push('<span class="pill">Skill certificate</span>')
  if (lic) chips.push('<span class="pill">Licence</span>')
  if (c1) chips.push('<span class="pill">Coordinator: Community Centre North</span>')
  if (c2) chips.push('<span class="pill">Coordinator: Clinic X</span>')
  if (!chips.length) chips.push('<span class="pill muted">Not registered (can sign as beneficiary)</span>')
  $('role-chips').innerHTML = chips.join('')

  const family = (await Promise.all(cfg.people.map(async (p) =>
    (p.address.toLowerCase() !== a.toLowerCase() && await read('isFamily', [a, p.address])) ? p : null))).filter(Boolean)
  $('gift-to').innerHTML = family.length
    ? family.map((p) => `<option value="${p.address}">${esc(p.name)}</option>`).join('')
    : cfg.people.filter((p) => p.address.toLowerCase() !== a.toLowerCase())
      .map((p) => `<option value="${p.address}">${esc(p.name)} (not family)</option>`).join('')
  await renderQuote()
}

async function renderQuote() {
  if (!account) return
  const partnerId = BigInt($('redeem-partner').value || 1)
  const hours = Number($('redeem-hours').value) || 0
  const [rate, loyal] = await read('redeemRate', [account.address, partnerId])
  const burn = Math.round(hours * 4) * 25 * Number(rate) / 100
  $('redeem-quote').innerHTML = `Rate <strong>${fmtCredits(rate)}</strong> per hour ${loyal ? '(loyalty rate: 20+ verified hours here)' : '(standard rate)'}. Cost: <strong>${fmtCredits(burn)}</strong> TIME.`
}

// ---------- sessions ----------

function signatureChips(mask) {
  return Object.entries(ROLE_BITS)
    .map(([role, bit]) => `<span class="sig${mask & (1 << bit) ? ' on' : ''}">${role}${mask & (1 << bit) ? ' ✓' : ''}</span>`)
    .join('')
}

function sessionActions(s) {
  const id = s.id.toString()
  if (s.status === 2 || s.status === 3) {
    const sign = `<select data-role-for="${id}" aria-label="Sign session ${id} as">
        <option value="1">coordinator</option><option value="3">peer</option><option value="2">beneficiary</option>
      </select><button type="button" class="btn-small" data-sign="${id}">Sign</button>`
    if (s.status === 2) return sign
    const ends = s.readyAt + DISPUTE_WINDOW
    const open = chainNow < ends
    return `${open ? `<button type="button" class="btn-small btn-secondary" data-dispute="${id}">Dispute</button>` : ''}
      <button type="button" class="btn-small" data-finalise="${id}">Finalise</button>
      <span class="subtle">${open ? `window ends ${sgt(ends)}` : 'window closed'}</span>`
  }
  return ''
}

async function renderSessions() {
  const sessions = await readSessions()
  const orgName = (id) => cfg.orgs.find((o) => BigInt(o.id) === id)?.name || `Org ${id}`
  const statusPill = (st) => {
    const cls = st === 5 ? '' : st === 4 ? ' bad' : ' warn'
    return `<span class="pill${cls}">${STATUS[st]}</span>`
  }
  $('sessions-body').innerHTML = sessions.length
    ? sessions.slice().reverse().map((s) => `
      <tr>
        <td class="num">${s.id}</td>
        <td>${esc(who(s.volunteer))}</td>
        <td>${esc(orgName(s.orgId))}</td>
        <td class="num">${s.status === 1 ? `open since ${sgt(s.tapIn)}` : (s.quarters / 4).toFixed(2)}</td>
        <td>${TIERS[s.tier]}</td>
        <td><div class="sigs">${signatureChips(s.roleMask)}</div></td>
        <td>${statusPill(s.status)}</td>
        <td class="num">${s.status === 5 ? `${fmtCredits(s.credits)}${s.capped ? ' (capped)' : ''}` : '-'}</td>
        <td><div class="actions">${sessionActions(s)}</div></td>
      </tr>`).join('')
    : '<tr><td colspan="9" class="subtle">No sessions yet. Log in as a volunteer and tap in.</td></tr>'

  const mine = account && sessions.find((s) => s.status === 1 && s.volunteer.toLowerCase() === account.address.toLowerCase())
  $('tap-in-btn').disabled = !account || Boolean(mine)
  $('tap-out-btn').disabled = !mine
  $('tap-out-btn').dataset.session = mine ? mine.id.toString() : ''
  $('tap-out-btn').dataset.tag = mine ? cfg.orgs.find((o) => BigInt(o.id) === mine.orgId).tags[0].hash : ''
}

// ---------- ledger ----------

function describeEvent(e) {
  const a = e.args
  switch (e.eventName) {
    case 'CheckIn': return `${who(a.volunteer)} tapped in (session ${a.sessionId}, ${TIERS[a.tier]})`
    case 'CheckOut': return `Session ${a.sessionId} tapped out: ${(Number(a.quarters) / 4).toFixed(2)} h`
    case 'Signed': return `${who(a.signer)} signed session ${a.sessionId} as ${['', 'coordinator', 'beneficiary', 'peer'][a.role]}`
    case 'Ready': return `Session ${a.sessionId} ready; dispute window opens`
    case 'Disputed': return `Session ${a.sessionId} disputed by ${who(a.by)}: ${a.reason}`
    case 'Minted': return `${fmtCredits(a.credits)} TIME minted to ${who(a.volunteer)}${a.capped ? ' (capped)' : ''}`
    case 'Redeemed': return `${who(a.volunteer)} burned ${fmtCredits(a.burn)} TIME for ${(Number(a.serviceQuarters) / 4).toFixed(2)} h${a.loyal ? ' (loyalty rate)' : ''}`
    case 'Gifted': return `${who(a.from)} gifted ${fmtCredits(a.amount)} TIME to ${who(a.to)}`
    case 'Donated': return `${who(a.from)} donated ${fmtCredits(a.amount)} TIME to pool ${a.poolId}`
    case 'VolunteerVerified': return `${who(a.volunteer)} verified${a.licence ? ' (licence)' : ''}${a.skillCert ? ' (skill certificate)' : ''}`
    case 'CoordinatorSet': return `${who(a.coordinator)} set as coordinator of org ${a.orgId}`
    case 'FamilyLinked': return `${who(a.a)} and ${who(a.b)} linked as family`
    case 'OrgRegistered': return `Organisation ${a.orgId} registered: ${a.name}`
    case 'TagRegistered': return `NFC tag registered for org ${a.orgId}`
    case 'PartnerRegistered': return `Partner registered: ${a.name}${a.loyaltyOn ? ' (loyalty on)' : ''}`
    case 'PoolRegistered': return `Pool registered: ${a.name}`
    default: return e.eventName
  }
}

async function renderLedger() {
  const [minted, burned, pool] = await Promise.all([read('totalMinted'), read('totalBurned'), read('poolBalance', [1n])])
  $('supply').innerHTML = `Minted <strong>${fmtCredits(minted)}</strong> · Burned <strong>${fmtCredits(burned)}</strong> · Circulating <strong>${fmtCredits(minted - burned)}</strong>`
  $('pool-balance').textContent = `${fmtCredits(pool)} TIME`
  const events = await publicClient.getContractEvents({ address: cfg.address, abi: cfg.abi, fromBlock: BigInt(cfg.deploymentBlock) })
  $('event-list').innerHTML = events.length
    ? events.slice().reverse().map((e) => `
      <li><span class="event-name">${esc(e.eventName)}</span><span>${esc(describeEvent(e))}</span><span class="event-block">#${e.blockNumber}</span></li>`).join('')
    : '<li class="subtle">No events yet.</li>'
}

// ---------- explorer ----------

function describeTx(tx) {
  if (!tx.to) return tx.hash.toLowerCase() === cfg?.deploymentTransaction?.toLowerCase() ? 'Deploy SGTimeCredit' : 'Contract creation'
  if (cfg && tx.to.toLowerCase() === cfg.address.toLowerCase() && tx.input && tx.input !== '0x') {
    try { return decodeFunctionData({ abi: cfg.abi, data: tx.input }).functionName + '()' } catch { return 'Contract call' }
  }
  return `${Number(formatEther(tx.value)).toFixed(4)} ETH transfer`
}

function renderBlock(b, isNew) {
  const txs = b.transactions.map((tx) => `
    <div class="tx"><strong>${esc(describeTx(tx))}</strong><br><span class="who">from ${esc(who(tx.from))}</span></div>`).join('')
  return `<article class="block${isNew ? ' is-new' : ''}" role="listitem" aria-label="Block ${b.number}">
    <div class="block-head"><span class="block-num">#${b.number}</span><span class="subtle">${b.transactions.length} tx</span></div>
    <div class="block-hash mono" title="${b.hash}">${short(b.hash, 8, 6)} ← ${b.number === 0n ? 'genesis' : short(b.parentHash, 6, 4)}</div>
    <div class="subtle">${sgt(b.timestamp)} SGT</div>
    ${txs || '<div class="tx subtle">No transactions</div>'}
  </article>`
}

async function updateExplorer(initial = false) {
  const latest = await publicClient.getBlockNumber({ cacheTime: 0 })
  if (!initial && latest <= highestBlock) return false
  const from = initial ? (latest > BigInt(MAX_BLOCKS_SHOWN) ? latest - BigInt(MAX_BLOCKS_SHOWN) + 1n : 0n) : highestBlock + 1n
  const blocks = []
  for (let n = from; n <= latest; n++) blocks.push(await publicClient.getBlock({ blockNumber: n, includeTransactions: true }))
  const html = blocks.map((b, i) => `${initial && i === 0 ? '' : '<div class="link" aria-hidden="true"></div>'}${renderBlock(b, !initial)}`).join('')
  const box = $('blocks')
  if (initial) box.innerHTML = html
  else box.insertAdjacentHTML('beforeend', html)
  const all = box.querySelectorAll('.block')
  for (let i = 0; i < all.length - MAX_BLOCKS_SHOWN; i++) { all[i].nextElementSibling?.remove(); all[i].remove() }
  highestBlock = latest
  const last = blocks[blocks.length - 1]
  chainNow = last.timestamp
  $('latest-block').textContent = `#${latest}`
  $('chain-time').textContent = sgt(chainNow)
  requestAnimationFrame(() => { box.scrollLeft = box.scrollWidth })
  return true
}

// ---------- refresh loop ----------

let refreshing = false
async function refresh() {
  if (refreshing || !contractReady) return
  refreshing = true
  try {
    await updateExplorer(highestBlock < 0n)
    await Promise.all([renderAccount(), renderSessions(), renderLedger()])
    setRpc(true)
    $('global-error').textContent = ''
  } catch (error) {
    setRpc(false)
    $('global-error').textContent = `Could not read the chain: ${explain(error)}. If you restarted Anvil, run yarn deploy again and refresh.`
  } finally {
    refreshing = false
  }
}

async function poll() {
  if (!contractReady) return
  try {
    const latest = await publicClient.getBlockNumber({ cacheTime: 0 })
    setRpc(true)
    if (latest !== highestBlock) await refresh()
  } catch {
    setRpc(false)
  }
}

// ---------- events ----------

function wire() {
  $('persona').addEventListener('change', choosePersona)
  $('login-btn').addEventListener('click', login)
  $('logout-btn').addEventListener('click', logout)
  $('private-key').addEventListener('keydown', (e) => { if (e.key === 'Enter') login() })

  document.querySelectorAll('[data-warp]').forEach((btn) => btn.addEventListener('click', async () => {
    try {
      await testClient.increaseTime({ seconds: Number(btn.dataset.warp) })
      await testClient.mine({ blocks: 1 })
      await refresh()
    } catch (error) {
      $('global-error').textContent = `Time machine failed: ${explain(error)}`
    }
  }))

  $('tap-in-btn').addEventListener('click', () => {
    const [orgId, tagHash] = $('tap-tag').value.split('|')
    send('checkIn', [BigInt(orgId), tagHash, Number($('tap-tier').value)],
      { statusId: 'tap-status', errorId: 'tap-error', success: 'Tapped in. Use the time machine, then tap out.' })
  })
  $('tap-out-btn').addEventListener('click', () => {
    const { session, tag } = $('tap-out-btn').dataset
    send('checkOut', [BigInt(session), tag],
      { statusId: 'tap-status', errorId: 'tap-error', success: 'Tapped out. Now the coordinator and a peer or beneficiary sign.' })
  })

  $('sessions-body').addEventListener('click', (e) => {
    const t = e.target.closest('button')
    if (!t) return
    const opts = { statusId: 'session-status', errorId: 'session-error' }
    if (t.dataset.sign) {
      const role = Number(document.querySelector(`[data-role-for="${t.dataset.sign}"]`).value)
      send('sign', [BigInt(t.dataset.sign), role], { ...opts, success: `Signed session ${t.dataset.sign}.` })
    } else if (t.dataset.dispute) {
      send('dispute', [BigInt(t.dataset.dispute), 'Disputed from the DApp'], { ...opts, success: `Session ${t.dataset.dispute} disputed.` })
    } else if (t.dataset.finalise) {
      send('finalise', [BigInt(t.dataset.finalise)], { ...opts, success: `Session ${t.dataset.finalise} finalised and credits minted.` })
    }
  })

  $('redeem-partner').addEventListener('change', () => void renderQuote())
  $('redeem-hours').addEventListener('input', () => void renderQuote())
  $('redeem-btn').addEventListener('click', () => {
    const quarters = BigInt(Math.round(Number($('redeem-hours').value) * 4))
    send('redeem', [BigInt($('redeem-partner').value), quarters],
      { statusId: 'spend-status', errorId: 'spend-error', success: 'Redeemed. Credits burned.' })
  })
  $('gift-btn').addEventListener('click', () => {
    const amount = BigInt(Math.round(Number($('gift-amount').value) * 100))
    send('gift', [$('gift-to').value, amount], { statusId: 'spend-status', errorId: 'spend-error', success: 'Gift sent.' })
  })
  $('donate-btn').addEventListener('click', () => {
    const amount = BigInt(Math.round(Number($('donate-amount').value) * 100))
    send('donate', [BigInt($('donate-pool').value), amount], { statusId: 'spend-status', errorId: 'spend-error', success: 'Donated.' })
  })
}

async function init() {
  wire()
  $('tap-in-btn').disabled = true
  $('tap-out-btn').disabled = true
  if (!(await connect())) {
    $('global-error').textContent = 'Anvil is not reachable. Run yarn chain, then yarn deploy, then refresh this page.'
    $('blocks').innerHTML = '<div class="subtle">Waiting for Anvil.</div>'
    return
  }
  if (await loadConfig()) await refresh()
  setInterval(poll, POLL_INTERVAL)
}

init()
