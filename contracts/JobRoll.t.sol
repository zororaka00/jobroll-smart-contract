// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { JobRoll } from "./JobRoll.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock USDT token for testing
contract MockUSDT is IERC20 {
    string public constant name = "MockUSDT";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract JobRollTest is Test {
    JobRoll jobroll;
    MockUSDT usdt;
    address client = address(0x1);
    address freelancer = address(0x2);

    function setUp() public {
        usdt = new MockUSDT();
        jobroll = new JobRoll(address(usdt));
        jobroll.setMaxExpiry(30 days);

        // Mint USDT to client
        usdt.mint(client, 1000e6);
        vm.prank(client);
        usdt.approve(address(jobroll), 1000e6);
    }

    function test_PostJob() public {
        uint256 amount = 10e6;
        uint256 expiresAt = block.timestamp + 1 days;

        vm.prank(client);
        jobroll.postJob(amount, expiresAt);

        (address jobClient, uint256 depositAmount,, bool active,,,,) = jobroll.jobs(1);
        assertEq(jobClient, client, "Client mismatch");
        assertEq(depositAmount, amount, "Deposit mismatch");
        assertTrue(active, "Job should be active");
        assertEq(jobroll.ownerOf(1), client, "NFT not minted to client");
    }

    function test_CancelJob() public {
        uint256 amount = 10e6;
        uint256 expiresAt = block.timestamp + 1 days;

        vm.startPrank(client);
        jobroll.postJob(amount, expiresAt);
        jobroll.cancelJob(1);
        vm.stopPrank();

        (, , , bool active, bool cancelled,,,) = jobroll.jobs(1);
        assertTrue(cancelled, "Should be cancelled");
        assertFalse(active, "Should not be active");
        // NFT should be burned, so ownerOf(1) should revert
        vm.expectRevert();
        jobroll.ownerOf(1);
    }

    function test_SubmitAndApproveWork() public {
        uint256 amount = 10e6;
        uint256 expiresAt = block.timestamp + 1 days;

        vm.prank(client);
        jobroll.postJob(amount, expiresAt);

        vm.prank(freelancer);
        jobroll.submitWork(1);

        address[] memory applicants = jobroll.getApplicants(1);
        assertEq(applicants.length, 1, "Should have 1 applicant");
        assertEq(applicants[0], freelancer, "Applicant mismatch");

        vm.prank(client);
        jobroll.approveWork(1, freelancer);

        (,,,,, bool finished, address selectedFreelancer, uint256 reward) = jobroll.jobs(1);
        assertTrue(finished, "Job should be finished");
        assertEq(selectedFreelancer, freelancer, "Freelancer mismatch");
        assertEq(reward, amount, "Reward mismatch");

        (uint256 totalEarned, uint256 completedJobs, uint256 withdrawableBalance) = jobroll.freelancers(freelancer);
        assertEq(totalEarned, amount, "Total earned mismatch");
        assertEq(completedJobs, 1, "Completed jobs mismatch");
        assertEq(withdrawableBalance, amount, "Withdrawable mismatch");
    }

    function test_Withdraw() public {
        uint256 amount = 10e6;
        uint256 expiresAt = block.timestamp + 1 days;

        // Set fee to 1%
        jobroll.setWithdrawFee(100);

        vm.prank(client);
        jobroll.postJob(amount, expiresAt);

        vm.prank(freelancer);
        jobroll.submitWork(1);

        vm.prank(client);
        jobroll.approveWork(1, freelancer);

        uint256 prevBalance = usdt.balanceOf(freelancer);

        vm.prank(freelancer);
        jobroll.withdraw();

        uint256 fee = amount / 100; // 1%
        uint256 expected = amount - fee;
        uint256 afterBalance = usdt.balanceOf(freelancer);

        assertEq(afterBalance - prevBalance, expected, "Withdraw amount mismatch");
        (,,uint256 withdrawableBalance) = jobroll.freelancers(freelancer);
        assertEq(withdrawableBalance, 0, "Withdrawable should be 0");
    }

    function test_SoulboundNFT() public {
        uint256 amount = 10e6;
        uint256 expiresAt = block.timestamp + 1 days;

        vm.prank(client);
        jobroll.postJob(amount, expiresAt);

        // Try to transfer NFT, should revert
        vm.expectRevert();
        vm.prank(client);
        jobroll.transferFrom(client, freelancer, 1);
    }
}
