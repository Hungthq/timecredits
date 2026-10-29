// Deploys SGTimeCredit to the local Anvil chain, registers the demo (hypothetical)
// organisations, people and partners, and writes frontend/contract.json.
// Same flow as Lab 1: `yarn chain` in one terminal, then `yarn deploy`, then `yarn start`.
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPublicClient, createWalletClient, http, keccak256, toHex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { foundry } from 'viem/chains'

const RPC_URL = 'http://127.0.0.1:8545'
const LOCAL_CHAIN_ID = 31337

// Anvil's default test accounts. These keys are public: never use them on a real network.
const ANVIL_KEYS = [
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
  '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
  '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
  '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6',
  '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a',
  '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba',
  '0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e',
  '0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356',
]

// Demo cast. All people and organisations are hypothetical.
const PEOPLE = [
  { key: 0, name: 'Operator', role: 'Platform operator (admin)' },
  { key: 1, name: 'Aisha', role: 'Volunteer', id: 'S1111111A', skill: false, licence: false },
  { key: 2, name: 'Ravi', role: 'Volunteer, licensed physiotherapist', id: 'S2222222B', skill: false, licence: true },
  { key: 3, name: 'Mei', role: 'Volunteer, certified digital-literacy trainer', id: 'S3333333C', skill: true, licence: false },
  { key: 4, name: 'Kumar', role: "Volunteer, Aisha's family member", id: 'S4444444D', skill: false, licence: false },
  { key: 5, name: 'Coordinator Tan', role: 'Coordinator, Community Centre North', coordinatorOf: 1 },
  { key: 6, name: 'Coordinator Lim', role: 'Coordinator, Clinic X', coordinatorOf: 2 },
  { key: 7, name: 'Mdm Wong', role: 'Beneficiary (senior)' },
]

const ORGS = [
  { name: 'Community Centre North', tags: [{ id: 'tag-cc-1', label: 'Community Centre North, front desk' }] },
  { name: 'Clinic X', tags: [{ id: 'tag-clinic', label: 'Clinic X, reception' }] },
]
const PARTNERS = [
  { orgId: 2, loyaltyOn: true, name: 'Clinic X Physio' },
  { orgId: 1, loyaltyOn: false, name: 'Hillview Grocer' },
]
const POOLS = ['Elder Care Pool']

const projectDirectory = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const artifactPath = resolve(projectDirectory, 'sgtimebank', 'out', 'SGTimeCredit.sol', 'SGTimeCredit.json')
const frontendConfigPath = resolve(projectDirectory, 'frontend', 'contract.json')

const tagHash = (id) => keccak256(toHex(id))
const idHash = (id) => keccak256(toHex(id))

async function main() {
  if (process.argv.length > 2) throw new Error('Run this with: yarn deploy (no extra arguments).')

  console.log('Deploying SG TimeBank to the local Anvil chain...')
  console.log('WARNING: This uses publicly known Anvil test keys. Never use them on a real network.')

  const artifact = JSON.parse(await readFile(artifactPath, 'utf8'))
  const object = artifact?.bytecode?.object
  if (!object || object === '0x') throw new Error(`Compiled bytecode not found in ${artifactPath}`)
  const bytecode = object.startsWith('0x') ? object : `0x${object}`

  const transport = http(RPC_URL)
  const publicClient = createPublicClient({ chain: foundry, transport })
  const chainId = await publicClient.getChainId()
  if (chainId !== LOCAL_CHAIN_ID) throw new Error(`Expected chain ID ${LOCAL_CHAIN_ID}, received ${chainId}.`)

  const accounts = ANVIL_KEYS.map((k) => privateKeyToAccount(k))
  const admin = createWalletClient({ account: accounts[0], chain: foundry, transport })

  const hash = await admin.deployContract({ abi: artifact.abi, bytecode, args: [accounts[0].address] })
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  const address = receipt.contractAddress
  if (!address) throw new Error('Deployment receipt did not contain a contract address.')
  console.log(`Contract: ${address}`)

  const write = async (functionName, args) => {
    const tx = await admin.writeContract({ address, abi: artifact.abi, functionName, args })
    const r = await publicClient.waitForTransactionReceipt({ hash: tx })
    if (r.status !== 'success') throw new Error(`${functionName} reverted`)
  }

  for (const org of ORGS) {
    await write('registerOrg', [org.name])
  }
  for (const [i, org] of ORGS.entries()) {
    for (const tag of org.tags) await write('registerTag', [BigInt(i + 1), tagHash(tag.id)])
  }
  for (const p of PARTNERS) await write('registerPartner', [BigInt(p.orgId), p.loyaltyOn, p.name])
  for (const name of POOLS) await write('registerPool', [name])
  for (const person of PEOPLE) {
    const who = accounts[person.key].address
    if (person.id) await write('verifyVolunteer', [who, idHash(person.id), person.skill, person.licence])
    if (person.coordinatorOf) await write('setCoordinator', [BigInt(person.coordinatorOf), who, true])
  }
  await write('linkFamily', [accounts[1].address, accounts[4].address])
  console.log(`Registered ${ORGS.length} organisations, ${PARTNERS.length} partners, ${POOLS.length} pool, ${PEOPLE.length} demo people.`)

  const frontendConfig = {
    chainId,
    address,
    deployer: accounts[0].address,
    deploymentTransaction: hash,
    deploymentBlock: receipt.blockNumber.toString(),
    people: PEOPLE.map((p) => ({
      name: p.name,
      role: p.role,
      address: accounts[p.key].address,
      privateKey: ANVIL_KEYS[p.key], // public Anvil test key, local demo only
    })),
    orgs: ORGS.map((o, i) => ({ id: i + 1, name: o.name, tags: o.tags.map((t) => ({ ...t, hash: tagHash(t.id) })) })),
    partners: PARTNERS.map((p, i) => ({ id: i + 1, ...p })),
    pools: POOLS.map((name, i) => ({ id: i + 1, name })),
    abi: artifact.abi,
  }
  await mkdir(dirname(frontendConfigPath), { recursive: true })
  await writeFile(frontendConfigPath, `${JSON.stringify(frontendConfig, null, 2)}\n`, 'utf8')

  console.log('Deployment successful. frontend/contract.json is ready. Open or refresh the webpage.')
}

main().catch((error) => {
  console.error(`Deployment failed: ${error.shortMessage || error.message}`)
  process.exitCode = 1
})
