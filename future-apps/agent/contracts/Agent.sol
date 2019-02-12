/*
 * SPDX-License-Identitifer:    GPL-3.0-or-later
 */

pragma solidity 0.4.24;

import "./SignatureValidator.sol";
import "./standards/IERC165.sol";
import "./standards/ERC1271.sol";

import "@aragon/apps-vault/contracts/Vault.sol";

import "@aragon/os/contracts/common/IForwarder.sol";


contract Agent is IERC165, ERC1271Bytes, IForwarder, IsContract, Vault {
    bytes32 public constant EXECUTE_ROLE = keccak256("EXECUTE_ROLE");
    bytes32 public constant RUN_SCRIPT_ROLE = keccak256("RUN_SCRIPT_ROLE");
    bytes32 public constant ADD_PRESIGNED_HASH_ROLE = keccak256("ADD_PRESIGNED_HASH_ROLE");
    bytes32 public constant DESIGNATE_SIGNER_ROLE = keccak256("DESIGNATE_SIGNER_ROLE");

    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;

    string private constant ERROR_EXECUTE_ETH_NO_DATA = "AGENT_EXEC_ETH_NO_DATA";
    string private constant ERROR_EXECUTE_TARGET_NOT_CONTRACT = "AGENT_EXEC_TARGET_NO_CONTRACT";
    string private constant ERROR_DESIGNATED_TO_SELF = "AGENT_DESIGNATED_TO_SELF";

    uint256 internal constant ISVALIDSIG_MAX_GAS = 250000;
    uint256 internal constant EIP165_MAX_GAS = 30000;

    mapping (bytes32 => bool) public isPresigned;
    address public designatedSigner;

    event Execute(address indexed sender, address indexed target, uint256 ethValue, bytes data);
    event PresignHash(address indexed sender, bytes32 indexed hash);
    event SetDesignatedSigner(address indexed sender, address indexed oldSigner, address indexed newSigner);

    /**
    * @notice Execute '`@radspec(_target, _data)`' on `_target``_ethValue == 0 ? '' : ' (Sending' + @tokenAmount(_ethValue, 0x00) + ')'`
    * @param _target Address where the action is being executed
    * @param _ethValue Amount of ETH from the contract that is sent with the action
    * @param _data Calldata for the action
    * @return Exits call frame forwarding the return data of the executed call (either error or success data)
    */
    function execute(address _target, uint256 _ethValue, bytes _data)
        external // This function MUST always be external as the function performs a low level return, exiting the Agent app execution context
        authP(EXECUTE_ROLE, arr(_target, _ethValue, uint256(getSig(_data)))) // TODO: Test that sig bytes are the least significant bytes
    {
        require(_ethValue == 0 || _data.length > 0, ERROR_EXECUTE_ETH_NO_DATA); // if ETH value is sent, there must be data
        require(isContract(_target), ERROR_EXECUTE_TARGET_NOT_CONTRACT);

        bool result = _target.call.value(_ethValue)(_data);

        if (result) {
            emit Execute(msg.sender, _target, _ethValue, _data);
        }

        assembly {
            let size := returndatasize
            let ptr := mload(0x40)
            returndatacopy(ptr, 0, size)

            // revert instead of invalid() bc if the underlying call failed with invalid() it already wasted gas.
            // if the call returned error data, forward it
            switch result case 0 { revert(ptr, size) }
            default { return(ptr, size) }
        }
    }

    /**
    * @notice Set `_designatedSigner` as the designated signer of the app, which will be able to sign messages on behalf of the app
    * @param _designatedSigner Address that will be able to sign messages on behalf of the app
    */
    function setDesignatedSigner(address _designatedSigner)
        external
        authP(DESIGNATE_SIGNER_ROLE, arr(_designatedSigner))
    {
        // Prevent an infinite loop by setting the app itself as its designated signer.
        // An undetectable loop can be created by setting a different contract as the
        // designated signer which calls back into `isValidSignature`.
        // Given that `isValidSignature` is always called with just 50k gas, the max
        // damage of the loop is wasting 50k gas.
        require(_designatedSigner != address(this), ERROR_DESIGNATED_TO_SELF);

        address oldDesignatedSigner = designatedSigner;
        designatedSigner = _designatedSigner;

        emit SetDesignatedSigner(msg.sender, oldDesignatedSigner, _designatedSigner);
    }

    /**
    * @notice Pre-sign hash `_hash`
    * @param _hash Hash that will be considered signed regardless of the signature checked with 'isValidSignature()'
    */
    function presignHash(bytes32 _hash)
        external
        authP(ADD_PRESIGNED_HASH_ROLE, arr(_hash))
    {
        isPresigned[_hash] = true;

        emit PresignHash(msg.sender, _hash);
    }

    function isForwarder() external pure returns (bool) {
        return true;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == ERC1271_INTERFACE_ID ||
            interfaceId == ERC165_INTERFACE_ID;
    }

    /**
    * @notice Execute the script as the Agent app
    * @dev IForwarder interface conformance. Forwards any token holder action.
    * @param _evmScript Script being executed
    */
    function forward(bytes _evmScript)
        public
        authP(RUN_SCRIPT_ROLE, arr(getScriptACLParam(_evmScript)))
    {
        bytes memory input = ""; // no input
        address[] memory blacklist = new address[](0); // no addr blacklist, can interact with anything
        runScript(_evmScript, input, blacklist);
        // We don't need to emit an event here as EVMScriptRunner will emit ScriptResult if successful
    }

    function isValidSignature(bytes32 hash, bytes signature) public view returns (bytes4) {
        // Short-circuit in case the hash was presigned. Optimization as performing calls
        // and ecrecover is more expensive than an SLOAD.
        if (isPresigned[hash]) {
            return isValidSignatureReturn(true);
        }

        // Checks if designatedSigner is a contract, and if it supports the isValidSignature interface
        if (safeSupportsInterface(IERC165(designatedSigner), ERC1271_INTERFACE_ID)) {
            // designatedSigner.isValidSignature(hash, signature) as a staticall
            ERC1271 signerContract = ERC1271(designatedSigner);
            bytes memory data = abi.encodeWithSelector(signerContract.isValidSignature.selector, hash, signature);
            return isValidSignatureReturn(safeBoolStaticCall(signerContract, data, ISVALIDSIG_MAX_GAS));
        }

        // `safeSupportsInterface` returns false if designatedSigner is a contract but it
        // doesn't support the interface. Here we check the validity of the ECDSA sig
        // which will always fail if designatedSigner is not an EOA

        return isValidSignatureReturn(SignatureValidator.isValidSignature(hash, designatedSigner, signature));
    }

    function canForward(address sender, bytes evmScript) public view returns (bool) {
        uint256[] memory params = new uint256[](1);
        params[0] = getScriptACLParam(evmScript);
        return canPerform(sender, RUN_SCRIPT_ROLE, params);
    }

    function safeSupportsInterface(IERC165 target, bytes4 interfaceId) internal view returns (bool) {
        if (!isContract(target)) {
            return false;
        }

        bytes memory data = abi.encodeWithSelector(target.supportsInterface.selector, interfaceId);
        return safeBoolStaticCall(target, data, EIP165_MAX_GAS);
    }

    function safeBoolStaticCall(address target, bytes data, uint256 maxGas) internal view returns (bool) {
        uint256 gasLeft = gasleft();

        uint256 callGas = gasLeft > maxGas ? maxGas : gasLeft;
        bool ok;
        assembly {
            ok := staticcall(callGas, target, add(data, 0x20), mload(data), 0, 0)
        }

        if (!ok) {
            return false;
        }

        uint256 size;
        assembly { size := returndatasize }
        if (size != 32) {
            return false;
        }

        bool result;
        assembly {
            let ptr := mload(0x40)       // get next free memory ptr
            returndatacopy(ptr, 0, size) // copy return from above `staticcall`
            result := mload(ptr)         // read data at ptr and set it to result
        }

        return result;
    }

    function getScriptACLParam(bytes evmScript) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(evmScript)));
    }

    function getSig(bytes data) internal pure returns (bytes4 sig) {
        assembly { sig := add(data, 0x20) }
    }
}
