pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IERC5192 {
    function locked(uint256 tokenId) external view returns (bool);
}

contract JobRoll is Ownable, ERC721, IERC5192 {
    IERC20 private usdt;

    address private approvalAddress; // Address that can approve freelancers

    uint256 public withdrawFee;     // e.g. 50 = 0.5%
    uint256 public maxExpiry;       // max job duration in seconds
    uint256 constant FEE_DENOMINATOR = 10000;
    uint16 constant MAX_APPLICANTS = 50; // Max applicants per job

    uint256 public jobCounterId;

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
        bool isRegistered;             // True if the freelancer paid the registration fee
        bool isFreelancer;             // True if the platform approved the freelancer
        uint256 totalEarned;           // Total USDT earned from jobs
        uint256 completedJobs;         // Number of jobs successfully completed
        uint256 withdrawableBalance;   // Earnings that can be withdrawn
    }

    mapping(uint256 => bool) private _locked;
    mapping(uint256 => Job) public jobs;
    mapping(address => FreelancerInfo) public freelancers;
    mapping(uint256 => mapping(address => bool)) public hasApplied;

    event JobPosted(uint256 indexed jobId, address indexed client, uint256 amount, uint256 expiresAt);
    event JobCancelled(uint256 indexed jobId, uint256 refundedAmount);
    event WorkSubmitted(uint256 indexed jobId, address indexed freelancer);
    event JobApproved(uint256 indexed jobId, address indexed freelancer, uint256 reward);
    event Withdrawn(address indexed freelancer, uint256 netAmount, uint256 feeTaken);

    constructor(address _usdt) Ownable(_msgSender()) ERC721("Job Roll", "JOBROLL") {
        usdt = IERC20(_usdt);
        jobCounterId = 1; // Start job ID from 1
    }

    function locked(uint256 tokenId) external view override returns (bool) {
        return _locked[tokenId];
    }

    function registerAsFreelancer() external {
        address who = _msgSender();
        require(!freelancers[who].isRegistered, "Already registered");
        require(usdt.transferFrom(who, owner(), 1e6), "1 USDT fee required");

        freelancers[who].isRegistered = true;
    }

    function postJob(uint256 amount, uint256 expiresAt) external {
        address who = _msgSender();
        uint32 size;
        assembly {
            size := extcodesize(who)
        }
        require(size == 0, "Contract not allowed");
        require(amount >= 1e6, "Minimum 1 USDT");
        require(expiresAt > block.timestamp, "Invalid expiry");
        require(expiresAt <= block.timestamp + maxExpiry, "Exceeds max expiry");

        require(usdt.transferFrom(who, address(this), amount), "Transfer failed");

        uint256 newJobId = jobCounterId;
        jobs[newJobId] = Job({
            client: who,
            depositAmount: amount,
            expiresAt: expiresAt,
            active: true,
            cancelled: false,
            finished: false,
            selectedFreelancer: address(0),
            reward: 0,
            applicants: new address[](0)
        });

        // Mint soulbound NFT to client, tokenId = jobCounterId
        _safeMint(who, newJobId);
        _locked[newJobId] = true; // Lock the NFT

        jobCounterId++;

        emit JobPosted(newJobId, who, amount, expiresAt);
    }

    function cancelJob(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(_msgSender() == job.client, "Not job owner");
        require(job.active && !job.finished && !job.cancelled, "Job not cancellable");
        require(block.timestamp < job.expiresAt, "Job expired");

        job.active = false;
        job.cancelled = true;

        require(usdt.transfer(job.client, job.depositAmount), "Refund failed");

        // Burn the NFT when job is cancelled
        _burn(jobId);

        emit JobCancelled(jobId, job.depositAmount);
    }

    function submitWork(uint256 jobId) external {
        address who = _msgSender();
        Job storage job = jobs[jobId];
        require(freelancers[who].isFreelancer, "Not a registered freelancer");
        require(!hasApplied[jobId][who], "Already applied");
        require(job.active, "Inactive job");
        require(block.timestamp < job.expiresAt, "Job expired");
        require(job.applicants.length <= MAX_APPLICANTS, "Max applicants reached");

        hasApplied[jobId][who] = true;
        job.applicants.push(who);
        emit WorkSubmitted(jobId, who);
    }

    function approveWork(uint256 jobId, address freelancer) external {
        Job storage job = jobs[jobId];
        require(_msgSender() == job.client, "Not job owner");
        require(job.active && !job.finished && block.timestamp < job.expiresAt, "Job closed");

        require(hasApplied[jobId][freelancer], "Freelancer not applied");

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

    function claimUnfinishedJob(uint256 jobId) external {
        Job storage job = jobs[jobId];
        require(_msgSender() == job.client, "Not job owner");
        require(job.active && !job.finished && !job.cancelled, "Job not claimable");
        require(block.timestamp >= job.expiresAt, "Job not expired yet");

        job.active = false;
        job.cancelled = true;

        require(usdt.transfer(job.client, job.depositAmount), "Refund failed");
        _burn(jobId);

        emit JobCancelled(jobId, job.depositAmount);
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

    function transferFrom(address from, address to, uint256 tokenId) public override {
        require(!_locked[tokenId], "Soulbound: token is locked and non-transferable");
        super.transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override {
        require(!_locked[tokenId], "Soulbound: token is locked and non-transferable");
        super.safeTransferFrom(from, to, tokenId, data);
    }

    // === View Functions ===

    function getApplicants(uint256 jobId) external view returns (address[] memory) {
        return jobs[jobId].applicants;
    }

    function getActiveJobs(uint256 startId, uint256 endId) external view returns (uint256[] memory) {
        require(startId <= endId && endId <= jobCounterId, "Invalid range");
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
        require(startId <= endId && endId <= jobCounterId, "Invalid range");
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
        require(startId <= endId && endId <= jobCounterId, "Invalid range");
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
        require(_withdrawFee <= 500, "Too high"); // Max 5%
        withdrawFee = _withdrawFee;
    }

    function setMaxExpiry(uint256 secondsFromNow) external onlyOwner {
        require(secondsFromNow >= 1 days && secondsFromNow <= 90 days, "Invalid range");
        maxExpiry = secondsFromNow;
    }

    function recoverTokens(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(usdt), "Cannot recover user funds");
        IERC20(token).transfer(to, amount);
    }

    function updateApprovalAddress(address newApprovalAddress) external onlyOwner {
        require(newApprovalAddress != address(0), "Invalid address");
        approvalAddress = newApprovalAddress;
    }

    function approveFreelancer(address freelancer) external {
        require(_msgSender() == approvalAddress, "Not authorized");
        require(freelancers[freelancer].isRegistered, "Freelancer not registered");
        freelancers[freelancer].isFreelancer = true;
    }
}