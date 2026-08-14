// SPDX-License-Identifier: MIT
//! Regression coverage for the Android build's UniFFI ABI guard.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn fixture() -> (PathBuf, PathBuf, Vec<PathBuf>) {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before epoch")
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "sidestage-android-abi-guard-{}-{nonce}",
        std::process::id()
    ));
    let bin = root.join("bin");
    fs::create_dir_all(&bin).expect("create fixture bin");

    let kotlin = root.join("sidestage.kt");
    fs::write(
        &kotlin,
        r#"
interface UniffiLib {
    fun uniffi_sidestage_checksum_func_version(): Short
    fun uniffi_sidestage_checksum_method_sidestageclient_events(): Short
}
"#,
    )
    .expect("write Kotlin fixture");

    let readelf = bin.join("readelf");
    fs::write(
        &readelf,
        r#"#!/usr/bin/env bash
set -euo pipefail
file="${!#}"
printf '%s\n' '1: 0 0 FUNC GLOBAL DEFAULT 1 uniffi_sidestage_checksum_func_version'
if [[ "$file" != *missing-symbol* ]]; then
  printf '%s\n' '2: 0 0 FUNC GLOBAL DEFAULT 1 uniffi_sidestage_checksum_method_sidestageclient_events'
fi
"#,
    )
    .expect("write fake readelf");
    fs::set_permissions(&readelf, fs::Permissions::from_mode(0o755))
        .expect("make fake readelf executable");

    let libraries = ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]
        .into_iter()
        .map(|abi| {
            let path = root.join(format!("{abi}-libsidestage.so"));
            fs::write(&path, b"ELF fixture").expect("write library fixture");
            path
        })
        .collect();

    (root, kotlin, libraries)
}

fn run_guard(root: &Path, kotlin: &Path, libraries: &[PathBuf]) -> std::process::Output {
    let guard = repo_root().join("tools/build-scripts/verify-android-uniffi-abi.sh");
    let mut command = Command::new("bash");
    command.arg(guard).arg(kotlin).args(libraries);
    command.env("READELF", root.join("bin/readelf"));
    command.output().expect("run ABI guard")
}

#[test]
fn accepts_all_four_libraries_when_the_checksum_contract_matches() {
    let (root, kotlin, libraries) = fixture();
    let output = run_guard(&root, &kotlin, &libraries);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "stdout={stdout}\nstderr={stderr}");
    assert!(stdout.contains("Verified 2 UniFFI checksum symbols across 4 Android ABI libraries"));
    fs::remove_dir_all(root).expect("clean fixture");
}

#[test]
fn rejects_a_library_missing_a_generated_checksum_symbol() {
    let (root, kotlin, mut libraries) = fixture();
    let missing = root.join("x86_64-missing-symbol-libsidestage.so");
    fs::write(&missing, b"ELF fixture").expect("write missing-symbol fixture");
    libraries[3] = missing;

    let output = run_guard(&root, &kotlin, &libraries);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "guard unexpectedly passed");
    assert!(stderr.contains("x86_64-missing-symbol-libsidestage.so"));
    assert!(stderr.contains("uniffi_sidestage_checksum_method_sidestageclient_events"));
    fs::remove_dir_all(root).expect("clean fixture");
}

#[test]
fn rejects_a_missing_abi_library() {
    let (root, kotlin, mut libraries) = fixture();
    libraries[2] = root.join("x86-absent-libsidestage.so");

    let output = run_guard(&root, &kotlin, &libraries);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success(), "guard unexpectedly passed");
    assert!(stderr.contains("Android ABI library missing or empty"));
    assert!(stderr.contains("x86-absent-libsidestage.so"));
    fs::remove_dir_all(root).expect("clean fixture");
}
