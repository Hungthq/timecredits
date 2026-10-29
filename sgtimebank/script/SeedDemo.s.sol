//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Script, console } from "forge-std/Script.sol";
import "../contracts/SGTimeCredit.sol";

/// @notice Registers the hypothetical demo organisations, venue tags, partners and pool.
/// Usage: SGT_ADDRESS=0x... forge script script/SeedDemo.s.sol --rpc-url <rpc> --broadcast --private-key <admin key>
contract SeedDemo is Script {
    function run() external {
        SGTimeCredit tb = SGTimeCredit(vm.envAddress("SGT_ADDRESS"));
        vm.startBroadcast();
        uint256 cc = tb.registerOrg("Community Centre North (hypothetical)");
        uint256 clinic = tb.registerOrg("Clinic X (hypothetical)");
        tb.registerTag(cc, keccak256("tag-cc-1"));
        tb.registerTag(clinic, keccak256("tag-clinic"));
        tb.registerPartner(clinic, true, "Clinic X Physio");
        tb.registerPartner(cc, false, "Hillview Grocer");
        tb.registerPool("Elder Care Pool");
        vm.stopBroadcast();
        console.log("Seeded: orgs", tb.orgCount(), "partners", tb.partnerCount());
    }
}
