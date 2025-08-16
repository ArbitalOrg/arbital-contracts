// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
contract ArbVault is ERC721, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    struct VestingChunk { uint40 unlockTime; uint16 weightBps; }
    struct Cohort {
        uint64  id; uint32  stakanId; uint128 threshold; uint128 collected; uint128 totalPrincipal;
        uint40  t0; uint40  ttl; bool active; int256 cumIndexX18; int256 realizedPnl; VestingChunk[] template;
    }
    struct Position {
        uint256 principalTotal; uint256 principalClaimed; int256 pnlIndexX18; int256 pnlNet;
        uint256 grossClaimed; uint256 feeClaimed; uint64 cohortId;
    }
    IERC20 public immutable asset; address public feeRecipient; uint16 public perfFeeBps;
    Counters.Counter private _idCounter; mapping(uint32 => uint64) public currentPendingCohortByStakan;
    mapping(uint64 => Cohort) public cohorts; mapping(uint256 => Position) public positions;
    event Deposited(address indexed user, uint256 indexed tokenId, uint64 indexed cohortId, uint256 amount);
    event CohortActivated(uint64 indexed cohortId, uint40 t0);
    event PrincipalTemplatePublished(uint64 indexed cohortId, bytes32 templateHash);
    event PrincipalUnlocked(uint256 indexed tokenId, uint256 amount);
    event PnLAccrued(uint64 indexed cohortId, int256 delta);
    event Claimed(address indexed user, uint256 indexed tokenId, uint256 principal, uint256 pnl, uint256 fee);
    constructor(address _asset, address _feeRecipient, uint16 _perfFeeBps, string memory name_, string memory symbol_)
        ERC721(name_, symbol_) {
        require(_asset != address(0) && _feeRecipient != address(0), "zero");
        require(_perfFeeBps <= 5000, "fee>50%");
        asset = IERC20(_asset); feeRecipient = _feeRecipient; perfFeeBps = _perfFeeBps;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    function deposit(uint256 amount, address beneficiary, uint32 stakanId) external whenNotPaused nonReentrant returns (uint256 tokenId) {
        require(amount > 0, "amount=0");
        if (beneficiary == address(0)) beneficiary = msg.sender;
        uint64 cohortId = currentPendingCohortByStakan[stakanId];
        if (cohortId == 0) { cohortId = _createPendingCohort(stakanId, 0, 0); }
        Cohort storage c = cohorts[cohortId]; require(!c.active, "cohort active");
        asset.safeTransferFrom(msg.sender, address(this), amount); c.collected += uint128(amount);
        tokenId = _mintPosition(beneficiary, cohortId, amount);
        emit Deposited(beneficiary, tokenId, cohortId, amount);
    }
    function cancelBeforeActivation(uint256 tokenId) external nonReentrant {
        Position storage p = positions[tokenId]; Cohort storage c = cohorts[p.cohortId];
        require(!c.active, "active"); require(ownerOf(tokenId) == msg.sender, "not owner");
        c.collected -= uint128(p.principalTotal); _burn(tokenId); asset.safeTransfer(msg.sender, p.principalTotal);
        delete positions[tokenId];
    }
    function activateCohort(uint64 cohortId) external onlyRole(EXECUTOR_ROLE) {
        Cohort storage c = cohorts[cohortId];
        require(!c.active, "already"); require(c.collected > 0 && c.collected >= c.threshold, "threshold");
        c.active = true; c.t0 = uint40(block.timestamp); c.totalPrincipal = c.collected;
        _buildAndStoreTemplate(c); if (currentPendingCohortByStakan[c.stakanId] == cohortId) { currentPendingCohortByStakan[c.stakanId] = 0; }
        emit CohortActivated(cohortId, c.t0); emit PrincipalTemplatePublished(cohortId, _templateHash(c));
    }
    function accruePnL(uint64 cohortId, int256 delta) external onlyRole(EXECUTOR_ROLE) {
        Cohort storage c = cohorts[cohortId]; require(c.active, "inactive cohort"); require(c.totalPrincipal > 0, "no principal");
        int256 inc = (delta * 1e18) / int256(uint256(c.totalPrincipal)); c.cumIndexX18 += inc; c.realizedPnl += delta; emit PnLAccrued(cohortId, delta);
    }
    function claimPrincipal(uint256 tokenId) public nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "not owner"); Position storage p = positions[tokenId]; Cohort storage c = cohorts[p.cohortId];
        require(c.active, "cohort not active");
        uint256 unlockedBps = _cohortUnlockedBps(c); uint256 unlockedTotal = (p.principalTotal * unlockedBps) / 10000;
        uint256 claimable = unlockedTotal - p.principalClaimed;
        if (claimable > 0) { p.principalClaimed += claimable; IERC20(asset).safeTransfer(msg.sender, claimable);
            emit PrincipalUnlocked(tokenId, claimable); emit Claimed(tokenId, tokenId, claimable, 0, 0); }
    }
    function claimPnL(uint256 tokenId) public nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "not owner"); Position storage p = positions[tokenId]; Cohort storage c = cohorts[p.cohortId];
        require(c.active, "cohort not active"); int256 deltaIndex = c.cumIndexX18 - p.pnlIndexX18;
        if (deltaIndex != 0) { int256 deltaPnl = (deltaIndex * int256(p.principalTotal)) / 1e18; p.pnlNet += deltaPnl; p.pnlIndexX18 = c.cumIndexX18; }
        uint256 positiveSoFar = p.pnlNet > 0 ? uint256(p.pnlNet) : 0; uint256 feeAccruedTotal = (positiveSoFar * perfFeeBps) / 10000;
        uint256 feeDelta = feeAccruedTotal > p.feeClaimed ? feeAccruedTotal - p.feeClaimed : 0; uint256 grossDelta = positiveSoFar > p.grossClaimed ? positiveSoFar - p.grossClaimed : 0;
        if (grossDelta == 0 && feeDelta == 0) return; uint256 userAmount = grossDelta > feeDelta ? (grossDelta - feeDelta) : 0;
        if (feeDelta > 0) { IERC20(asset).safeTransfer(feeRecipient, feeDelta); p.feeClaimed += feeDelta; }
        if (userAmount > 0) { IERC20(asset).safeTransfer(msg.sender, userAmount); }
        p.grossClaimed += grossDelta; emit Claimed(msg.sender, tokenId, 0, userAmount, feeDelta);
    }
    function exit(uint256 tokenId) external { claimPrincipal(tokenId); claimPnL(tokenId);
        Position storage p = positions[tokenId]; if (p.principalClaimed >= p.principalTotal) { require(ownerOf(tokenId) == msg.sender, "not owner"); _burn(tokenId); delete positions[tokenId]; } }
    function _mintPosition(address to, uint64 cohortId, uint256 amount) internal returns (uint256 tokenId) {
        tokenId = uint256(keccak256(abi.encodePacked(address(this), to, cohortId, block.timestamp, amount)));
        _safeMint(to, tokenId); positions[tokenId] = Position({ principalTotal: amount, principalClaimed: 0, pnlIndexX18: cohorts[cohortId].cumIndexX18,
            pnlNet: 0, grossClaimed: 0, feeClaimed: 0, cohortId: cohortId });
    }
    function _createPendingCohort(uint32 stakanId, uint128 threshold, uint40 ttl) internal returns (uint64 id) {
        id = uint64(uint256(keccak256(abi.encodePacked(block.chainid, stakanId, block.timestamp, address(this)))) & type(uint64).max);
        Cohort storage c = cohorts[id]; c.id = id; c.stakanId = stakanId; c.threshold = threshold; c.ttl = ttl; currentPendingCohortByStakan[stakanId] = id;
    }
    function _templateHash(Cohort storage c) internal view returns (bytes32) {
        bytes memory packed; for (uint256 i = 0; i < c.template.length; i++) { packed = abi.encodePacked(packed, c.template[i].unlockTime, c.template[i].weightBps); }
        return keccak256(packed);
    }
    function _buildAndStoreTemplate(Cohort storage c) internal {
        uint40[7] memory days_ = [uint40(3 days), 7 days, 12 days, 17 days, 24 days, 31 days, 38 days];
        uint16[7] memory w; uint256 seed = uint256(keccak256(abi.encodePacked(block.prevrandao, address(this), c.id))); uint256 sum;
        for (uint256 i = 0; i < 7; i++) { uint256 roll = uint256(keccak256(abi.encode(seed, i))) % 2100; uint16 weight = uint16(200 + (roll % 2301)); if (weight > 2500) weight = 2500; w[i] = weight; sum += weight; }
        for (uint256 i = 0; i < 7; i++) { w[i] = uint16((uint256(w[i]) * 10000) / sum); } int256 acc = 0; for (uint256 i = 0; i < 7; i++) acc += int256(uint256(w[i]));
        int256 diff = 10000 - acc; if (diff != 0) { w[0] = uint16(uint256(int256(uint256(w[0])) + diff)); }
        for (uint256 i = 0; i < 7; i++) { c.template.push(VestingChunk({unlockTime: c.t0 + days_[i], weightBps: w[i]})); }
    }
    function _cohortUnlockedBps(Cohort storage c) internal view returns (uint256 unlockedBps) {
        if (!c.active) return 0; for (uint256 i = 0; i < c.template.length; i++) { if (block.timestamp >= c.template[i].unlockTime) unlockedBps += c.template[i].weightBps; else break; }
        if (unlockedBps > 10000) unlockedBps = 10000;
    }
    function _beforeTokenTransfer(address from, address to, uint256 tokenId, uint256 batchSize) internal override {
        super._beforeTokenTransfer(from, to, tokenId, batchSize); if (from != address(0) && to != address(0)) { revert("SBT: non-transferable"); }
    }
}
