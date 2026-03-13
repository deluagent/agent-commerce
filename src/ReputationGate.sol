// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ReputationGate
/// @notice Hook for AgentCommerceHub that enforces minimum reputation score on providers.
/// @dev Set as the `hook` on a job. When the job is funded, the hook is called to validate
///      the provider's reputation in ServiceRegistry. Reverts if below threshold.

interface IServiceRegistry {
    function getReputation(uint256 serviceId) external view returns (uint256 score, uint256 totalRatings);
    function services(uint256 serviceId) external view returns (
        address owner, string memory name, string memory endpoint,
        string memory capabilitiesURI, uint8 serviceType,
        uint256 stake, uint256 reputationScore, uint256 totalRatings,
        bool active, uint256 registeredAt, uint256 lastRatingTime
    );
}

contract ReputationGate {
    IServiceRegistry public immutable registry;
    
    /// @notice Minimum reputation score (0–100) required to be funded as provider
    uint256 public minReputationScore;
    
    /// @notice Minimum number of ratings before gate applies (new providers get a grace period)
    uint256 public minRatingsRequired;
    
    address public owner;

    event GateUpdated(uint256 minScore, uint256 minRatings);

    error ReputationTooLow(uint256 serviceId, uint256 score, uint256 required);
    error NotEnoughRatings(uint256 serviceId, uint256 ratings, uint256 required);
    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _registry, uint256 _minReputationScore, uint256 _minRatingsRequired) {
        registry = IServiceRegistry(_registry);
        minReputationScore = _minReputationScore;
        minRatingsRequired = _minRatingsRequired;
        owner = msg.sender;
    }

    /// @notice Called by AgentCommerceHub on job fund.
    ///         Checks provider's linked serviceId reputation.
    /// @param provider The job provider address
    /// @param serviceId The ServiceRegistry service ID linked to the job
    function onFund(address provider, uint256 serviceId) external view {
        // serviceId = 0 or type(uint256).max means not linked — skip gate
        if (serviceId == 0 || serviceId == type(uint256).max) return;

        (,,,,,, uint256 score, uint256 totalRatings,,, ) = registry.services(serviceId);

        // Grace period: new providers with fewer than minRatingsRequired ratings are exempt
        if (totalRatings < minRatingsRequired) return;

        if (score < minReputationScore) {
            revert ReputationTooLow(serviceId, score, minReputationScore);
        }
    }

    /// @notice Check if a provider passes the gate (view helper for off-chain use)
    function passes(uint256 serviceId) external view returns (bool ok, string memory reason) {
        if (serviceId == 0 || serviceId == type(uint256).max) return (true, "no service linked");

        (,,,,,, uint256 score, uint256 totalRatings,,, ) = registry.services(serviceId);

        if (totalRatings < minRatingsRequired) return (true, "grace period");
        if (score < minReputationScore) {
            return (false, string(abi.encodePacked(
                "score ", _uint2str(score), " < required ", _uint2str(minReputationScore)
            )));
        }
        return (true, "ok");
    }

    function setMinReputation(uint256 _score, uint256 _ratings) external onlyOwner {
        minReputationScore = _score;
        minRatingsRequired = _ratings;
        emit GateUpdated(_score, _ratings);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0));
        owner = newOwner;
    }

    function _uint2str(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { b[--len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }
}
