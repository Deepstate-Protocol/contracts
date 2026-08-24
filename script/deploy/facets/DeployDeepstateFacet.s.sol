// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {DeepstateFacet} from "lifi/Facets/DeepstateFacet.sol";
import {IDeepstateV1} from "lifi/Interfaces/IDeepstateV1.sol";
import {DeployScriptBase} from "./utils/DeployScriptBase.sol";
import {stdJson} from "forge-std/Script.sol";

contract DeployScript is DeployScriptBase {
    using stdJson for string;

    constructor() DeployScriptBase("DeepstateFacet") {}

    function run() public returns (DeepstateFacet deployed, bytes memory constructorArgs) {
        constructorArgs = getConstructorArgs();
        deployed = DeepstateFacet(deploy(type(DeepstateFacet).creationCode));
    }

    function getConstructorArgs() internal override returns (bytes memory) {
        string memory path = string.concat(root, "/config/deepstate.json");
        address deepstate = _getConfigContractAddress(path, string.concat(".engines.", network));

        return abi.encode(IDeepstateV1(deepstate));
    }
}
