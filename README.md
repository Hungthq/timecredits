# SG TimeBank: TIME credits on chain

A blockchain time bank for Singapore's community care. Volunteers earn TIME credits for verified hours, then redeem them at partners, gift them to family, or donate them to a community pool. Credits cannot be traded.

Built with the same toolchain as the IS634 Web3 Fundamentals labs: **Foundry 1.8.1** (forge, anvil, cast), **Solidity 0.8.20**, the **Scaffold-ETH 2** deploy pattern (Labs 2 and 4), and a **Vite + viem** web app in the style of the Lab 1 playground.

All people, organisations and partners in the demo are hypothetical.

## What is in this repo

```
frontend/                 Web app (Vite + viem): wallet login, tap in/out, sign-offs,
                          time machine, redeem/gift/donate, on-chain ledger, block explorer
scripts/deploy.js         Builds, deploys to Anvil, seeds the demo, writes frontend/contract.json
sgtimebank/
  contracts/SGTimeCredit.sol   The TIME credit contract
  test/SGTimeCredit.t.sol      30 Forge tests (including a fuzz test)
  script/                      Scaffold-ETH style deploy scripts + SeedDemo.s.sol
  demo.sh                      The same flow from the command line with cast
SG_TimeBank_Lab.ipynb     Course-style notebook: test, deploy, run the flow, optional BSC Testnet deploy
```

## Run the web app (same steps as Lab 1)

Requirements: Node.js 20.18+ (24.19.0 recommended), Yarn 1.22.22, Foundry 1.8.1.

```bash
yarn install
yarn chain        # terminal 1: start Anvil on http://127.0.0.1:8545
yarn deploy       # terminal 2: compile, deploy, seed demo data, write frontend/contract.json
yarn start        # terminal 2: open http://localhost:5173
```

If you restart Anvil, run `yarn deploy` again and refresh the page.

### Troubleshooting

- **`yarn chain` fails with "Only one usage of each socket address" (os error 10048):** an Anvil from an earlier lab is still running on port 8545. Find it with `Get-NetTCPConnection -LocalPort 8545 -State Listen | ForEach-Object { Get-Process -Id $_.OwningProcess }`, stop it with `Stop-Process -Name anvil -Force`, then run `yarn chain` again.
- **`yarn start` fails with "Failed to load url /app.js" or "Cannot read properties of undefined (reading 'imports')":** Vite's pre-bundle cache is out of date, often after opening the project through a different path (a junction or symlink). Pull the latest version, then run `yarn start --force` once to rebuild the cache.

### A 3-minute demo script

1. **Log in as Ravi** (licensed physiotherapist). Choose *Clinic X, reception*, tier *Professional*, then **Tap in**.
2. Click **+3 hours** in the time machine, then **Tap out**.
3. **Log in as Coordinator Lim** and sign session 1 as *coordinator*. Status stays *Awaiting sign-off*.
4. **Log in as Mdm Wong** (a senior) and sign as *beneficiary*. Status becomes *Ready*.
5. Click **Finalise**. It is refused: the 14-day dispute window is still open.
6. Click **+14 days**, then **Finalise**. Ravi gets **6.00 TIME** (3 h × 2.0).
7. **Log in as Ravi** and redeem 1 hour at *Clinic X Physio*. 1.00 TIME is burned.
8. Try the safeguards: Aisha choosing *Professional* (no licence), Ravi signing his own hours, or Kumar signing for Aisha (family). Each is refused with the contract's reason.

The **On-chain ledger** lists every contract event, and the **Blockchain explorer** shows each block with the decoded function call.

## Run the tests

```bash
cd sgtimebank
forge install foundry-rs/forge-std --no-git
forge test
```

## Use the notebook

Open `SG_TimeBank_Lab.ipynb` in VS Code and run the cells in order. Step 9 deploys to BSC Testnet (chain ID 97). Use a separate test wallet and put its key in the `SGT_TESTNET_PK` environment variable, never in the notebook.

## Safety

The web app and scripts use Anvil's built-in test accounts, whose private keys are public. Use them only on a local chain. Never enter a real wallet's private key in the web app.
