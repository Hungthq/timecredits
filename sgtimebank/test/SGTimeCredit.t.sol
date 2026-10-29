// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from "forge-std/Test.sol";
import { SGTimeCredit } from "../contracts/SGTimeCredit.sol";

/// @notice Mirrors sg-timebank-engine.test.js, plus checks that only apply on chain.
contract SGTimeCreditTest is Test {
    SGTimeCredit tb;

    address admin = makeAddr("admin");
    address aisha = makeAddr("aisha");   // general volunteer
    address ravi = makeAddr("ravi");     // licensed physiotherapist
    address mei = makeAddr("mei");       // peer volunteer
    address kumar = makeAddr("kumar");   // family of aisha
    address coordA = makeAddr("coordA"); // coordinator, community centre
    address coordC = makeAddr("coordC"); // coordinator, clinic
    address stranger = makeAddr("stranger");

    uint256 cc;       // community centre org
    uint256 clinic;   // clinic org
    uint256 clinicPartner;
    uint256 plainPartner;
    uint256 pool;

    bytes32 constant TAG_CC = keccak256("tag-cc");
    bytes32 constant TAG_CLINIC = keccak256("tag-clinic");

    uint256 constant HOUR = 1 hours;
    // 5 Oct 2026, 08:00 Singapore time (00:00 UTC)
    uint256 constant T0 = 1791158400;

    function setUp() public {
        vm.warp(T0);
        tb = new SGTimeCredit(admin);
        vm.startPrank(admin);
        tb.verifyVolunteer(aisha, keccak256("S1111111A"), false, false);
        tb.verifyVolunteer(ravi, keccak256("S2222222B"), false, true);
        tb.verifyVolunteer(mei, keccak256("S3333333C"), true, false);
        tb.verifyVolunteer(kumar, keccak256("S4444444D"), false, false);
        cc = tb.registerOrg("Community Centre North");
        clinic = tb.registerOrg("Clinic X");
        tb.setCoordinator(cc, coordA, true);
        tb.setCoordinator(clinic, coordC, true);
        tb.registerTag(cc, TAG_CC);
        tb.registerTag(clinic, TAG_CLINIC);
        clinicPartner = tb.registerPartner(clinic, true, "Clinic X Physio");
        plainPartner = tb.registerPartner(clinic, false, "Clinic X (no loyalty)");
        pool = tb.registerPool("Elder Care Pool");
        tb.linkFamily(aisha, kumar);
        vm.stopPrank();
    }

    // ---------- helpers ----------

    function _tag(uint256 org) internal view returns (bytes32) {
        return org == cc ? TAG_CC : TAG_CLINIC;
    }

    function _coord(uint256 org) internal view returns (address) {
        return org == cc ? coordA : coordC;
    }

    /// Runs check-in to "ready". Returns the session id; leaves time at the moment it became ready.
    function _session(address vol, uint256 org, uint8 tier, uint256 hoursX4, uint256 start) internal returns (uint256 id) {
        vm.warp(start);
        vm.prank(vol);
        id = tb.checkIn(org, _tag(org), tier);
        vm.warp(start + hoursX4 * 15 minutes);
        vm.prank(vol);
        tb.checkOut(id, _tag(org));
        vm.prank(_coord(org));
        tb.sign(id, 1); // coordinator (literal: a call to tb.ROLE_COORDINATOR() here would consume the prank)
        vm.prank(vol == mei ? aisha : mei);
        tb.sign(id, 3); // peer
    }

    function _finaliseAfterWindow(uint256 id) internal {
        vm.warp(tb.disputeWindowEnds(id));
        tb.finalise(id);
    }

    function _status(uint256 id) internal view returns (SGTimeCredit.Status st) {
        (,,,,,,,,,, st) = tb.sessions(id);
    }

    function _credits(uint256 id) internal view returns (uint256 c, bool capped) {
        (,,,,,,,, c, capped,) = tb.sessions(id);
    }

    // ---------- ported from the JS engine tests ----------

    function test_GeneralTierMintsOneCreditPerHour() public {
        uint256 id = _session(aisha, cc, 0, 12, T0); // 3h
        _finaliseAfterWindow(id);
        assertEq(tb.balanceOf(aisha), 300);
    }

    function test_ProfessionalTierNeedsLicence() public {
        vm.prank(aisha);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.MissingCredential.selector, uint8(2)));
        tb.checkIn(clinic, TAG_CLINIC, 2);
    }

    function test_ProfessionalWithLicenceEarnsDouble() public {
        uint256 id = _session(ravi, clinic, 2, 12, T0); // 3h x2
        _finaliseAfterWindow(id);
        assertEq(tb.balanceOf(ravi), 600);
    }

    function test_DailyCapLimitsToEightCredits() public {
        uint256 a = _session(aisha, cc, 0, 32, T0);            // 8h
        uint256 b = _session(aisha, cc, 0, 16, T0 + 10 * HOUR); // 4h same SGT day
        vm.warp(T0 + 40 days);
        tb.finalise(a);
        tb.finalise(b);
        (uint256 ca,) = _credits(a);
        (uint256 cb, bool cappedB) = _credits(b);
        assertEq(ca, 800);
        assertEq(cb, 0);
        assertTrue(cappedB);
    }

    function test_CannotSignOwnHours() public {
        vm.prank(aisha);
        uint256 id = tb.checkIn(cc, TAG_CC, 0);
        vm.warp(T0 + HOUR);
        vm.prank(aisha);
        tb.checkOut(id, TAG_CC);
        vm.prank(aisha);
        vm.expectRevert(SGTimeCredit.SelfSign.selector);
        tb.sign(id, 3);
    }

    function test_FamilyCannotSign() public {
        vm.prank(aisha);
        uint256 id = tb.checkIn(cc, TAG_CC, 0);
        vm.warp(T0 + HOUR);
        vm.prank(aisha);
        tb.checkOut(id, TAG_CC);
        vm.prank(kumar);
        vm.expectRevert(SGTimeCredit.FamilyCannotSign.selector);
        tb.sign(id, 3);
    }

    function test_CoordinatorAloneIsNotEnough() public {
        vm.prank(aisha);
        uint256 id = tb.checkIn(cc, TAG_CC, 0);
        vm.warp(T0 + HOUR);
        vm.prank(aisha);
        tb.checkOut(id, TAG_CC);
        vm.prank(coordA);
        tb.sign(id, 1);
        assertEq(uint8(_status(id)), uint8(SGTimeCredit.Status.AwaitingSignoff));
        vm.prank(mei);
        tb.sign(id, 3);
        assertEq(uint8(_status(id)), uint8(SGTimeCredit.Status.Ready));
    }

    function test_PeerAndBeneficiaryWithoutCoordinatorIsNotEnough() public {
        vm.prank(aisha);
        uint256 id = tb.checkIn(cc, TAG_CC, 0);
        vm.warp(T0 + HOUR);
        vm.prank(aisha);
        tb.checkOut(id, TAG_CC);
        vm.prank(mei);
        tb.sign(id, 3);
        vm.prank(stranger);
        tb.sign(id, 2);
        assertEq(uint8(_status(id)), uint8(SGTimeCredit.Status.AwaitingSignoff));
    }

    function test_TagFromAnotherOrgIsRejected() public {
        vm.prank(aisha);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.TagNotInOrg.selector, cc, TAG_CLINIC));
        tb.checkIn(cc, TAG_CLINIC, 0);
    }

    function test_NothingMintsDuringDisputeWindow() public {
        uint256 id = _session(aisha, cc, 0, 8, T0);
        vm.warp(tb.disputeWindowEnds(id) - 1);
        vm.expectRevert();
        tb.finalise(id);
        assertEq(tb.balanceOf(aisha), 0);
    }

    function test_DisputedSessionNeverMints() public {
        uint256 id = _session(aisha, cc, 0, 8, T0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(coordA);
        tb.dispute(id, "hours not right");
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert();
        tb.finalise(id);
        assertEq(tb.balanceOf(aisha), 0);
    }

    function test_LoyaltyBelowThresholdIsStandardRate() public {
        _finaliseAfterWindow(_session(ravi, clinic, 0, 20, T0));          // 5h
        _finaliseAfterWindow(_session(ravi, clinic, 0, 20, T0 + 2 days)); // 5h
        assertEq(tb.verifiedQuartersAt(ravi, clinic), 40);
        (uint256 rate, bool loyal) = tb.redeemRate(ravi, clinicPartner);
        assertFalse(loyal);
        assertEq(rate, 100);
    }

    function test_LoyaltyAfterTwentyHoursCosts1point6For2Hours() public {
        for (uint256 k = 0; k < 3; k++) {
            _finaliseAfterWindow(_session(aisha, clinic, 0, 28, T0 + k * 30 days)); // 7h each
        }
        assertEq(tb.verifiedQuartersAt(aisha, clinic), 84); // 21h
        vm.prank(aisha);
        uint256 burn = tb.redeem(clinicPartner, 8); // 2h of physio
        assertEq(burn, 160);
    }

    function test_PartnerWithLoyaltyOffGivesStandardRate() public {
        (, bool loyal) = tb.redeemRate(aisha, plainPartner);
        assertFalse(loyal);
    }

    function test_RedeemRefusedWhenBalanceTooLow() public {
        vm.prank(mei);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.InsufficientCredits.selector, 0, 100));
        tb.redeem(clinicPartner, 4);
    }

    function test_GiftsOnlyToFamily() public {
        _finaliseAfterWindow(_session(aisha, cc, 0, 16, T0)); // 4 credits
        vm.prank(aisha);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.NotFamily.selector, aisha, mei));
        tb.gift(mei, 100);
        vm.prank(aisha);
        tb.gift(kumar, 200);
        assertEq(tb.balanceOf(kumar), 200);
        assertEq(tb.balanceOf(aisha), 200);
    }

    function test_DonationsGoToPool() public {
        _finaliseAfterWindow(_session(aisha, cc, 0, 16, T0));
        vm.prank(aisha);
        tb.donate(pool, 300);
        assertEq(tb.poolBalance(pool), 300);
        assertEq(tb.balanceOf(aisha), 100);
    }

    function test_SupplyReconciles() public {
        _finaliseAfterWindow(_session(ravi, clinic, 2, 12, T0)); // 6 credits
        vm.prank(ravi);
        tb.redeem(clinicPartner, 4); // 1h at standard rate
        assertEq(tb.totalMinted(), 600);
        assertEq(tb.totalBurned(), 100);
        assertEq(tb.circulatingSupply(), 500);
    }

    function test_CapsApplyPerWorkDayNotMintDay() public {
        uint256 a = _session(ravi, clinic, 2, 16, T0);          // 4h x2 = 8
        uint256 b = _session(ravi, clinic, 2, 16, T0 + 3 days); // different work day
        vm.warp(T0 + 60 days); // both finalised in the same block
        tb.finalise(a);
        tb.finalise(b);
        (uint256 ca,) = _credits(a);
        (uint256 cb,) = _credits(b);
        assertEq(ca, 800);
        assertEq(cb, 800);
    }

    // ---------- on-chain-only checks ----------

    function test_OneWalletPerIdentity() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.IdentityAlreadyUsed.selector, keccak256("S1111111A")));
        tb.verifyVolunteer(stranger, keccak256("S1111111A"), false, false);
    }

    function test_OnlyAdminCanOnboard() public {
        vm.prank(stranger);
        vm.expectRevert(SGTimeCredit.NotAdmin.selector);
        tb.verifyVolunteer(stranger, keccak256("S9"), false, false);
    }

    function test_UnverifiedWalletCannotCheckIn() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.NotVerifiedVolunteer.selector, stranger));
        tb.checkIn(cc, TAG_CC, 0);
    }

    function test_CoordinatorOfAnotherOrgCannotSign() public {
        vm.prank(aisha);
        uint256 id = tb.checkIn(cc, TAG_CC, 0);
        vm.warp(T0 + HOUR);
        vm.prank(aisha);
        tb.checkOut(id, TAG_CC);
        vm.prank(coordC);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.NotCoordinator.selector, coordC, cc));
        tb.sign(id, 1);
    }

    function test_StrangerCannotDispute() public {
        uint256 id = _session(aisha, cc, 0, 8, T0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.NotAllowedToDispute.selector, stranger));
        tb.dispute(id, "spite");
    }

    function test_SessionLengthLimits() public {
        vm.prank(aisha);
        uint256 id = tb.checkIn(cc, TAG_CC, 0);
        vm.warp(T0 + 7 minutes); // rounds to 0 quarters
        vm.prank(aisha);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.SessionTooShort.selector, 0));
        tb.checkOut(id, TAG_CC);
        vm.warp(T0 + 9 hours);
        vm.prank(aisha);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.SessionTooLong.selector, 36));
        tb.checkOut(id, TAG_CC);
    }

    function test_OneOpenSessionAtATime() public {
        vm.prank(aisha);
        uint256 id = tb.checkIn(cc, TAG_CC, 0);
        vm.prank(aisha);
        vm.expectRevert(abi.encodeWithSelector(SGTimeCredit.SessionAlreadyOpen.selector, id));
        tb.checkIn(cc, TAG_CC, 0);
    }

    function test_MonthlyCapOfSixty() public {
        // 8 work days x 8 credits = 64 requested in October; only 60 mint.
        uint256[] memory ids = new uint256[](8);
        for (uint256 d = 0; d < 8; d++) {
            ids[d] = _session(aisha, cc, 0, 32, T0 + d * 1 days);
        }
        vm.warp(T0 + 40 days);
        for (uint256 d = 0; d < 8; d++) tb.finalise(ids[d]);
        assertEq(tb.balanceOf(aisha), 6000);
        assertEq(tb.mintedInMonth(aisha, tb.monthKey(T0)), 6000);
    }

    function test_MonthKeyUsesSingaporeTime() public view {
        // 31 Oct 2026 20:00 UTC = 1 Nov 2026 04:00 SGT -> November
        assertEq(tb.monthKey(1793476800), 2026 * 12 + 10);
        // 31 Oct 2026 15:59 UTC = 31 Oct 23:59 SGT -> October
        assertEq(tb.monthKey(1793462340), 2026 * 12 + 9);
        // 29 Feb 2028 (leap day), noon SGT -> February
        assertEq(tb.monthKey(1835409600), 2028 * 12 + 1);
    }

    function test_CreditsCannotBeTransferredFreely() public view {
        // There is no transfer() or approve(): only gift (family) and donate (pool) move credits.
        (bool ok,) = address(tb).staticcall(abi.encodeWithSignature("transfer(address,uint256)", stranger, 1));
        assertFalse(ok);
    }

    function testFuzz_QuarterHourRounding(uint256 secondsWorked) public {
        secondsWorked = bound(secondsWorked, 450, 8 hours + 449);
        vm.prank(aisha);
        uint256 id = tb.checkIn(cc, TAG_CC, 0);
        vm.warp(T0 + secondsWorked);
        vm.prank(aisha);
        tb.checkOut(id, TAG_CC);
        (,,,,,, uint32 quarters,,,,) = tb.sessions(id);
        uint256 expected = (secondsWorked * 4 + 1800) / 3600;
        assertEq(quarters, expected);
        assertLe(quarters, 32);
        assertGe(quarters, 1);
    }
}
