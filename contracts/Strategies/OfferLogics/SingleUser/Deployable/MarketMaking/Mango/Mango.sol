// SPDX-License-Identifier:	BSD-2-Clause

// Mango.sol

// Copyright (c) 2021 Giry SAS. All rights reserved.

// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

// 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
pragma solidity ^0.8.10;
pragma abicoder v2;
import "./MangoStorage.sol";
import "./MangoImplementation.sol";
import "../../../Persistent.sol";
import "../Sourcers/EOASourcer.sol";

/** Discrete automated market making strat */
/** This AMM is headless (no price model) and market makes on `NSLOTS` price ranges*/
/** current `Pmin` is the price of an offer at position `0`, current `Pmax` is the price of an offer at position `NSLOTS-1`*/
/** Initially `Pmin = P(0) = QUOTE_0/BASE_0` and the general term is P(i) = __quote_progression__(i)/BASE_0 */
/** NB `__quote_progression__` is a hook that defines how price increases with positions and is by default an arithmetic progression, i.e __quote_progression__(i) = QUOTE_0 + `delta`*i */
/** When one of its offer is matched on Mangrove, the headless strat does the following: */
/** Each time this strat receives b `BASE` tokens (bid was taken) at price position i, it increases the offered (`BASE`) volume of the ask at position i+1 of 'b'*/
/** Each time this strat receives q `QUOTE` tokens (ask was taken) at price position i, it increases the offered (`QUOTE`) volume of the bid at position i-1 of 'q'*/
/** In case of a partial fill of an offer at position i, the offer residual is reposted (see `Persistent` strat class)*/

