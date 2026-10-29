# SG TimeBank - on-chain prototype

Built with the same toolchain as the course labs: Foundry 1.8.1 (forge, anvil, cast),
Solidity 0.8.20, and the Scaffold-ETH 2 deploy pattern from Lab 2 / Lab 4.

## Run it
1. Open `SG_TimeBank_Lab.ipynb` in VS Code (folder `sgtimebank/` must sit next to it).
2. Run the cells in order. The notebook installs forge-std, runs the 30 tests,
   starts Anvil, deploys, seeds demo data and runs the full volunteer flow with cast.
3. Optional: Step 9 deploys to BSC Testnet (chain ID 97). Use a separate test wallet;
   put its key in the SGT_TESTNET_PK environment variable, never in the notebook.

## Command line (macOS/Linux/WSL)
    cd sgtimebank
    forge install foundry-rs/forge-std --no-git
    forge test
    anvil                                   # in another terminal
    forge script script/Deploy.s.sol --rpc-url localhost --broadcast --private-key <anvil key 0>
    SGT_ADDRESS=<address> forge script script/SeedDemo.s.sol --rpc-url localhost --broadcast --private-key <anvil key 0>
    SGT_ADDRESS=<address> ./demo.sh

## Use inside your Lab 2 Scaffold-ETH project
Copy `contracts/SGTimeCredit.sol`, `test/SGTimeCredit.t.sol`, `script/DeploySGTimeCredit.s.sol`
and `script/SeedDemo.s.sol` into `packages/foundry/`, then add to `script/Deploy.s.sol`:

    DeploySGTimeCredit deploySGTimeCredit = new DeploySGTimeCredit();
    deploySGTimeCredit.run();

`yarn deploy` then generates the ABI so the Scaffold-ETH Debug Contracts page can call it.

All organisations, partners and people in the demo are hypothetical.
