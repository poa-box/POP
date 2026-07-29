// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {SwitchableBeacon} from "../SwitchableBeacon.sol";
import {IPoaManager} from "./ModuleDeploymentLib.sol";

/*────────────────────────────  Errors  ───────────────────────────────*/
error UnsupportedType();

/**
 * @title BeaconDeploymentLib
 * @notice Library for creating SwitchableBeacon instances
 * @dev Extracts common beacon creation logic used across factories
 */
library BeaconDeploymentLib {
    /**
     * @notice Creates a SwitchableBeacon for a module type
     * @param typeId Module type identifier from ModuleTypes
     * @param poaManager Address of the PoaManager contract
     * @param moduleOwner Address that will own the beacon
     * @param autoUpgrade Whether the beacon should auto-upgrade with POA beacon
     * @param customImpl Optional custom implementation (address(0) for default)
     * @return beacon Address of the created SwitchableBeacon
     */
    function createBeacon(bytes32 typeId, address poaManager, address moduleOwner, bool autoUpgrade, address customImpl)
        internal
        returns (address beacon)
    {
        IPoaManager poa = IPoaManager(poaManager);

        address poaBeacon = poa.getBeaconById(typeId);
        if (poaBeacon == address(0)) revert UnsupportedType();

        address initImpl = address(0);
        SwitchableBeacon.Mode beaconMode = SwitchableBeacon.Mode.Mirror;

        if (!autoUpgrade) {
            // For static mode, get the current implementation
            initImpl = (customImpl == address(0)) ? poa.getCurrentImplementationById(typeId) : customImpl;
            if (initImpl == address(0)) revert UnsupportedType();
            beaconMode = SwitchableBeacon.Mode.Static;
        }

        // Create SwitchableBeacon with appropriate configuration
        beacon = address(new SwitchableBeacon(moduleOwner, poaBeacon, initImpl, beaconMode));
    }

    /**
     * @notice Returns true if PoaManager has a beacon registered for `typeId`.
     * @dev Uses the public `beacons` mapping getter, which returns address(0) for an
     *      unregistered type — unlike `getBeaconById`, it does NOT revert. Callers use this
     *      to gate *optional* modules: if the protocol-level beacon was never registered on
     *      this chain, the module is treated as unavailable and skipped, rather than reverting
     *      the entire org deployment with `TypeUnknown`.
     * @param typeId Module type identifier from ModuleTypes
     * @param poaManager Address of the PoaManager contract
     */
    function beaconRegistered(bytes32 typeId, address poaManager) internal view returns (bool) {
        return IPoaManager(poaManager).beacons(typeId) != address(0);
    }
}
