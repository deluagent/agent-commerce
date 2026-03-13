// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AgentCommerceHub.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Minimal ServiceRegistry for integration testing ─────────────────────────
// Mirrors the real deployed contract's interface + state machine

contract ServiceRegistry {
    struct Service {
        address owner;
        string  name;
        string  capabilitiesURI;
        uint256 pricePerCallWei;
        uint8   category;
        uint256 stakedETH;
        uint256 reputationScore; // 0-10000 (basis points, 5000 = 50%)
        uint256 totalCalls;
        uint256 goodResponses;
        uint256 badResponses;
        uint256 registeredAt;
        bool    active;
        bool    slashed;
    }

    uint256 public constant INITIAL_REPUTATION  = 5000;
    uint256 public constant REP_GOOD_DELTA      = 100;   // +1%
    uint256 public constant REP_BAD_DELTA       = 500;   // -5%
    uint256 public constant SLASH_BPS           = 2000;  // 20%
    uint256 public constant BAD_THRESHOLD       = 10;
    uint256 public constant MIN_STAKE           = 0.001 ether;
    uint256 public constant RATE_COOLDOWN       = 24 hours;

    mapping(uint256 => Service) public services;
    mapping(uint256 => mapping(address => uint256)) public lastRatingTime;
    uint256 public serviceCount;
    uint256 public treasuryBalance;
    address public owner;

    event ServiceRegistered(uint256 indexed id, address indexed owner, string name);
    event ServiceRated(uint256 indexed id, address indexed rater, uint8 score);
    event ServiceSlashed(uint256 indexed id, uint256 amount);

    constructor(address _owner) { owner = _owner; }

    function register(
        string calldata name,
        string calldata capabilitiesURI,
        uint256 pricePerCallWei,
        uint8 category
    ) external payable returns (uint256 id) {
        require(msg.value >= MIN_STAKE, "insufficient stake");
        id = serviceCount++;
        services[id] = Service({
            owner:           msg.sender,
            name:            name,
            capabilitiesURI: capabilitiesURI,
            pricePerCallWei: pricePerCallWei,
            category:        category,
            stakedETH:       msg.value,
            reputationScore: INITIAL_REPUTATION,
            totalCalls:      0,
            goodResponses:   0,
            badResponses:    0,
            registeredAt:    block.timestamp,
            active:          true,
            slashed:         false
        });
        emit ServiceRegistered(id, msg.sender, name);
    }

    function rateService(uint256 id, uint8 score, string calldata) external {
        Service storage svc = services[id];
        require(svc.active, "not active");
        require(score >= 1 && score <= 5, "score 1-5");

        // Rate limit (skip if never rated)
        if (lastRatingTime[id][msg.sender] != 0) {
            require(block.timestamp >= lastRatingTime[id][msg.sender] + RATE_COOLDOWN, "rate limited");
        }
        lastRatingTime[id][msg.sender] = block.timestamp;

        svc.totalCalls++;

        if (score >= 4) {
            svc.goodResponses++;
            svc.reputationScore = min(10000, svc.reputationScore + REP_GOOD_DELTA);
        } else if (score <= 2) {
            svc.badResponses++;
            if (svc.reputationScore >= REP_BAD_DELTA) {
                svc.reputationScore -= REP_BAD_DELTA;
            } else {
                svc.reputationScore = 0;
            }
            if (svc.badResponses >= BAD_THRESHOLD) _slash(id);
        }
        emit ServiceRated(id, msg.sender, score);
    }

    function _slash(uint256 id) internal {
        Service storage svc = services[id];
        uint256 slashAmount = (svc.stakedETH * SLASH_BPS) / 10000;
        svc.stakedETH -= slashAmount;
        treasuryBalance += slashAmount;
        svc.slashed = true;
        emit ServiceSlashed(id, slashAmount);
    }

    function getService(uint256 id) external view returns (
        address, string memory, string memory, uint256, uint8,
        uint256, uint256, uint256, uint256, uint256, uint256, bool, bool
    ) {
        Service storage s = services[id];
        return (s.owner, s.name, s.capabilitiesURI, s.pricePerCallWei, s.category,
                s.stakedETH, s.reputationScore, s.totalCalls, s.goodResponses,
                s.badResponses, s.registeredAt, s.active, s.slashed);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    receive() external payable {}
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// ─── Integration Tests ────────────────────────────────────────────────────────

contract IntegrationTest is Test {
    AgentCommerceHub hub;
    ServiceRegistry  registry;
    MockUSDC         usdc;

    address owner     = makeAddr("protocol-owner");
    address client    = makeAddr("client-agent");
    address provider  = makeAddr("provider-agent");
    address evaluator = makeAddr("evaluator");

    uint256 serviceId;
    uint256 constant BUDGET   = 50_000_000; // 50 USDC
    uint256 constant DEADLINE = 7 days;

    function setUp() public {
        usdc     = new MockUSDC();
        registry = new ServiceRegistry(owner);
        hub      = new AgentCommerceHub(owner, address(usdc), address(registry));

        // Register provider as a service in ServiceRegistry
        vm.deal(provider, 1 ether);
        vm.prank(provider);
        serviceId = registry.register{value: 0.001 ether}(
            "ProviderAgent",
            "https://provider.example.com/capabilities.json",
            1_000_000, // 1 USDC per call
            0 // AI category
        );

        // Fund client with USDC
        usdc.mint(client, 1_000_000_000); // 1000 USDC
        vm.prank(client);
        usdc.approve(address(hub), type(uint256).max);

        // Grant hub permission to rate (hub will call rateService as evaluator callback)
        // In real scenario the evaluator IS the caller who calls complete()
    }

    // ─── Test 1: Full happy path ───────────────────────────────────────────────

    function test_fullLoop_jobToReputation() public {
        uint256 repBefore = _getReputation(serviceId);
        assertEq(repBefore, 5000); // starts at 50%

        // 1. Client discovers provider via ServiceRegistry ✓ (done in setUp)

        // 2. Client creates job linked to serviceId
        vm.prank(client);
        uint256 jobId = hub.createJob(
            provider,
            evaluator,
            block.timestamp + DEADLINE,
            "Analyze this dataset and return summary",
            address(0),
            serviceId
        );

        // 3. Agree on budget
        vm.prank(client);
        hub.setBudget(jobId, BUDGET);

        // 4. Client funds escrow
        vm.prank(client);
        hub.fund(jobId, BUDGET);
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Funded));

        // 5. Provider submits deliverable
        vm.prank(provider);
        hub.submit(jobId, "ipfs://QmAnalysisResult123");
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Submitted));

        // 6. Evaluator attests completion
        uint256 providerBalBefore = usdc.balanceOf(provider);
        vm.prank(evaluator);
        hub.complete(jobId, "analysis verified correct");

        // 7. Provider got paid (minus 1% fee)
        uint256 fee = (BUDGET * 100) / 10_000;
        assertEq(usdc.balanceOf(provider), providerBalBefore + BUDGET - fee);
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Completed));

        // 8. ServiceRegistry auto-rated the provider 5/5
        uint256 repAfter = _getReputation(serviceId);
        assertGt(repAfter, repBefore); // reputation INCREASED
        assertEq(repAfter, 5000 + 100); // +100 bps = +1%
    }

    // ─── Test 2: Bad job → reputation decreases ───────────────────────────────

    function test_badJob_reputationDecreases() public {
        uint256 repBefore = _getReputation(serviceId);

        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "task", address(0), serviceId);
        vm.prank(client);
        hub.setBudget(jobId, BUDGET);
        vm.prank(client);
        hub.fund(jobId, BUDGET);

        // Provider submits (bad work)
        vm.prank(provider);
        hub.submit(jobId, "garbage output");

        // Evaluator rejects
        vm.prank(evaluator);
        hub.reject(jobId, "output was incorrect");

        // Client got refund
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Rejected));

        // ServiceRegistry: provider rated 1/5 → reputation decreased
        uint256 repAfter = _getReputation(serviceId);
        assertLt(repAfter, repBefore); // reputation DECREASED
        assertEq(repAfter, 5000 - 500); // -500 bps = -5%
    }

    // ─── Test 3: Slash after 10 bad jobs ──────────────────────────────────────

    function test_tenBadJobs_triggersSlash() public {
        uint256 stakeBefore = _getStake(serviceId);
        assertEq(stakeBefore, 0.001 ether);

        // 10 different raters give score=1
        for (uint256 i = 0; i < 10; i++) {
            address rater = makeAddr(string.concat("rater", vm.toString(i)));
            vm.prank(rater);
            registry.rateService(serviceId, 1, "terrible");
        }

        // After 10 bad ratings, should be auto-slashed
        bool slashed = _getSlashed(serviceId);
        assertTrue(slashed, "should be slashed after 10 bad ratings");

        // Stake reduced by 20%
        uint256 stakeAfter = _getStake(serviceId);
        assertEq(stakeAfter, stakeBefore - (stakeBefore * 2000) / 10_000);
    }

    // ─── Test 4: Job with no service link — no auto-rating ────────────────────

    function test_noServiceLink_noAutoRating() public {
        uint256 repBefore = _getReputation(serviceId);

        // Create job with type(uint256).max = not linked
        vm.prank(client);
        uint256 jobId = hub.createJob(
            provider, evaluator,
            block.timestamp + DEADLINE,
            "task", address(0),
            type(uint256).max // NOT linked
        );
        vm.prank(client);
        hub.setBudget(jobId, BUDGET);
        vm.prank(client);
        hub.fund(jobId, BUDGET);
        vm.prank(provider);
        hub.submit(jobId, "work");
        vm.prank(evaluator);
        hub.complete(jobId, "done");

        // Reputation unchanged — no auto-rating
        assertEq(_getReputation(serviceId), repBefore);
    }

    // ─── Test 5: Expired job, client gets refund ──────────────────────────────

    function test_expiredJob_clientRefunded() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + 1 days, "task", address(0), serviceId);
        vm.prank(client);
        hub.setBudget(jobId, BUDGET);

        uint256 clientBalBefore = usdc.balanceOf(client);
        vm.prank(client);
        hub.fund(jobId, BUDGET);
        assertEq(usdc.balanceOf(client), clientBalBefore - BUDGET);

        // Fast-forward past expiry
        vm.warp(block.timestamp + 2 days);
        hub.claimRefund(jobId);

        assertEq(usdc.balanceOf(client), clientBalBefore); // fully refunded
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Expired));
    }

    // ─── Test 6: Client self-evaluates (evaluator = client) ───────────────────

    function test_selfEvaluate_clientIsEvaluator() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(
            provider, client, // evaluator = client
            block.timestamp + DEADLINE, "task", address(0), serviceId
        );
        vm.prank(client);
        hub.setBudget(jobId, BUDGET);
        vm.prank(client);
        hub.fund(jobId, BUDGET);
        vm.prank(provider);
        hub.submit(jobId, "work");

        // Client evaluates their own job
        vm.prank(client);
        hub.complete(jobId, "satisfied");

        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Completed));
        assertGt(usdc.balanceOf(provider), 0);
    }

    // ─── Test 7: Multiple jobs compound reputation ────────────────────────────

    function test_multipleJobs_compoundReputation() public {
        uint256 rep = _getReputation(serviceId);
        assertEq(rep, 5000);

        // 3 good jobs → reputation rises
        for (uint256 i = 0; i < 3; i++) {
            address c = makeAddr(string.concat("client", vm.toString(i)));
            usdc.mint(c, BUDGET * 2);
            vm.prank(c);
            usdc.approve(address(hub), type(uint256).max);

            vm.prank(c);
            uint256 jobId = hub.createJob(provider, c, block.timestamp + DEADLINE, "task", address(0), serviceId);
            vm.prank(c);
            hub.setBudget(jobId, BUDGET);
            vm.prank(c);
            hub.fund(jobId, BUDGET);
            vm.prank(provider);
            hub.submit(jobId, "work");
            vm.prank(c);
            hub.complete(jobId, "good");

            // Advance time to avoid rate limits
            vm.warp(block.timestamp + 25 hours);
        }

        uint256 repAfter = _getReputation(serviceId);
        assertEq(repAfter, 5000 + 3 * 100); // +300 bps = 53%
    }

    // ─── Test 8: Protocol fee accumulation + withdrawal ───────────────────────

    function test_protocolFee_accumulates() public {
        // Run 3 jobs
        for (uint256 i = 0; i < 3; i++) {
            address c = makeAddr(string.concat("fc", vm.toString(i)));
            usdc.mint(c, BUDGET * 2);
            vm.prank(c);
            usdc.approve(address(hub), type(uint256).max);

            vm.prank(c);
            uint256 jobId = hub.createJob(provider, c, block.timestamp + DEADLINE, "task", address(0), type(uint256).max);
            vm.prank(c);
            hub.setBudget(jobId, BUDGET);
            vm.prank(c);
            hub.fund(jobId, BUDGET);
            vm.prank(provider);
            hub.submit(jobId, "work");
            vm.prank(c);
            hub.complete(jobId, "done");
        }

        uint256 expectedFees = (BUDGET * 100 / 10_000) * 3; // 1% of 3 jobs
        assertEq(hub.treasury(), expectedFees);

        // Owner withdraws
        vm.prank(owner);
        hub.withdrawFees(owner);
        assertEq(usdc.balanceOf(owner), expectedFees);
        assertEq(hub.treasury(), 0);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _getReputation(uint256 id) internal view returns (uint256) {
        (,,,,,, uint256 rep,,,,, ,) = registry.getService(id);
        return rep;
    }

    function _getStake(uint256 id) internal view returns (uint256) {
        (,,,,, uint256 stake,,,,,,, ) = registry.getService(id);
        return stake;
    }

    function _getSlashed(uint256 id) internal view returns (bool) {
        (,,,,,,,,,,,, bool slashed) = registry.getService(id);
        return slashed;
    }
}
