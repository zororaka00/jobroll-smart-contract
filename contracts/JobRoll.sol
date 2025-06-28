pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract JobRoll is Ownable {
    IERC20 private usdt;

    uint256 public withdrawFee;     // e.g. 50 = 0.5%
    uint256 public maxExpiry;       // max job duration in seconds
    uint256 constant FEE_DENOMINATOR = 10000;

    uint256 public jobCounter;

    struct Job {
        address client;
        uint256 depositAmount;
        uint256 expiresAt;
        bool active;
        bool cancelled;
        bool finished;
        address selectedFreelancer;
        uint256 reward;
        address[] applicants;
    }

    struct FreelancerInfo {
        uint256 totalEarned;
        uint256 completedJobs;
        uint256 withdrawableBalance;
    }

    mapping(uint256 => Job) public jobs;
    mapping(address => FreelancerInfo) public freelancers;

    event JobPosted(uint256 indexed jobId, address indexed client, uint256 amount, uint256 expiresAt);
    event JobCancelled(uint256 indexed jobId, uint256 refundedAmount);
    event WorkSubmitted(uint256 indexed jobId, address indexed freelancer);
    event JobApproved(uint256 indexed jobId, address indexed freelancer, uint256 reward);
    event Withdrawn(address indexed freelancer, uint256 netAmount, uint256 feeTaken);

    constructor(address _usdt) Ownable(_msgSender()) {
        usdt = IERC20(_usdt);
        jobCounter = 1; // Start job ID from 1
    }

    function postJob(uint256 amount, uint256 expiresAt) external {
        require(amount >= 10e6, "Minimum 10 USDT");
        require(expiresAt > block.timestamp, "Invalid expiry");
        require(expiresAt <= block.timestamp + maxExpiry, "Exceeds max expiry");

        address who = _msgSender();
        require(usdt.transferFrom(who, address(this), amount), "Transfer failed");

        Job storage job = jobs[jobCounter];
        job.client = who;
        job.depositAmount = amount;
        job.expiresAt = expiresAt;
        job.active = true;
        jobCounter++;

        emit JobPosted(jobCounter, who, amount, expiresAt);
    }

    function cancelJob(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.client, "Not job owner");
        require(job.active && !job.finished && !job.cancelled, "Job not cancellable");

        job.active = false;
        job.cancelled = true;

        require(usdt.transfer(job.client, job.depositAmount), "Refund failed");

        emit JobCancelled(jobId, job.depositAmount);
    }

    function submitWork(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(job.active, "Inactive job");
        require(block.timestamp < job.expiresAt, "Job expired");

        job.applicants.push(msg.sender);
        emit WorkSubmitted(jobId, msg.sender);
    }

    function approveWork(uint256 jobId, address freelancer) external {
        Job storage job = jobs[jobId];
        require(msg.sender == job.client, "Not job owner");
        require(job.active && !job.finished, "Job closed");

        bool isApplicant = false;
        for (uint i = 0; i < job.applicants.length; i++) {
            if (job.applicants[i] == freelancer) {
                isApplicant = true;
                break;
            }
        }
        require(isApplicant, "Freelancer not applied");

        job.selectedFreelancer = freelancer;
        job.reward = job.depositAmount;
        job.finished = true;
        job.active = false;

        // Add to freelancer's balance
        freelancers[freelancer].totalEarned += job.reward;
        freelancers[freelancer].completedJobs += 1;
        freelancers[freelancer].withdrawableBalance += job.reward;

        emit JobApproved(jobId, freelancer, job.reward);
    }

    function withdraw() external {
        address who = _msgSender();
        uint256 amount = freelancers[who].withdrawableBalance;
        require(amount > 0, "No funds");

        uint256 fee = (amount * withdrawFee) / FEE_DENOMINATOR;
        uint256 finalAmount = amount - fee;

        freelancers[who].withdrawableBalance = 0;

        require(usdt.transfer(who, finalAmount), "Withdraw failed");

        emit Withdrawn(who, finalAmount, fee);
    }

    // === View Functions ===

    function getApplicants(uint256 jobId) external view returns (address[] memory) {
        return jobs[jobId].applicants;
    }

    function getActiveJobs(uint256 startId, uint256 endId) external view returns (uint256[] memory) {
        require(startId <= endId && endId <= jobCounter, "Invalid range");
        uint256 count;
        for (uint256 i = startId; i <= endId; i++) {
            if (jobs[i].active) count++;
        }

        uint256[] memory result = new uint256[](count);
        uint256 j;
        for (uint256 i = startId; i <= endId; i++) {
            if (jobs[i].active) {
                result[j] = i;
                j++;
            }
        }
        return result;
    }

    function getFinishedJobs(uint256 startId, uint256 endId) external view returns (uint256[] memory) {
        require(startId <= endId && endId <= jobCounter, "Invalid range");
        uint256 count;
        for (uint256 i = startId; i <= endId; i++) {
            if (jobs[i].finished) count++;
        }

        uint256[] memory result = new uint256[](count);
        uint256 j;
        for (uint256 i = startId; i <= endId; i++) {
            if (jobs[i].finished) {
                result[j] = i;
                j++;
            }
        }
        return result;
    }

    function getCancelledJobs(uint256 startId, uint256 endId) external view returns (uint256[] memory) {
        require(startId <= endId && endId <= jobCounter, "Invalid range");
        uint256 count;
        for (uint256 i = startId; i <= endId; i++) {
            if (jobs[i].cancelled) count++;
        }

        uint256[] memory result = new uint256[](count);
        uint256 j;
        for (uint256 i = startId; i <= endId; i++) {
            if (jobs[i].cancelled) {
                result[j] = i;
                j++;
            }
        }
        return result;
    }

    // === Admin Functions ===

    function setWithdrawFee(uint256 _withdrawFee) external onlyOwner {
        require(_withdrawFee <= 1000, "Too high"); // Max 10%
        withdrawFee = _withdrawFee;
    }

    function setMaxExpiry(uint256 secondsFromNow) external onlyOwner {
        require(secondsFromNow >= 1 days && secondsFromNow <= 90 days, "Invalid range");
        maxExpiry = secondsFromNow;
    }

    function recoverTokens(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}