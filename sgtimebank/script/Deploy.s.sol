//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { DeploySGTimeCredit } from "./DeploySGTimeCredit.s.sol";

/// @notice Main deployment script (yarn deploy / forge script script/Deploy.s.sol).
contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        DeploySGTimeCredit deploySGTimeCredit = new DeploySGTimeCredit();
        deploySGTimeCredit.run();
    }
}
