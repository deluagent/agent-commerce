// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AgentCommerceHub.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

// Mock ServiceRegistry — records ratings
contract MockRegistry {
    struct Rating { uint256 serviceId; uint8 score; string comment; }
    Rating[] public ratings;

    function rateService(uint256 serviceId, uint8 score, string calldata comment) external {
        ratings.push(Rating(serviceId, score, comment));
    }
    function getService(uint256) external pure returns (
        address, string memory, string memory, uint256, uint8, uint256,
        uint256, uint256, uint256, uint256, uint256, bool, bool
    ) {
        return (address(0),"","",0,0,0,5000,0,0,0,0,true,false);
    }
    function ratingCount() external view returns (uint256) { return ratings.length; }
    function lastRating() external view returns (Rating memory) { return ratings[ratings.length - 1]; }
}

contract AgentCommerceHubTest is Test {
    AgentCommerceHub public hub;
    MockUSDC         public usdc;
    MockRegistry     public registry;

    address owner     = makeAddr("owner");
    address client    = makeAddr("client");
    address provider  = makeAddr("provider");
    address evaluator = makeAddr("evaluator");

    uint256 constant BUDGET   = 10_000_000; // 10 USDC (6 decimals)
    uint256 constant DEADLINE = 1 days;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new MockRegistry();
        hub = new AgentCommerceHub(owner, address(usdc), address(registry));

        usdc.mint(client, 100_000_000); // 100 USDC
        vm.prank(client);
        usdc.approve(address(hub), type(uint256).max);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _createAndFund() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "do x for me", address(0), type(uint256).max);

        vm.prank(client);
        hub.setBudget(jobId, BUDGET);

        vm.prank(client);
        hub.fund(jobId, BUDGET);
    }

    // ─── createJob ────────────────────────────────────────────────────────────

    function test_createJob_basic() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "job desc", address(0), type(uint256).max);

        AgentCommerceHub.Job memory job = hub.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.provider, provider);
        assertEq(job.evaluator, evaluator);
        assertEq(uint8(job.status), uint8(AgentCommerceHub.Status.Open));
        assertEq(hub.jobCount(), 1);
    }

    function test_createJob_noProvider() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(address(0), evaluator, block.timestamp + DEADLINE, "open job", address(0), type(uint256).max);
        assertEq(hub.getJob(jobId).provider, address(0));
    }

    function test_createJob_revertZeroEvaluator() public {
        vm.prank(client);
        vm.expectRevert(AgentCommerceHub.ZeroAddress.selector);
        hub.createJob(provider, address(0), block.timestamp + DEADLINE, "desc", address(0), type(uint256).max);
    }

    function test_createJob_revertExpiredDeadline() public {
        vm.prank(client);
        vm.expectRevert(AgentCommerceHub.AlreadyExpired.selector);
        hub.createJob(provider, evaluator, block.timestamp - 1, "desc", address(0), type(uint256).max);
    }

    // ─── setProvider ──────────────────────────────────────────────────────────

    function test_setProvider() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(address(0), evaluator, block.timestamp + DEADLINE, "desc", address(0), type(uint256).max);

        vm.prank(client);
        hub.setProvider(jobId, provider);
        assertEq(hub.getJob(jobId).provider, provider);
    }

    function test_setProvider_revertNonClient() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(address(0), evaluator, block.timestamp + DEADLINE, "desc", address(0), type(uint256).max);

        vm.prank(provider);
        vm.expectRevert(AgentCommerceHub.Unauthorized.selector);
        hub.setProvider(jobId, provider);
    }

    // ─── setBudget ────────────────────────────────────────────────────────────

    function test_setBudget_byClient() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "desc", address(0), type(uint256).max);
        vm.prank(client);
        hub.setBudget(jobId, BUDGET);
        assertEq(hub.getJob(jobId).budget, BUDGET);
    }

    function test_setBudget_byProvider() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "desc", address(0), type(uint256).max);
        vm.prank(provider);
        hub.setBudget(jobId, BUDGET);
        assertEq(hub.getJob(jobId).budget, BUDGET);
    }

    // ─── fund ─────────────────────────────────────────────────────────────────

    function test_fund_success() public {
        uint256 jobId = _createAndFund();
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Funded));
        assertEq(usdc.balanceOf(address(hub)), BUDGET);
    }

    function test_fund_revertBudgetMismatch() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "desc", address(0), type(uint256).max);
        vm.prank(client);
        hub.setBudget(jobId, BUDGET);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(AgentCommerceHub.BudgetMismatch.selector, BUDGET, BUDGET + 1));
        hub.fund(jobId, BUDGET + 1);
    }

    // ─── submit ───────────────────────────────────────────────────────────────

    function test_submit_success() public {
        uint256 jobId = _createAndFund();

        vm.prank(provider);
        hub.submit(jobId, "ipfs://QmDeliverable");

        AgentCommerceHub.Job memory job = hub.getJob(jobId);
        assertEq(uint8(job.status), uint8(AgentCommerceHub.Status.Submitted));
        assertEq(job.deliverable, "ipfs://QmDeliverable");
    }

    function test_submit_revertNonProvider() public {
        uint256 jobId = _createAndFund();
        vm.prank(client);
        vm.expectRevert(AgentCommerceHub.Unauthorized.selector);
        hub.submit(jobId, "ipfs://fake");
    }

    // ─── complete ─────────────────────────────────────────────────────────────

    function test_complete_releasesPayment() public {
        uint256 jobId = _createAndFund();

        vm.prank(provider);
        hub.submit(jobId, "deliverable");

        uint256 providerBalBefore = usdc.balanceOf(provider);

        vm.prank(evaluator);
        hub.complete(jobId, "looks good");

        uint256 fee = (BUDGET * 100) / 10_000; // 1%
        uint256 expectedPayment = BUDGET - fee;

        assertEq(usdc.balanceOf(provider), providerBalBefore + expectedPayment);
        assertEq(hub.treasury(), fee);
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Completed));
    }

    function test_complete_revertNonEvaluator() public {
        uint256 jobId = _createAndFund();
        vm.prank(provider);
        hub.submit(jobId, "work");

        vm.prank(client);
        vm.expectRevert(AgentCommerceHub.Unauthorized.selector);
        hub.complete(jobId, "");
    }

    // ─── reject ───────────────────────────────────────────────────────────────

    function test_reject_fundedRefundsClient() public {
        uint256 jobId = _createAndFund();
        uint256 clientBalBefore = usdc.balanceOf(client);

        vm.prank(evaluator);
        hub.reject(jobId, "not satisfied");

        assertEq(usdc.balanceOf(client), clientBalBefore + BUDGET);
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Rejected));
    }

    function test_reject_submittedRefundsClient() public {
        uint256 jobId = _createAndFund();
        vm.prank(provider);
        hub.submit(jobId, "partial work");

        uint256 clientBalBefore = usdc.balanceOf(client);
        vm.prank(evaluator);
        hub.reject(jobId, "incomplete");

        assertEq(usdc.balanceOf(client), clientBalBefore + BUDGET);
    }

    function test_reject_openByClient() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "desc", address(0), type(uint256).max);
        vm.prank(client);
        hub.reject(jobId, "changed mind");
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Rejected));
    }

    // ─── claimRefund ──────────────────────────────────────────────────────────

    function test_claimRefund_afterExpiry() public {
        uint256 jobId = _createAndFund();
        uint256 clientBalBefore = usdc.balanceOf(client);

        vm.warp(block.timestamp + DEADLINE + 1);
        hub.claimRefund(jobId);

        assertEq(usdc.balanceOf(client), clientBalBefore + BUDGET);
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Expired));
    }

    function test_claimRefund_revertBeforeExpiry() public {
        uint256 jobId = _createAndFund();
        vm.expectRevert(AgentCommerceHub.NotExpired.selector);
        hub.claimRefund(jobId);
    }

    // ─── ServiceRegistry auto-rating ──────────────────────────────────────────

    function test_autoRate_onComplete() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "do x", address(0), 1); // serviceId=1

        vm.prank(client);
        hub.setBudget(jobId, BUDGET);
        vm.prank(client);
        hub.fund(jobId, BUDGET);
        vm.prank(provider);
        hub.submit(jobId, "deliverable");
        vm.prank(evaluator);
        hub.complete(jobId, "great work");

        assertEq(registry.ratingCount(), 1);
        MockRegistry.Rating memory r = registry.lastRating();
        assertEq(r.serviceId, 1);
        assertEq(r.score, 5);
    }

    function test_autoRate_onReject() public {
        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "do x", address(0), 1);

        vm.prank(client);
        hub.setBudget(jobId, BUDGET);
        vm.prank(client);
        hub.fund(jobId, BUDGET);
        vm.prank(provider);
        hub.submit(jobId, "bad work");
        vm.prank(evaluator);
        hub.reject(jobId, "terrible");

        assertEq(registry.ratingCount(), 1);
        assertEq(registry.lastRating().score, 1); // bad: provider submitted but got rejected
    }

    function test_noAutoRate_whenNotLinked() public {
        uint256 jobId = _createAndFund(); // serviceId not linked (uses type(uint256).max)
        vm.prank(provider);
        hub.submit(jobId, "work");
        vm.prank(evaluator);
        hub.complete(jobId, "done");

        assertEq(registry.ratingCount(), 0);
    }

    // ─── Fee management ───────────────────────────────────────────────────────

    function test_setFee() public {
        vm.prank(owner);
        hub.setFee(200); // 2%
        assertEq(hub.feeBps(), 200);
    }

    function test_setFee_revertTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(AgentCommerceHub.FeeTooHigh.selector);
        hub.setFee(1001);
    }

    function test_withdrawFees() public {
        // Complete a job to accumulate fees
        uint256 jobId = _createAndFund();
        vm.prank(provider);
        hub.submit(jobId, "work");
        vm.prank(evaluator);
        hub.complete(jobId, "done");

        uint256 fee = hub.treasury();
        assertTrue(fee > 0);

        vm.prank(owner);
        hub.withdrawFees(owner);

        assertEq(hub.treasury(), 0);
        assertEq(usdc.balanceOf(owner), fee);
    }

    // ─── Full end-to-end flow ─────────────────────────────────────────────────

    function test_fullFlow_openToCompleted() public {
        // 1. Client creates job
        vm.prank(client);
        uint256 jobId = hub.createJob(address(0), evaluator, block.timestamp + 7 days, "Write a smart contract", address(0), 2);

        // 2. Provider bids
        vm.prank(client);
        hub.setProvider(jobId, provider);

        // 3. Negotiate budget
        vm.prank(provider);
        hub.setBudget(jobId, BUDGET);

        // 4. Client funds
        vm.prank(client);
        hub.fund(jobId, BUDGET);
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Funded));

        // 5. Provider submits
        vm.prank(provider);
        hub.submit(jobId, "github.com/provider/contract-v1");
        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Submitted));

        // 6. Evaluator completes
        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(evaluator);
        hub.complete(jobId, "contract passes all tests");

        assertEq(uint8(hub.getJob(jobId).status), uint8(AgentCommerceHub.Status.Completed));
        assertTrue(usdc.balanceOf(provider) > providerBefore);

        // 7. Registry auto-rated (serviceId=2 → score=5)
        assertEq(registry.ratingCount(), 1);
        assertEq(registry.lastRating().score, 5);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_budgetAndFee(uint256 budget) public {
        budget = bound(budget, 1, 1_000_000 * 1e6); // 1 unit to 1M USDC
        usdc.mint(client, budget);

        vm.prank(client);
        uint256 jobId = hub.createJob(provider, evaluator, block.timestamp + DEADLINE, "fuzz", address(0), type(uint256).max);
        vm.prank(client);
        hub.setBudget(jobId, budget);
        vm.prank(client);
        hub.fund(jobId, budget);
        vm.prank(provider);
        hub.submit(jobId, "work");

        uint256 providerBefore = usdc.balanceOf(provider);
        vm.prank(evaluator);
        hub.complete(jobId, "ok");

        uint256 fee = (budget * 100) / 10_000;
        uint256 expectedPayment = budget - fee;
        assertEq(usdc.balanceOf(provider), providerBefore + expectedPayment);
        assertEq(hub.treasury(), fee);
    }
}
