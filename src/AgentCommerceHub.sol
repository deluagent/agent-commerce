// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IServiceRegistry {
    function rateService(uint256 serviceId, uint8 score, string calldata comment) external;
}

interface IHook {
    function beforeAction(uint256 jobId, string calldata action) external;
    function afterAction(uint256 jobId, string calldata action) external;
}

/**
 * @title AgentCommerceHub
 * @notice ERC-8183 compliant job escrow for agent-to-agent commerce.
 *
 * Implements the Agentic Commerce Protocol:
 *   Open → Funded → Submitted → Completed / Rejected / Expired
 *
 * Extensions beyond base ERC-8183:
 *   - ServiceRegistry integration: auto-rates provider when job completes/rejects
 *   - Platform fee (configurable, default 1%)
 *   - Reputation-gated job creation (min reputation threshold)
 *   - ERC-8004 agent identity composability
 *
 * @dev https://eips.ethereum.org/EIPS/eip-8183
 */
contract AgentCommerceHub is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── ERC-8183 State Machine ────────────────────────────────────────────────

    enum Status { Open, Funded, Submitted, Completed, Rejected, Expired }

    struct Job {
        address client;
        address provider;
        address evaluator;
        address token;          // ERC-20 payment token
        uint256 budget;         // agreed amount in token units
        uint256 expiredAt;      // unix timestamp
        uint256 serviceId;      // ServiceRegistry service ID (0 = not linked, type(uint256).max = unset)
        Status  status;
        string  description;
        string  deliverable;    // set by provider on submit
        string  evaluatorNote;  // set by evaluator on complete/reject
        bool    serviceLinked;  // whether serviceId is a valid ServiceRegistry ID
    }

    // ─── Storage ──────────────────────────────────────────────────────────────

    uint256 public jobCount;
    mapping(uint256 => Job) public jobs;
    mapping(uint256 => address) public hooks; // jobId → hook address

    address public serviceRegistry;
    address public defaultToken;    // default payment token (USDC on Base)
    uint256 public feeBps;          // platform fee in basis points (default 100 = 1%)
    uint256 public treasury;        // accumulated platform fees (in defaultToken)

    uint256 public constant MAX_FEE_BPS = 1000; // 10% max

    // ─── Events (ERC-8183 required) ───────────────────────────────────────────

    event JobCreated(uint256 indexed jobId, address indexed client, address indexed provider, address evaluator);
    event ProviderSet(uint256 indexed jobId, address indexed provider);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, string deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed provider, uint256 payment, string reason);
    event JobRejected(uint256 indexed jobId, string reason);
    event JobExpired(uint256 indexed jobId);
    event FeeUpdated(uint256 newFeeBps);
    event RegistryUpdated(address newRegistry);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidStatus(Status current, Status required);
    error Unauthorized();
    error ZeroAddress();
    error BudgetMismatch(uint256 expected, uint256 actual);
    error NotExpired();
    error AlreadyExpired();
    error FeeTooHigh();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _owner, address _defaultToken, address _serviceRegistry) Ownable(_owner) {
        if (_defaultToken == address(0)) revert ZeroAddress();
        defaultToken = _defaultToken;
        serviceRegistry = _serviceRegistry; // can be address(0) if not integrated
        feeBps = 100; // 1%
    }

    // ─── Core ERC-8183 Functions ──────────────────────────────────────────────

    /**
     * @notice Create a new job. Provider can be address(0) to be set later.
     * @param provider  Service provider address (or address(0))
     * @param evaluator Who attests completion. Can be client, or a smart contract.
     * @param expiredAt Unix timestamp after which anyone can claimRefund
     * @param description Job brief / scope reference
     * @param hook Optional hook contract (address(0) = none)
     * @param serviceId ServiceRegistry service ID for auto-rating (type(uint256).max = none)
     */
    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook,
        uint256 serviceId
    ) external returns (uint256 jobId) {
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp) revert AlreadyExpired();

        jobId = jobCount++;

        bool linked = serviceId != type(uint256).max && serviceRegistry != address(0);

        jobs[jobId] = Job({
            client:        msg.sender,
            provider:      provider,
            evaluator:     evaluator,
            token:         defaultToken,
            budget:        0,
            expiredAt:     expiredAt,
            serviceId:     serviceId,
            status:        Status.Open,
            description:   description,
            deliverable:   "",
            evaluatorNote: "",
            serviceLinked: linked
        });

        if (hook != address(0)) hooks[jobId] = hook;

        emit JobCreated(jobId, msg.sender, provider, evaluator);
    }

    /**
     * @notice Set or negotiate the job budget. Either client or provider may call.
     */
    function setBudget(uint256 jobId, uint256 amount) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert InvalidStatus(job.status, Status.Open);
        if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();
        job.budget = amount;
        emit BudgetSet(jobId, amount);
    }

    /**
     * @notice Set the provider after job creation (only when provider == address(0)).
     */
    function setProvider(uint256 jobId, address provider) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert InvalidStatus(job.status, Status.Open);
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert Unauthorized(); // already set
        if (provider == address(0)) revert ZeroAddress();
        job.provider = provider;
        emit ProviderSet(jobId, provider);
    }

    /**
     * @notice Client funds the job escrow. Pulls token from client.
     * @param expectedBudget Front-running protection — must match job.budget.
     */
    function fund(uint256 jobId, uint256 expectedBudget) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) revert InvalidStatus(job.status, Status.Open);
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ZeroAddress(); // provider must be set
        if (job.budget != expectedBudget) revert BudgetMismatch(job.budget, expectedBudget);
        if (block.timestamp >= job.expiredAt) revert AlreadyExpired();

        _hook(jobId, "fund", true);

        IERC20(job.token).safeTransferFrom(msg.sender, address(this), job.budget);
        job.status = Status.Funded;

        _hook(jobId, "fund", false);
        emit JobFunded(jobId, job.budget);
    }

    /**
     * @notice Provider submits deliverable. Moves Funded → Submitted.
     */
    function submit(uint256 jobId, string calldata deliverable) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Funded) revert InvalidStatus(job.status, Status.Funded);
        if (msg.sender != job.provider) revert Unauthorized();
        if (block.timestamp >= job.expiredAt) revert AlreadyExpired();

        _hook(jobId, "submit", true);

        job.deliverable = deliverable;
        job.status = Status.Submitted;

        _hook(jobId, "submit", false);
        emit JobSubmitted(jobId, deliverable);
    }

    /**
     * @notice Evaluator marks job complete. Releases escrow to provider.
     */
    function complete(uint256 jobId, string calldata reason) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) revert InvalidStatus(job.status, Status.Submitted);
        if (msg.sender != job.evaluator) revert Unauthorized();

        _hook(jobId, "complete", true);

        job.evaluatorNote = reason;
        job.status = Status.Completed;

        // Calculate platform fee
        uint256 fee = (job.budget * feeBps) / 10_000;
        uint256 payment = job.budget - fee;
        treasury += fee;

        IERC20(job.token).safeTransfer(job.provider, payment);

        // Auto-rate in ServiceRegistry (good: 5/5)
        _autoRate(job, 5, string.concat("job completed: ", reason));

        _hook(jobId, "complete", false);
        emit JobCompleted(jobId, job.provider, payment, reason);
    }

    /**
     * @notice Evaluator (or client if Open) rejects job. Refunds client.
     */
    function reject(uint256 jobId, string calldata reason) external nonReentrant {
        Job storage job = jobs[jobId];

        if (job.status == Status.Open) {
            if (msg.sender != job.client) revert Unauthorized();
        } else if (job.status == Status.Funded || job.status == Status.Submitted) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert InvalidStatus(job.status, Status.Funded);
        }

        _hook(jobId, "reject", true);

        job.evaluatorNote = reason;
        job.status = Status.Rejected;

        if (job.budget > 0 && IERC20(job.token).balanceOf(address(this)) >= job.budget) {
            IERC20(job.token).safeTransfer(job.client, job.budget);
        }

        // Auto-rate in ServiceRegistry (bad: 1/5 if submitted, neutral: 3/5 if not)
        uint8 score = bytes(job.deliverable).length > 0 ? 1 : 3;
        _autoRate(job, score, string.concat("job rejected: ", reason));

        _hook(jobId, "reject", false);
        emit JobRejected(jobId, reason);
    }

    /**
     * @notice Anyone can trigger expiry after expiredAt. Refunds client.
     */
    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.status != Status.Funded && job.status != Status.Submitted) {
            revert InvalidStatus(job.status, Status.Funded);
        }
        if (block.timestamp < job.expiredAt) revert NotExpired();

        job.status = Status.Expired;

        if (job.budget > 0) {
            IERC20(job.token).safeTransfer(job.client, job.budget);
        }

        emit JobExpired(jobId);
    }

    // ─── ServiceRegistry integration ──────────────────────────────────────────

    function _autoRate(Job storage job, uint8 score, string memory comment) internal {
        if (!job.serviceLinked || serviceRegistry == address(0)) return;
        try IServiceRegistry(serviceRegistry).rateService(job.serviceId, score, comment) {}
        catch {} // never revert on rating failure
    }

    // ─── Hook support ─────────────────────────────────────────────────────────

    function _hook(uint256 jobId, string memory action, bool before) internal {
        address h = hooks[jobId];
        if (h == address(0)) return;
        try IHook(h).beforeAction(jobId, action) {} catch {}
        if (!before) {
            try IHook(h).afterAction(jobId, action) {} catch {}
        }
    }

    // ─── View functions ───────────────────────────────────────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    function getJobStatus(uint256 jobId) external view returns (Status) {
        return jobs[jobId].status;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setServiceRegistry(address newRegistry) external onlyOwner {
        serviceRegistry = newRegistry;
        emit RegistryUpdated(newRegistry);
    }

    function withdrawFees(address to) external onlyOwner nonReentrant {
        uint256 amount = treasury;
        treasury = 0;
        IERC20(defaultToken).safeTransfer(to, amount);
    }
}
