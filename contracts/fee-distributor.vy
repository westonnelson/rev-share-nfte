# @version 0.2.7
"""
@title Curve Fee Distribution
@author Curve Finance
@license MIT
"""
from vyper.interfaces import ERC20
interface VotingEscrow:
    def user_point_epoch(addr: address) -> uint256: view
    def epoch() -> uint256: view
    def user_point_history(addr: address, loc: uint256) -> Point: view
    def point_history(loc: uint256) -> Point: view
    def checkpoint(): nonpayable
interface WETH:
    def withdraw(wad: uint256): nonpayable
event SetEmergencyReturn:
    admin: address
event CommitAdmin:
    admin: address
event ApplyAdmin:
    admin: address
event ToggleAllowCheckpointToken:
    toggle_flag: bool
event CheckpointToken:
    time: uint256
    tokens: uint256
event Claimed:
    recipient: indexed(address)
    amount: uint256
    claim_epoch: uint256
    max_epoch: uint256
struct Point:
    bias: int128
    slope: int128  # - dweight / dt
    ts: uint256
    blk: uint256  # block
WEEK: constant(uint256) = 7 * 86400
TOKEN_CHECKPOINT_DEADLINE: constant(uint256) = 86400
start_time: public(uint256)
time_cursor: public(uint256)
time_cursor_of: public(HashMap[address, uint256])
user_epoch_of: public(HashMap[address, uint256])
last_token_time: public(uint256)
tokens_per_week: public(uint256[1000000000000000])
voting_escrow: public(address)
token: public(address)
total_received: public(uint256)
token_last_balance: public(uint256)
ve_supply: public(uint256[1000000000000000])  # VE total supply at week bounds
admin: public(address)
future_admin: public(address)
can_checkpoint_token: public(bool)
emergency_return: public(address)
is_killed: public(bool)
@external
def __init__(
    _voting_escrow: address,
    _start_time: uint256,
    _token: address,
    _admin: address,
    _emergency_return: address
):
    """
    @notice Contract constructor
    @param _voting_escrow VotingEscrow contract address
    @param _start_time Epoch time for fee distribution to start
    @param _token Fee token address (ETH)
    @param _admin Admin address
    @param _emergency_return Address to transfer `_token` balance to
                             if this contract is killed
    """
    t: uint256 = _start_time / WEEK * WEEK
    self.start_time = t
    self.last_token_time = t
    self.time_cursor = t
    self.token = _token
    self.voting_escrow = _voting_escrow
    self.admin = _admin
    self.emergency_return = _emergency_return
    self.can_checkpoint_token = True
@external
@payable
def __default__():
  return
@internal
def _checkpoint_token():
    token_balance: uint256 = self.balance
    to_distribute: uint256 = token_balance - self.token_last_balance
    self.token_last_balance = token_balance
    t: uint256 = self.last_token_time
    since_last: uint256 = block.timestamp - t
    self.last_token_time = block.timestamp
    this_week: uint256 = t / WEEK * WEEK
    next_week: uint256 = 0
    for i in range(20):
        next_week = this_week + WEEK
        if block.timestamp < next_week:
            if since_last == 0 and block.timestamp == t:
                self.tokens_per_week[this_week] += to_distribute
            else:
                self.tokens_per_week[this_week] += to_distribute * (block.timestamp - t) / since_last
            break
        else:
            if since_last == 0 and next_week == t:
                self.tokens_per_week[this_week] += to_distribute
            else:
                self.tokens_per_week[this_week] += to_distribute * (next_week - t) / since_last
        t = next_week
        this_week = next_week
    log CheckpointToken(block.timestamp, to_distribute)
@external
def checkpoint_token():
    """
    @notice Update the token checkpoint
    @dev Calculates the total number of tokens to be distributed in a given week.
         During setup for the initial distribution this function is only callable
         by the contract owner. Beyond initial distro, it can be enabled for anyone
         to call.
    """
    assert (msg.sender == self.admin) or\
           (self.can_checkpoint_token and (block.timestamp > self.last_token_time + TOKEN_CHECKPOINT_DEADLINE))
    self._checkpoint_token()
@internal
def _find_timestamp_epoch(ve: address, _timestamp: uint256) -> uint256:
    _min: uint256 = 0
    _max: uint256 = VotingEscrow(ve).epoch()
    for i in range(128):
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 2) / 2
        pt: Point = VotingEscrow(ve).point_history(_mid)
        if pt.ts <= _timestamp:
            _min = _mid
        else:
            _max = _mid - 1
    return _min
@view
@internal
def _find_timestamp_user_epoch(ve: address, user: address, _timestamp: uint256, max_user_epoch: uint256) -> uint256:
    _min: uint256 = 0
    _max: uint256 = max_user_epoch
    for i in range(128):
        if _min >= _max:
            break
        _mid: uint256 = (_min + _max + 2) / 2
        pt: Point = VotingEscrow(ve).user_point_history(user, _mid)
        if pt.ts <= _timestamp:
            _min = _mid
        else:
            _max = _mid - 1
    return _min
@view
@external
def ve_for_at(_user: address, _timestamp: uint256) -> uint256:
    """
    @notice Get the veCRV balance for `_user` at `_timestamp`
    @param _user Address to query balance for
    @param _timestamp Epoch time
    @return uint256 veCRV balance
    """
    ve: address = self.voting_escrow
    max_user_epoch: uint256 = VotingEscrow(ve).user_point_epoch(_user)
    epoch: uint256 = self._find_timestamp_user_epoch(ve, _user, _timestamp, max_user_epoch)
    pt: Point = VotingEscrow(ve).user_point_history(_user, epoch)
    return convert(max(pt.bias - pt.slope * convert(_timestamp - pt.ts, int128), 0), uint256)
@internal
def _checkpoint_total_supply():
    ve: address = self.voting_escrow
    t: uint256 = self.time_cursor
    rounded_timestamp: uint256 = block.timestamp / WEEK * WEEK
    VotingEscrow(ve).checkpoint()
    for i in range(20):
        if t > rounded_timestamp:
            break
        else:
            epoch: uint256 = self._find_timestamp_epoch(ve, t)
            pt: Point = VotingEscrow(ve).point_history(epoch)
            dt: int128 = 0
            if t > pt.ts:
                # If the point is at 0 epoch, it can actually be earlier than the first deposit
                # Then make dt 0
                dt = convert(t - pt.ts, int128)
            self.ve_supply[t] = convert(max(pt.bias - pt.slope * dt, 0), uint256)
        t += WEEK
    self.time_cursor = t
@external
def checkpoint_total_supply():