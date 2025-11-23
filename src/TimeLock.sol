// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title TimeLock
 * @notice Impose un délai minimum avant l'exécution d'actions critiques
 * @dev Protège contre les rug pulls et donne du temps aux utilisateurs pour réagir
 */
contract TimeLock is AccessControl {
    
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    
    uint256 public constant MIN_DELAY = 2 days;
    uint256 public constant MAX_DELAY = 30 days;
    uint256 public constant GRACE_PERIOD = 7 days; // Fenêtre pour exécuter après le délai
    
    struct Operation {
        address target;
        bytes data;
        uint256 value;
        uint256 executeAfter;
        uint256 expiresAt;
        bool executed;
        bool cancelled;
        string description;
    }
    
    mapping(bytes32 => Operation) public operations;
    bytes32[] public operationIds;
    
    event OperationScheduled(
        bytes32 indexed id,
        address indexed target,
        bytes data,
        uint256 value,
        uint256 executeAfter,
        string description
    );
    
    event OperationExecuted(bytes32 indexed id, address indexed executor);
    event OperationCancelled(bytes32 indexed id, address indexed canceller);
    
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROPOSER_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(CANCELLER_ROLE, admin);
    }
    
    /**
     * @notice Planifie une opération pour exécution future
     * @param target Contrat cible
     * @param data Calldata à exécuter
     * @param value ETH à envoyer (0 pour la plupart des cas)
     * @param delay Délai avant exécution (minimum MIN_DELAY)
     * @param description Description lisible de l'opération
     */
    function schedule(
        address target,
        bytes calldata data,
        uint256 value,
        uint256 delay,
        string calldata description
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32) {
        require(delay >= MIN_DELAY && delay <= MAX_DELAY, "Invalid delay");
        require(target != address(0), "Invalid target");
        
        bytes32 id = keccak256(abi.encode(target, data, value, block.timestamp));
        require(operations[id].executeAfter == 0, "Already scheduled");
        
        uint256 executeAfter = block.timestamp + delay;
        uint256 expiresAt = executeAfter + GRACE_PERIOD;
        
        operations[id] = Operation({
            target: target,
            data: data,
            value: value,
            executeAfter: executeAfter,
            expiresAt: expiresAt,
            executed: false,
            cancelled: false,
            description: description
        });
        
        operationIds.push(id);
        
        emit OperationScheduled(id, target, data, value, executeAfter, description);
        
        return id;
    }
    
    /**
     * @notice Exécute une opération après le délai
     */
    function execute(bytes32 id) external payable onlyRole(EXECUTOR_ROLE) {
        Operation storage op = operations[id];
        
        require(op.executeAfter > 0, "Not scheduled");
        require(!op.executed, "Already executed");
        require(!op.cancelled, "Cancelled");
        require(block.timestamp >= op.executeAfter, "Too soon");
        require(block.timestamp <= op.expiresAt, "Expired");
        require(msg.value == op.value, "Wrong value");
        
        op.executed = true;
        
        (bool success, bytes memory returnData) = op.target.call{value: op.value}(op.data);
        require(success, _getRevertMsg(returnData));
        
        emit OperationExecuted(id, msg.sender);
    }
    
    /**
     * @notice Annule une opération planifiée (emergency)
     */
    function cancel(bytes32 id) external onlyRole(CANCELLER_ROLE) {
        Operation storage op = operations[id];
        
        require(op.executeAfter > 0, "Not scheduled");
        require(!op.executed, "Already executed");
        require(!op.cancelled, "Already cancelled");
        
        op.cancelled = true;
        
        emit OperationCancelled(id, msg.sender);
    }
    
    /**
     * @notice Récupère une opération par son ID
     */
    function getOperation(bytes32 id) external view returns (
        address target,
        bytes memory data,
        uint256 value,
        uint256 executeAfter,
        uint256 expiresAt,
        bool executed,
        bool cancelled,
        string memory description
    ) {
        Operation memory op = operations[id];
        return (
            op.target,
            op.data,
            op.value,
            op.executeAfter,
            op.expiresAt,
            op.executed,
            op.cancelled,
            op.description
        );
    }
    
    /**
     * @notice Récupère toutes les opérations en attente
     */
    function getPendingOperations() external view returns (bytes32[] memory) {
        uint256 count = 0;
        
        // Compter les pending
        for (uint256 i = 0; i < operationIds.length; i++) {
            Operation memory op = operations[operationIds[i]];
            if (!op.executed && !op.cancelled && block.timestamp < op.expiresAt) {
                count++;
            }
        }
        
        // Remplir le tableau
        bytes32[] memory pending = new bytes32[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < operationIds.length; i++) {
            Operation memory op = operations[operationIds[i]];
            if (!op.executed && !op.cancelled && block.timestamp < op.expiresAt) {
                pending[index] = operationIds[i];
                index++;
            }
        }
        
        return pending;
    }
    
    /**
     * @notice Vérifie si une opération est prête à être exécutée
     */
    function isReady(bytes32 id) external view returns (bool) {
        Operation memory op = operations[id];
        return op.executeAfter > 0 
            && !op.executed 
            && !op.cancelled 
            && block.timestamp >= op.executeAfter 
            && block.timestamp <= op.expiresAt;
    }
    
    /**
     * @notice Helper pour extraire le message d'erreur
     */
    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        if (_returnData.length < 68) return "Transaction reverted silently";
        
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}