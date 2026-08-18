// SPDX-License-Identifier: MIT
//! Pins the two phone shells' WHEP players to the shared core's policy seam
//! (plan decision D-036) and to each other.
//!
//! Why textual: neither shell's player is typable from this repo's Linux-side
//! verification. The Android player compiles only under Gradle, and the iOS
//! engine sits behind `#if canImport(WebRTC)` because the swiftc typecheck
//! harness (tools/verify-ios-typecheck.sh) has no Swift Package Manager
//! resolution — so the branch that actually plays video is exactly the branch
//! no compiler on this box ever reads. These pins are the compensating
//! control: they fail when the load-bearing parts of that unverifiable branch
//! disappear, when a shell stops consulting the core's policy, or when the
//! hand-duplicated stage copy drifts between the phones.

use std::fs;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn source(rel: &str) -> String {
    let path = repo_root().join(rel);
    fs::read_to_string(&path).unwrap_or_else(|err| panic!("read {}: {err}", path.display()))
}

const ANDROID_PLAYER: &str = "android/app/src/main/kotlin/com/sidestage/mobile/buyer/WhepPlayer.kt";
const ANDROID_STAGE: &str =
    "android/app/src/main/kotlin/com/sidestage/mobile/buyer/LiveEventScreen.kt";
const IOS_PLAYER: &str = "ios/SideStage/Sources/Buyer/WhepPlayer.swift";
const IOS_ENGINE: &str = "ios/SideStage/Sources/Buyer/WhepWebRTCEngine.swift";

/// The six policy calls D-036 reserves to the core. A shell player that stops
/// invoking one of these has grown its own copy of the policy — the drift this
/// whole seam exists to prevent.
const POLICY_CALLS: [&str; 6] = [
    "publisherRetryDelayMs",
    "isLostConnectionState",
    "maxLossReconnects",
    "sdpHasIceCandidate",
    "waitingForPublisherMessage",
    "publisherAbsentMessage",
];

/// The stage copy each shell declares by hand, with no compiler comparing
/// them. Same class of hole as the payment-status vocabulary that shipped an
/// unreachable success branch (see status_vocabulary_guard.rs).
// The button labels are pinned QUOTED because bare `Connect` is a substring
// of `Disconnect` and `Connecting…` — unquoted, that pin could never fail.
const SHARED_STAGE_COPY: [&str; 6] = [
    "The seller stream appears here when the room is live.",
    "Live playback isn't available for this room yet.",
    "Connecting…",
    "\"Connect\"",
    "\"Disconnect\"",
    "\"Retry\"",
];

/// The failure copy both players map `WhepError` onto.
const SHARED_FAILURE_COPY: [&str; 4] = [
    "This room's playback address is invalid.",
    "The stream could not be connected.",
    "The media server rejected the stream (",
    "The media server returned an unusable answer.",
];

/// Assert every needle appears, refusing an empty haystack first: an empty
/// source means the guard stopped reading its subject, and that must never
/// read as "all pins hold".
fn assert_all_present(subject: &str, haystack: &str, needles: &[&str]) {
    assert!(
        !haystack.trim().is_empty(),
        "{subject} read back empty — this guard stopped reading its subject and \
         would have passed against anything"
    );
    for needle in needles {
        assert!(
            haystack.contains(needle),
            "{subject} no longer contains {needle:?}. If this is a rename, update \
             the pin AND its counterpart on the other platform — these are \
             hand-duplicated with no compiler comparing them."
        );
    }
}

#[test]
fn both_shell_players_consult_every_core_policy_call() {
    assert_all_present(ANDROID_PLAYER, &source(ANDROID_PLAYER), &POLICY_CALLS);
    assert_all_present(IOS_PLAYER, &source(IOS_PLAYER), &POLICY_CALLS);
}

#[test]
fn the_stage_copy_is_identical_on_both_phones() {
    // Android splits the strings across the controller and the stage
    // composable; iOS keeps them all in the player. Concatenating each
    // shell's declaring files keeps the pin about the SHELL, not the file
    // layout.
    let android = format!("{}\n{}", source(ANDROID_PLAYER), source(ANDROID_STAGE));
    let ios = source(IOS_PLAYER);
    assert_all_present("the Android shell", &android, &SHARED_STAGE_COPY);
    assert_all_present(IOS_PLAYER, &ios, &SHARED_STAGE_COPY);
    assert_all_present(
        ANDROID_PLAYER,
        &source(ANDROID_PLAYER),
        &SHARED_FAILURE_COPY,
    );
    assert_all_present(IOS_PLAYER, &ios, &SHARED_FAILURE_COPY);
}

/// The parts of the iOS engine branch that no compiler on this box reads.
///
/// Each of these is load-bearing, established the hard way on the other
/// surfaces: recv-only transceivers are what make the offer a VIEWER's offer;
/// unified plan is what makes `didStartReceivingOn` fire; the canImport guard
/// is what keeps the typecheck harness honest; the Metal view is the actual
/// pixels. Losing any of them compiles fine somewhere and shows a buyer a
/// black rectangle.
#[test]
fn the_ios_engine_branch_keeps_its_load_bearing_structure() {
    let engine = source(IOS_ENGINE);
    assert_all_present(
        IOS_ENGINE,
        &engine,
        &[
            "#if canImport(WebRTC)",
            "sdpSemantics = .unifiedPlan",
            "addTransceiver(of: .video",
            "addTransceiver(of: .audio",
            ".recvOnly",
            "RTCInitializeSSL()",
            "RTCMTLVideoView",
            "localDescription?.sdp",
            "makePlatformWhepEngine",
        ],
    );
    // The fallback branch must keep the app typecheckable WITHOUT the
    // package: the harness compiles that branch, so it must exist.
    assert!(
        engine.contains("#else"),
        "{IOS_ENGINE} lost its no-WebRTC fallback branch — the swiftc typecheck \
         harness can no longer compile the app target"
    );
}

/// Both engines wait the same bounded time for ICE gathering. The bound is
/// engine policy the core deliberately does not own (it is a property of the
/// native stacks), so the parity pin lives here instead.
#[test]
fn the_ice_gathering_bound_matches_across_shells() {
    assert_all_present(
        ANDROID_PLAYER,
        &source(ANDROID_PLAYER),
        &["ICE_GATHERING_TIMEOUT_MS = 10_000L"],
    );
    assert_all_present(
        IOS_ENGINE,
        &source(IOS_ENGINE),
        &["iceGatheringTimeoutMs: UInt64 = 10_000"],
    );
}

/// Proof the assertions above can FAIL, kept permanently in the file (the
/// same discipline as status_vocabulary_guard.rs: mutating the real tree to
/// prove falsifiability is unsafe under the sweep, so the controls drive the
/// same assertion function with fixtures whose verdict is known).
#[test]
fn the_pins_reject_what_they_are_supposed_to_reject() {
    let rejects = |case: &str, body: fn()| {
        assert!(
            std::panic::catch_unwind(body).is_err(),
            "the guard accepted {case} — it is weaker than it looks"
        );
    };

    rejects("a source missing a pinned needle", || {
        assert_all_present("fixture", "some content", &["absent needle"])
    });
    // The fail-toward-green case: an unread subject must refuse, not pass.
    rejects("an empty source with no needles asked", || {
        assert_all_present("fixture", "", &[])
    });

    // Positive control: with the needle present it must NOT panic, or the
    // rejections above are meaningless.
    assert_all_present("fixture", "the needle is here", &["needle"]);
}
