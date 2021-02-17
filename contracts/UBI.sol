// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20SnapshotUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./Humanity.sol";


contract UBI is ForHumans, Initializable, ERC20BurnableUpgradeable, ERC20SnapshotUpgradeable {

  using SafeMath for uint256;

  struct AccruePolicy {
    uint256 accruedPerSecond;
    uint64 validFrom;
    uint64 validTo;
  }

  /* Events */

  /** @dev Emitted when UBI is minted or taken by a reporter.
    *  @param _recipient The accruer of the UBI.
    *  @param _beneficiary The withdrawer or taker.
    *  @param _value The value withdrawn.
    */
  event Mint(
      address indexed _recipient,
      address indexed _beneficiary,
      uint256 _value
  );

  /* Storage */

  /// @dev The contract's governor.
  address public governor;

  /// @dev Persists time of last minted tokens for any given address. accruePolicies[policyID]
  mapping(uint256 => AccruePolicy) public accruePolicies;

  /// @dev Persists time of last minted tokens for any given address.
  mapping(address => uint256) public accruedSince;

  /// @dev Persists time of last minted tokens for any given address. lastAccrued[human][policy]
  mapping(address => mapping(uint256 => uint256)) public lastAccrued;

  /* Modifiers */

  /// @dev Verifies sender has ability to modify governed parameters.
  modifier onlyByGovernor() {
    require(governor == msg.sender, "The caller is not the governor.");
    _;
  }

  /** @dev is already accruing token subsidy
  *  @param human for the address of the human.
  *  @param _accruing if its actively accruing value.
  */
  modifier isAccruing(address human, bool _accruing) {
    bool accruing = accruedSince[human] != 0;
    require(
      accruing == _accruing,
      accruing
        ? "The submission is already accruing UBI."
        : "The submission is not accruing UBI."
    );
    _;
  }

  /* Initalizer */

  /** @dev Constructor.
  *  @param _initialSupply for the UBI coin including all decimals.
  *  @param _name for UBI coin.
  *  @param _symbol for UBI coin ticker.
  *  @param _accruedPerSecond How much of the token is accrued per block.
  *  @param _proofOfHumanity The Proof Of Humanity registry to reference.
  */
  function initialize(uint256 _initialSupply, string memory _name, string memory _symbol, uint256 _accruedPerSecond, IProofOfHumanity _proofOfHumanity) public initializer {
    __Context_init_unchained();
    __ERC20_init_unchained(_name, _symbol);

    accruedPerSecond = _accruedPerSecond;
    proofOfHumanity = _proofOfHumanity;
    governor = msg.sender;

    _mint(msg.sender, _initialSupply);
  }

  /* External */

  function addPolicy(uint256 policyID, uint256 accruedPerSecond, uint256 validFrom, uint256 validTo) external onlyByGovernor() {
    AccruePolicy storage policy = accruePolicies[policyID];
    require(policy.accruedPerSecond == 0, "Policy already set.");
    require(validFrom < validTo, "Invalid parameters.");

    policy.accruedPerSecond = accruedPerSecond;
    policy.validFrom = validFrom;
    policy.validTo = validTo;
  }

  function finalizePolicy(uint256 policyID) external onlyByGovernor() {
    AccruePolicy storage policy = accruePolicies[policyID];
    require(policy.accruedPerSecond != 0, "Invalid policy.");
    require(policy.validTo > block.timestamp, "Invalid policy.");
    policy.validTo = block.timestamp;
  }

  /** @dev Universal Basic Income mechanism
  *  @param human The submission ID.
  *  @param policyID The accruing policy ID.
  */
  function mintAccrued(address human, uint256 policyID) external isRegistered(human, true) isAccruing(human, true) {
    uint256 newSupply = getAccruedValue(human, policyID);

    lastAccrued[human][policyID] = block.timestamp;

    _mint(human, newSupply);

    emit Mint(human, human, newSupply);
  }

  /** @dev Starts accruing UBI for a registered submission.
  *  @param human The submission ID.
  */
  function startAccruing(address human) external isRegistered(human, true) isAccruing(human, false) {
    accruedSince[human] = block.timestamp;
  }

  /** @dev Allows anyone to report a submission that
  *  should no longer receive UBI due to removal from the
  *  Proof Of Humanity registry. The reporter receives any
  *  leftover accrued UBI.
  *  @param human The submission ID.
  */
  function reportRemoval(address human, uint256[] calldata policyIDs) external isAccruing(human, true) isRegistered(human, false) {
    uint256 newSupply;
    for (uint256 i; i < policyIDs.length; i++)
     newSupply += getAccruedValue(human, policyIDs[i]);

    accruedSince[human] = 0;

    _mint(msg.sender, newSupply);

    emit Mint(human, msg.sender, newSupply);
  }

  /** @dev Changes `accruedPerSecond` to `_accruedPerSecond`.
  *  @param _accruedPerSecond How much of the token is accrued per block.
  */
  function changeAccruedPerSecond(uint256 _accruedPerSecond) external onlyByGovernor {
    accruedPerSecond = _accruedPerSecond;
  }

  /** @dev Changes `proofOfHumanity` to `_proofOfHumanity`.
  *  @param _proofOfHumanity Registry that meets interface of Proof of Humanity
  */
  function changeProofOfHumanity(IProofOfHumanity _proofOfHumanity) external onlyByGovernor {
    proofOfHumanity = _proofOfHumanity;
  }

  /** @dev External function for Snapshot event emitter only accessible by governor.  */
  function snapshot() external onlyByGovernor returns(uint256) {
    return _snapshot();
  }

  /* Getters */

  /** @dev Calculates how much UBI a submission has available for withdrawal.
  *  @param human The submission ID.
  *  @param policyID The accruing policy ID.
  *  @return accrued The available UBI for withdrawal.
  */
  function getAccruedValue(address human, uint256 policyID) public view returns (uint256 accrued) {
    // If this human have not started to accrue, return 0.
    if (accruedSince[human] == 0) return 0;

    AccruePolicy storage policy = accruePolicies[policyID];

    uint256 _lastAccrued = lastAccrued[human][policyID];
    if (lastAccrued == 0) {
      _lastAccrued = accruedSince[human] > policy.validFrom ? accruedSince[human] : policy.validFrom;
    }
    uint256 _accrueUntil = block.timestamp <= policy.validTo ? block.timestamp : policy.validTo; 

    if (_accrueUntil < _lastAccrued)
      return 0;
    else
      return (_accrueUntil - _lastAccrued) * policy.accruedPerSecond;
  }

  /** Overrides */

  /** @dev Overrides with Snapshot mechanisms _beforeTokenTransfer functions.  */
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override(ERC20Upgradeable, ERC20SnapshotUpgradeable) {
    ERC20SnapshotUpgradeable._beforeTokenTransfer(from, to, amount);
  }
}
