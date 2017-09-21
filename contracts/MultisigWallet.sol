pragma solidity ^0.4.13;

/**
 * Basic multi-signer wallet designed for use in a co-signing environment where 2 signatures are required to move funds.
 * Typically used in a 2-of-3 signing configuration. Uses ecrecover to allow for 2 signatures in a single transaction.
 * https://github.com/BitGo/eth-multisig-v2/blob/master/contracts/WalletSimple.sol
 */
contract MultisigWallet {
    // Events
    event Deposited(address from, uint value, bytes data);
    event SafeModeActivated(address msgSender);

    event Transacted(
        address msgSender, // Address of the sender of the message initiating the transaction
        address otherSigner, // Address of the signer (second signature) used to initiate the transaction
        bytes32 operation, // Operation hash (sha3 of toAddress, value, data, expireTime, sequenceId)
        address toAddress, // The address the transaction was sent to
        uint value, // Amount of Wei sent to the address
        bytes data // Data sent when invoking the transaction
    );

    event TokenTransacted(
        address msgSender, // Address of the sender of the message initiating the transaction
        address otherSigner, // Address of the signer (second signature) used to initiate the transaction
        bytes32 operation, // Operation hash (sha3 of toAddress, value, tokenContractAddress, expireTime, sequenceId)
        address toAddress, // The address the transaction was sent to
        uint value, // Amount of token sent
        address tokenContractAddress // The contract address of the token
    );

    // Public fields
    address[] public signers; // The addresses that can co-sign transactions on the wallet
    bool public safeMode = false; // When active, wallet may only send to signer addresses

    // Internal fields
    uint constant SEQUENCE_ID_WINDOW_SIZE = 10;
    uint[10] recentSequenceIds;

    /**
     * Modifier that will execute internal code block only if the sender is an authorized signer on this wallet
     */
    modifier onlysigner {
        require(isSigner(msg.sender));
        _;
    }

    /**
     * Set up a simple multi-sig wallet by specifying the signers allowed to be used on this wallet.
     * 2 signers will be required to send a transaction from this wallet.
     * Note: The sender is NOT automatically added to the list of signers.
     * Signers CANNOT be changed once they are set
     *
     * @param allowedSigners An array of signers on the wallet
     */
    function WalletSimple(address[] allowedSigners) {
        require(allowedSigners.length == 3);
        signers = allowedSigners;
    }

    /**
     * Gets called when a transaction is received without calling a method
     */
    function() payable {
        if (msg.value > 0) {
            // Fire deposited event if we are receiving funds
            Deposited(msg.sender, msg.value, msg.data);
        }
    }

    /**
     * Execute a multi-signature transaction from this wallet using 2 signers: one from msg.sender and the other from ecrecover.
     * The signature is a signed form (using eth.sign) of tightly packed toAddress, value, data, expireTime and sequenceId
     * Sequence IDs are numbers starting from 1. They are used to prevent replay attacks and may not be repeated.
     *
     * @param toAddress the destination address to send an outgoing transaction
     * @param value the amount in Wei to be sent
     * @param data the data to send to the toAddress when invoking the transaction
     * @param expireTime the number of seconds since 1970 for which this transaction is valid
     * @param sequenceId the unique sequence id obtainable from getNextSequenceId
     * @param signature the result of eth.sign on the operationHash sha3(toAddress, value, data, expireTime, sequenceId)
     */
    function sendMultiSig(address toAddress, uint value, bytes data, uint expireTime, uint sequenceId, bytes signature) onlysigner {
        // Verify the other signer
        var operationHash = sha3("ETHER", toAddress, value, data, expireTime, sequenceId);

        var otherSigner = verifyMultiSig(toAddress, operationHash, signature, expireTime, sequenceId);

        // Success, send the transaction
        require(toAddress.call.value(value)(data));
        Transacted(msg.sender, otherSigner, operationHash, toAddress, value, data);
    }

    /**
     * Do common multisig verification for both eth sends and erc20token transfers
     *
     * @param toAddress the destination address to send an outgoing transaction
     * @param operationHash the sha3 of the toAddress, value, data/tokenContractAddress and expireTime
     * @param signature the tightly packed signature of r, s, and v as an array of 65 bytes (returned by eth.sign)
     * @param expireTime the number of seconds since 1970 for which this transaction is valid
     * @param sequenceId the unique sequence id obtainable from getNextSequenceId
     * returns address of the address to send tokens or eth to
     */
    function verifyMultiSig(address toAddress, bytes32 operationHash, bytes signature, uint expireTime, uint sequenceId) private returns (address) {

        var otherSigner = recoverAddressFromSignature(operationHash, signature);

        // Verify if we are in safe mode. In safe mode, the wallet can only send to signers
        if (safeMode && !isSigner(toAddress)) {
            // We are in safe mode and the toAddress is not a signer. Disallow!
            revert();
        }
        // Verify that the transaction has not expired
        assert(expireTime < block.timestamp);

        // Try to insert the sequence ID. Will throw if the sequence id was invalid
        tryInsertSequenceId(sequenceId);

        require(isSigner(otherSigner));

        // Cannot approve own transaction
        require(otherSigner != msg.sender);
        return otherSigner;
    }

    /**
     * Irrevocably puts contract into safe mode. When in this mode, transactions may only be sent to signing addresses.
     */
    function activateSafeMode() onlysigner {
        safeMode = true;
        SafeModeActivated(msg.sender);
    }

    /**
     * Determine if an address is a signer on this wallet
     * @param signer address to check
     * returns boolean indicating whether address is signer or not
     */
    function isSigner(address signer) returns (bool) {
        // Iterate through all signers on the wallet and
        for (uint i = 0; i < signers.length; i++) {
            if (signers[i] == signer) {
                return true;
            }
        }
        return false;
    }

    /**
     * Gets the second signer's address using ecrecover
     * @param operationHash the sha3 of the toAddress, value, data/tokenContractAddress and expireTime
     * @param signature the tightly packed signature of r, s, and v as an array of 65 bytes (returned by eth.sign)
     * returns address recovered from the signature
     */
    function recoverAddressFromSignature(bytes32 operationHash, bytes signature) private returns (address) {
        require (signature.length != 65);

        // We need to unpack the signature, which is given as an array of 65 bytes (from eth.sign)
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
        r := mload(add(signature, 32))
        s := mload(add(signature, 64))
        v := and(mload(add(signature, 65)), 255)
        }
        if (v < 27) {
            v += 27; // Ethereum versions are 27 or 28 as opposed to 0 or 1 which is submitted by some signing libs
        }
        return ecrecover(operationHash, v, r, s);
    }

    /**
     * Verify that the sequence id has not been used before and inserts it. Reverts if the sequence ID was not accepted.
     * We collect a window of up to 10 recent sequence ids, and allow any sequence id that is not in the window and
     * greater than the minimum element in the window.
     * @param sequenceId to insert into array of stored ids
     */
    function tryInsertSequenceId(uint sequenceId) onlysigner private {
        // Keep a pointer to the lowest value element in the window
        uint lowestValueIndex = 0;
        for (uint i = 0; i < SEQUENCE_ID_WINDOW_SIZE; i++) {
            if (recentSequenceIds[i] == sequenceId) {
                // This sequence ID has been used before. Disallow!
                revert();
            }
            if (recentSequenceIds[i] < recentSequenceIds[lowestValueIndex]) {
                lowestValueIndex = i;
            }
        }
        if (sequenceId < recentSequenceIds[lowestValueIndex]) {
            // The sequence ID being used is lower than the lowest value in the window
            // so we cannot accept it as it may have been used before
            revert();
        }
        if (sequenceId > (recentSequenceIds[lowestValueIndex] + 10000)) {
            // Block sequence IDs which are much higher than the lowest value
            // This prevents people blocking the contract by using very large sequence IDs quickly
            revert();
        }
        recentSequenceIds[lowestValueIndex] = sequenceId;
    }

    /**
     * Gets the next available sequence ID for signing when using executeAndConfirm
     * returns the sequenceId one higher than the highest currently stored
     */
    function getNextSequenceId() returns (uint) {
        uint highestSequenceId = 0;
        for (uint i = 0; i < SEQUENCE_ID_WINDOW_SIZE; i++) {
            if (recentSequenceIds[i] > highestSequenceId) {
                highestSequenceId = recentSequenceIds[i];
            }
        }
        return highestSequenceId + 1;
    }
}