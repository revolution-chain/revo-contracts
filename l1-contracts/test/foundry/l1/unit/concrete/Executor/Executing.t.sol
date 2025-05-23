// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Test.sol";
import {Utils, L2_SYSTEM_CONTEXT_ADDRESS} from "../Utils/Utils.sol";

import {ExecutorTest, EMPTY_PREPUBLISHED_COMMITMENT, POINT_EVALUATION_PRECOMPILE_RESULT} from "./_Executor_Shared.t.sol";

import {POINT_EVALUATION_PRECOMPILE_ADDR} from "contracts/common/Config.sol";
import {L2_BOOTLOADER_ADDRESS} from "contracts/common/L2ContractAddresses.sol";
import {COMMIT_TIMESTAMP_NOT_OLDER, REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {IExecutor, SystemLogKey} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {PriorityOperationsRollingHashMismatch, BatchHashMismatch, NonSequentialBatch, CantExecuteUnprovenBatches, QueueIsEmpty, TxHashMismatch} from "contracts/common/L1ContractErrors.sol";

contract ExecutingTest is ExecutorTest {
    bytes32 l2DAValidatorOutputHash;
    bytes32[] blobVersionedHashes;

    bytes32[] priorityOpsHashes;
    bytes32 correctRollingHash;

    function appendPriorityOps() internal {
        for (uint256 i = 0; i < priorityOpsHashes.length; i++) {
            executor.appendPriorityOp(priorityOpsHashes[i]);
        }
    }

    function generatePriorityOps() internal {
        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = keccak256("hash1");
        hashes[1] = keccak256("hash2");

        bytes32 rollingHash = keccak256("");

        for (uint256 i = 0; i < hashes.length; i++) {
            rollingHash = keccak256(bytes.concat(rollingHash, hashes[i]));
        }

        correctRollingHash = rollingHash;
        priorityOpsHashes = hashes;
    }

    function setUp() public {
        generatePriorityOps();

        bytes1 source = bytes1(0x01);
        bytes memory defaultBlobCommitment = Utils.getDefaultBlobCommitment();

        bytes32 uncompressedStateDiffHash = Utils.randomBytes32("uncompressedStateDiffHash");
        bytes32 totalL2PubdataHash = Utils.randomBytes32("totalL2PubdataHash");
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);
        blobsLinearHashes[0] = Utils.randomBytes32("blobsLinearHashes");

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            source,
            defaultBlobCommitment,
            EMPTY_PREPUBLISHED_COMMITMENT
        );

        l2DAValidatorOutputHash = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        blobVersionedHashes = new bytes32[](1);
        blobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;

        bytes memory precompileInput = Utils.defaultPointEvaluationPrecompileInput(blobVersionedHashes[0]);
        vm.mockCall(POINT_EVALUATION_PRECOMPILE_ADDR, precompileInput, POINT_EVALUATION_PRECOMPILE_RESULT);

        // This currently only uses the legacy priority queue, not the priority tree.
        executor.setPriorityTreeStartIndex(1);
        vm.warp(COMMIT_TIMESTAMP_NOT_OLDER + 1);
        currentTimestamp = block.timestamp;

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY))] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
        correctL2Logs[uint256(uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY))] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            correctRollingHash
        );
        correctL2Logs[uint256(uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY))] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(priorityOpsHashes.length)
        );

        bytes memory l2Logs = Utils.encodePacked(correctL2Logs);

        newCommitBatchInfo.systemLogs = l2Logs;
        newCommitBatchInfo.timestamp = uint64(currentTimestamp);
        newCommitBatchInfo.operatorDAInput = operatorDAInput;
        newCommitBatchInfo.priorityOperationsHash = correctRollingHash;
        newCommitBatchInfo.numberOfLayer1Txs = priorityOpsHashes.length;

        IExecutor.CommitBatchInfo[] memory commitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        commitBatchInfoArray[0] = newCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            commitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        newStoredBatchInfo = IExecutor.StoredBatchInfo({
            batchNumber: 1,
            batchHash: entries[0].topics[2],
            indexRepeatedStorageChanges: 0,
            numberOfLayer1Txs: priorityOpsHashes.length,
            priorityOperationsHash: correctRollingHash,
            l2LogsTreeRoot: 0,
            timestamp: currentTimestamp,
            commitment: entries[0].topics[3]
        });

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 proveBatchFrom, uint256 proveBatchTo, bytes memory proveData) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            storedBatchInfoArray,
            proofInput
        );
        executor.proveBatchesSharedBridge(uint256(0), proveBatchFrom, proveBatchTo, proveData);
    }

    function test_RevertWhen_ExecutingBlockWithWrongBatchNumber() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.batchNumber = 10; // Correct is 1

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = wrongNewStoredBatchInfo;

        vm.prank(validator);
        vm.expectRevert(NonSequentialBatch.selector);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        executor.executeBatchesSharedBridge(uint256(0), executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_ExecutingBlockWithWrongData() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo memory wrongNewStoredBatchInfo = newStoredBatchInfo;
        wrongNewStoredBatchInfo.timestamp = 0; // incorrect timestamp

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = wrongNewStoredBatchInfo;

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchHashMismatch.selector,
                keccak256(abi.encode(newStoredBatchInfo)),
                keccak256(abi.encode(wrongNewStoredBatchInfo))
            )
        );
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        executor.executeBatchesSharedBridge(uint256(0), executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_ExecutingRevertedBlockWithoutCommittingAndProvingAgain() public {
        appendPriorityOps();

        vm.prank(validator);
        executor.revertBatchesSharedBridge(0, 0);

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        vm.expectRevert(CantExecuteUnprovenBatches.selector);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        executor.executeBatchesSharedBridge(uint256(0), executeBatchFrom, executeBatchTo, executeData);
    }

    function test_RevertWhen_ExecutingUnavailablePriorityOperationHash() public {
        vm.prank(validator);
        executor.revertBatchesSharedBridge(0, 0);

        bytes32 arbitraryCanonicalTxHash = Utils.randomBytes32("arbitraryCanonicalTxHash");
        bytes32 chainedPriorityTxHash = keccak256(bytes.concat(keccak256(""), arbitraryCanonicalTxHash));

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
        correctL2Logs[uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            chainedPriorityTxHash
        );
        correctL2Logs[uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(uint256(1))
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.priorityOperationsHash = chainedPriorityTxHash;
        correctNewCommitBatchInfo.numberOfLayer1Txs = 1;

        IExecutor.CommitBatchInfo[] memory correctNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctNewCommitBatchInfoArray[0] = correctNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        IExecutor.StoredBatchInfo memory correctNewStoredBatchInfo = newStoredBatchInfo;
        correctNewStoredBatchInfo.batchHash = entries[0].topics[2];
        correctNewStoredBatchInfo.numberOfLayer1Txs = 1;
        correctNewStoredBatchInfo.priorityOperationsHash = chainedPriorityTxHash;
        correctNewStoredBatchInfo.commitment = entries[0].topics[3];

        IExecutor.StoredBatchInfo[] memory correctNewStoredBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        correctNewStoredBatchInfoArray[0] = correctNewStoredBatchInfo;

        vm.prank(validator);
        uint256 processBatchFrom;
        uint256 processBatchTo;
        bytes memory processData;
        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeProveBatchesData(
                genesisStoredBatchInfo,
                correctNewStoredBatchInfoArray,
                proofInput
            );
            executor.proveBatchesSharedBridge(uint256(0), processBatchFrom, processBatchTo, processData);
        }

        vm.prank(validator);
        vm.expectRevert(QueueIsEmpty.selector);
        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeExecuteBatchesData(
                correctNewStoredBatchInfoArray,
                Utils.generatePriorityOps(correctNewStoredBatchInfoArray.length)
            );
            executor.executeBatchesSharedBridge(uint256(0), processBatchFrom, processBatchTo, processData);
        }
    }

    function test_RevertWhen_ExecutingWithUnmatchedPriorityOperationHash() public {
        appendPriorityOps();

        vm.prank(validator);
        executor.revertBatchesSharedBridge(0, 0);

        bytes32 arbitraryCanonicalTxHash = Utils.randomBytes32("arbitraryCanonicalTxHash");
        bytes32 chainedPriorityTxHash = keccak256(bytes.concat(keccak256(""), arbitraryCanonicalTxHash));

        bytes[] memory correctL2Logs = Utils.createSystemLogs(l2DAValidatorOutputHash);
        correctL2Logs[uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY)] = Utils.constructL2Log(
            true,
            L2_SYSTEM_CONTEXT_ADDRESS,
            uint256(SystemLogKey.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY),
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp)
        );
        correctL2Logs[uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.CHAINED_PRIORITY_TXN_HASH_KEY),
            chainedPriorityTxHash
        );
        correctL2Logs[uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY)] = Utils.constructL2Log(
            true,
            L2_BOOTLOADER_ADDRESS,
            uint256(SystemLogKey.NUMBER_OF_LAYER_1_TXS_KEY),
            bytes32(uint256(1))
        );
        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = Utils.encodePacked(correctL2Logs);
        correctNewCommitBatchInfo.priorityOperationsHash = chainedPriorityTxHash;
        correctNewCommitBatchInfo.numberOfLayer1Txs = 1;

        IExecutor.CommitBatchInfo[] memory correctNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctNewCommitBatchInfoArray[0] = correctNewCommitBatchInfo;

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.recordLogs();
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisStoredBatchInfo,
            correctNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        IExecutor.StoredBatchInfo memory correctNewStoredBatchInfo = newStoredBatchInfo;
        correctNewStoredBatchInfo.batchHash = entries[0].topics[2];
        correctNewStoredBatchInfo.numberOfLayer1Txs = 1;
        correctNewStoredBatchInfo.priorityOperationsHash = chainedPriorityTxHash;
        correctNewStoredBatchInfo.commitment = entries[0].topics[3];

        IExecutor.StoredBatchInfo[] memory correctNewStoredBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        correctNewStoredBatchInfoArray[0] = correctNewStoredBatchInfo;

        vm.prank(validator);
        uint256 processBatchFrom;
        uint256 processBatchTo;
        bytes memory processData;
        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeProveBatchesData(
                genesisStoredBatchInfo,
                correctNewStoredBatchInfoArray,
                proofInput
            );
            executor.proveBatchesSharedBridge(uint256(0), processBatchFrom, processBatchTo, processData);
        }

        bytes32 randomFactoryDeps0 = Utils.randomBytes32("randomFactoryDeps0");

        bytes[] memory factoryDeps = new bytes[](1);
        factoryDeps[0] = bytes.concat(randomFactoryDeps0);

        uint256 gasPrice = 1000000000;
        uint256 l2GasLimit = 1000000;
        uint256 baseCost = mailbox.l2TransactionBaseCost(gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        uint256 l2Value = 10 ether;
        uint256 totalCost = baseCost + l2Value;

        mailbox.requestL2Transaction{value: totalCost}({
            _contractL2: address(0),
            _l2Value: l2Value,
            _calldata: bytes(""),
            _l2GasLimit: l2GasLimit,
            _l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            _factoryDeps: factoryDeps,
            _refundRecipient: address(0)
        });

        vm.prank(validator);
        vm.expectRevert(PriorityOperationsRollingHashMismatch.selector);

        {
            (processBatchFrom, processBatchTo, processData) = Utils.encodeExecuteBatchesData(
                correctNewStoredBatchInfoArray,
                Utils.generatePriorityOps(correctNewStoredBatchInfoArray.length)
            );
            executor.executeBatchesSharedBridge(uint256(0), processBatchFrom, processBatchTo, processData);
        }
    }

    function test_RevertWhen_CommittingBlockWithWrongPreviousBatchHash() public {
        appendPriorityOps();

        // solhint-disable-next-line func-named-parameters
        bytes memory correctL2Logs = abi.encodePacked(
            bytes4(0x00000001),
            bytes4(0x00000000),
            L2_SYSTEM_CONTEXT_ADDRESS,
            Utils.packBatchTimestampAndBlockTimestamp(currentTimestamp, currentTimestamp),
            bytes32("")
        );

        IExecutor.CommitBatchInfo memory correctNewCommitBatchInfo = newCommitBatchInfo;
        correctNewCommitBatchInfo.systemLogs = correctL2Logs;

        IExecutor.CommitBatchInfo[] memory correctNewCommitBatchInfoArray = new IExecutor.CommitBatchInfo[](1);
        correctNewCommitBatchInfoArray[0] = correctNewCommitBatchInfo;

        bytes32 wrongPreviousBatchHash = Utils.randomBytes32("wrongPreviousBatchHash");

        IExecutor.StoredBatchInfo memory genesisBlock = genesisStoredBatchInfo;
        genesisBlock.batchHash = wrongPreviousBatchHash;

        bytes32 storedBatchHash = getters.storedBlockHash(1);

        vm.prank(validator);
        vm.expectRevert(
            abi.encodeWithSelector(BatchHashMismatch.selector, storedBatchHash, keccak256(abi.encode(genesisBlock)))
        );
        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            genesisBlock,
            correctNewCommitBatchInfoArray
        );
        executor.commitBatchesSharedBridge(uint256(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_ShouldExecuteBatchesuccessfully() public {
        appendPriorityOps();

        IExecutor.StoredBatchInfo[] memory storedBatchInfoArray = new IExecutor.StoredBatchInfo[](1);
        storedBatchInfoArray[0] = newStoredBatchInfo;

        vm.prank(validator);
        (uint256 executeBatchFrom, uint256 executeBatchTo, bytes memory executeData) = Utils.encodeExecuteBatchesData(
            storedBatchInfoArray,
            Utils.generatePriorityOps(storedBatchInfoArray.length)
        );
        executor.executeBatchesSharedBridge(uint256(0), executeBatchFrom, executeBatchTo, executeData);

        uint256 totalBlocksExecuted = getters.getTotalBlocksExecuted();
        assertEq(totalBlocksExecuted, 1);

        bool isPriorityQueueActive = getters.isPriorityQueueActive();
        assertFalse(isPriorityQueueActive);

        uint256 processed = getters.getFirstUnprocessedPriorityTx();
        assertEq(processed, 2);
    }
}