contract Mango is Persistent {
  using P.Offer for P.Offer.t;
  using P.OfferDetail for P.OfferDetail.t;

  // emitted when init function has been called and AMM becomes active
  event Initialized(uint from, uint to);
  event SetLiquiditySourcer(ISourcer);

  address private immutable IMPLEMENTATION;

  uint public immutable NSLOTS;
  IEIP20 public immutable BASE;
  IEIP20 public immutable QUOTE;

  // Asks and bids offer Ids are stored in `ASKS` and `BIDS` arrays respectively.

  constructor(
    IMangrove mgv,
    IEIP20 base,
    IEIP20 quote,
    uint base_0,
    uint quote_0,
    uint nslots,
    uint price_incr,
    address deployer
  ) MangroveOffer(mgv, deployer) {
    MangoStorage.Layout storage mStr = MangoStorage.get_storage();
    // sanity check
    require(
      nslots > 0 &&
        address(mgv) != address(0) &&
        uint16(nslots) == nslots &&
        uint96(base_0) == base_0 &&
        uint96(quote_0) == quote_0,
      "Mango/constructor/invalidArguments"
    );
    // require(
    //   address(liquidity_sourcer) != address(0),
    //   "Mango/constructor/0xLiquiditySource"
    // );
    NSLOTS = nslots;

    // implementation should have correct immutables
    IMPLEMENTATION = address(
      new MangoImplementation(
        mgv,
        base,
        quote,
        uint96(base_0),
        uint96(quote_0),
        nslots
      )
    );
    BASE = base;
    QUOTE = quote;
    // setting local storage
    mStr.asks = new uint[](nslots);
    mStr.bids = new uint[](nslots);
    mStr.delta = price_incr;
    // logs `BID/ASKatMin/MaxPosition` events when only 1 slot remains
    mStr.min_buffer = 1;

    // setting inherited storage
    setGasreq(400_000); // dry run OK with 200_000
    // approve Mangrove to pull funds during trade in order to pay takers
    approveMangrove(quote, type(uint).max);
    approveMangrove(base, type(uint).max);
  }

  // populate mangrove order book with bids or/and asks in the price range R = [`from`, `to`[
  // tokenAmounts are always expressed `gives`units, i.e in BASE when asking and in QUOTE when bidding
  function initialize(
    uint lastBidPosition, // if `lastBidPosition` is in R, then all offers before `lastBidPosition` (included) will be bids, offers strictly after will be asks.
    uint from, // first price position to be populated
    uint to, // last price position to be populated
    uint[][2] calldata pivotIds, // `pivotIds[0][i]` ith pivots for bids, `pivotIds[1][i]` ith pivot for asks
    uint[] calldata tokenAmounts // `tokenAmounts[i]` is the amount of `BASE` or `QUOTE` tokens (dePENDING on `withBase` flag) that is used to fixed one parameter of the price at position `from+i`.
  ) public mgvOrAdmin {
    (bool success, bytes memory retdata) = IMPLEMENTATION.delegatecall(
      abi.encodeWithSelector(
        MangoImplementation.$initialize.selector,
        lastBidPosition,
        from,
        to,
        pivotIds,
        tokenAmounts
      )
    );
    if (!success) {
      MangoStorage.revertWithData(retdata);
    } else {
      emit Initialized({from: from, to: to});
    }
  }

  /** Sets the account from which base (resp. quote) tokens need to be fetched or put during trade execution*/
  /** */
  /** NB Sourcer might need further approval to work as intended*/
  function set_liquidity_sourcer(ISourcer sourcer, uint gasreq)
    external
    onlyAdmin
  {
    MangoStorage.get_storage().liquidity_sourcer = sourcer;
    BASE.approve(address(sourcer), type(uint).max);
    QUOTE.approve(address(sourcer), type(uint).max);
    setGasreq(gasreq);
    emit SetLiquiditySourcer(sourcer);
  }

  function set_EOA_sourcer() external onlyAdmin {
    MangoStorage.Layout storage mStr = MangoStorage.get_storage();
    mStr.liquidity_sourcer = new EOASourcer(address(this), admin());
    BASE.approve(address(mStr.liquidity_sourcer), type(uint).max);
    QUOTE.approve(address(mStr.liquidity_sourcer), type(uint).max);
    emit SetLiquiditySourcer(mStr.liquidity_sourcer);
  }

  function liquidity_sourcer() public view returns (ISourcer) {
    return MangoStorage.get_storage().liquidity_sourcer;
  }

  function reset_pending() external onlyAdmin {
    MangoStorage.Layout storage mStr = MangoStorage.get_storage();
    mStr.pending_base = 0;
    mStr.pending_quote = 0;
  }

  /** Setters and getters */
  function delta() external view onlyAdmin returns (uint) {
    return MangoStorage.get_storage().delta;
  }

  function set_delta(uint _delta) public mgvOrAdmin {
    MangoStorage.get_storage().delta = _delta;
  }

  function shift() external view onlyAdmin returns (int) {
    return MangoStorage.get_storage().shift;
  }

  function pending() external view onlyAdmin returns (uint[2] memory) {
    MangoStorage.Layout storage mStr = MangoStorage.get_storage();
    return [mStr.pending_base, mStr.pending_quote];
  }

  /** __put__ is default SingleUser.__put__*/

  /** Fetches required tokens from the corresponding source*/
  function __get__(uint amount, ML.SingleOrder calldata order)
    internal
    virtual
    override
    returns (uint)
  {
    // pulled might be lower or higher than amount
    uint pulled = MangoStorage.get_storage().liquidity_sourcer.pull(
      IEIP20(order.outbound_tkn),
      amount
    );
    if (pulled > amount) {
      return 0; //nothing is missing
    } else {
      // still needs to get liquidity using `SingleUser.__get__()`
      return super.__get__(amount - pulled, order);
    }
  }

  // with ba=0:bids only, ba=1: asks only ba>1 all
  function retractOffers(
    uint ba,
    uint from,
    uint to
  ) external onlyAdmin returns (uint collected) {
    (bool success, bytes memory retdata) = IMPLEMENTATION.delegatecall(
      abi.encodeWithSelector(
        MangoImplementation.$retractOffers.selector,
        ba,
        from,
        to
      )
    );
    if (!success) {
      MangoStorage.revertWithData(retdata);
    } else {
      return abi.decode(retdata, (uint));
    }
  }

  /** Shift the price (induced by quote amount) of n slots down or up */
  /** price at position i will be shifted (up or down dePENDING on the sign of `shift`) */
  /** New positions 0<= i < s are initialized with amount[i] in base tokens if `withBase`. In quote tokens otherwise*/
  function set_shift(
    int s,
    bool withBase,
    uint[] calldata amounts
  ) public mgvOrAdmin {
    (bool success, bytes memory retdata) = IMPLEMENTATION.delegatecall(
      abi.encodeWithSelector(
        MangoImplementation.$set_shift.selector,
        s,
        withBase,
        amounts
      )
    );
    if (!success) {
      MangoStorage.revertWithData(retdata);
    }
  }

  function set_min_offer_type(uint m) external mgvOrAdmin {
    MangoStorage.get_storage().min_buffer = m;
  }

  function _staticdelegatecall(bytes calldata data)
    external
    onlyCaller(address(this))
  {
    (bool success, bytes memory retdata) = IMPLEMENTATION.delegatecall(data);
    if (!success) {
      MangoStorage.revertWithData(retdata);
    }
    assembly {
      return(add(retdata, 32), returndatasize())
    }
  }

  // return Mango offer Ids on Mangrove. If `liveOnly` will only return offer Ids that are live (0 otherwise).
  function get_offers(bool liveOnly)
    external
    view
    returns (uint[][2] memory offers)
  {
    (bool success, bytes memory retdata) = address(this).staticcall(
      abi.encodeWithSelector(
        this._staticdelegatecall.selector,
        abi.encodeWithSelector(
          MangoImplementation.$get_offers.selector,
          liveOnly
        )
      )
    );
    if (!success) {
      MangoStorage.revertWithData(retdata);
    } else {
      return abi.decode(retdata, (uint[][2]));
    }
  }

  // starts reneging all offers
  // NB reneged offers will not be reposted
  function pause() public mgvOrAdmin {
    MangoStorage.get_storage().paused = true;
  }

  function restart() external onlyAdmin {
    MangoStorage.get_storage().paused = false;
  }

  function is_paused() external view returns (bool) {
    return MangoStorage.get_storage().paused;
  }

  // this overrides is read during `makerExecute` call (see `MangroveOffer`)
  function __lastLook__(ML.SingleOrder calldata order)
    internal
    virtual
    override
    returns (bool proceed)
  {
    order; //shh
    proceed = !MangoStorage.get_storage().paused;
  }

  function __posthookSuccess__(ML.SingleOrder calldata order)
    internal
    virtual
    override
    returns (bool)
  {
    (bool success, bytes memory retdata) = IMPLEMENTATION.delegatecall(
      abi.encodeWithSelector(
        MangoImplementation.$posthookSuccess.selector,
        order
      )
    );
    if (!success) {
      MangoStorage.revertWithData(retdata);
    } else {
      return abi.decode(retdata, (bool));
    }
  }
}