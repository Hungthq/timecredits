//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../contracts/SGTimeCredit.sol";
import "./DeployHelpers.s.sol";

/// @notice Deploys SGTimeCredit with the deployer as admin.
/// @dev Same pattern as DeployCrowdFund.s.sol in Lab 2 / Lab 4 (deploy only).
///      Demo data is added afterwards by SeedDemo.s.sol.
contract DeploySGTimeCredit is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        SGTimeCredit tb = new SGTimeCredit(deployer);
        console.logString(string.concat("SGTimeCredit deployed at: ", vm.toString(address(tb))));
        deployments.push(Deployment("SGTimeCredit", address(tb)));
    }
}
