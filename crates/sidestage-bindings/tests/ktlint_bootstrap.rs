#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const FAKE_KTLINT: &str = "#!/bin/sh\nprintf 'ktlint version test\\n'\n";
const FAKE_KTLINT_SHA256: &str = "a23303422f3de9bfe9eaf6a1215cfdb17eafa6c98f60d44c5982cfb9fce4c2ab";

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("canonical repository root")
}

fn fixture_root() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time after Unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("sidestage-ktlint-{}-{nonce}", std::process::id()))
}

fn run_bootstrap(cache: &Path, source: &Path) -> std::process::Output {
    Command::new(repo_root().join("tools/build-scripts/ensure-ktlint.sh"))
        .env("SIDESTAGE_KTLINT_VERSION", "test")
        .env("SIDESTAGE_KTLINT_SHA256", FAKE_KTLINT_SHA256)
        .env(
            "SIDESTAGE_KTLINT_URL",
            format!("file://{}", source.display()),
        )
        .env("SIDESTAGE_KTLINT_CACHE_DIR", cache)
        .output()
        .expect("run ktlint bootstrap")
}

#[test]
fn downloads_verifies_and_reuses_the_pinned_formatter() {
    let root = fixture_root();
    let cache = root.join("cache");
    let source = root.join("ktlint-source");
    fs::create_dir_all(&root).expect("create fixture root");
    fs::write(&source, FAKE_KTLINT).expect("write fake ktlint");
    fs::set_permissions(&source, fs::Permissions::from_mode(0o755))
        .expect("make fake ktlint executable");

    let first = run_bootstrap(&cache, &source);
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    let installed = PathBuf::from(
        String::from_utf8(first.stdout)
            .expect("bootstrap path is UTF-8")
            .trim(),
    );
    assert_eq!(fs::read_to_string(&installed).unwrap(), FAKE_KTLINT);
    assert_ne!(
        fs::metadata(&installed).unwrap().permissions().mode() & 0o111,
        0
    );

    fs::write(&installed, "corrupt cache").expect("corrupt cached ktlint");
    let repaired = run_bootstrap(&cache, &source);
    assert!(
        repaired.status.success(),
        "{}",
        String::from_utf8_lossy(&repaired.stderr)
    );
    assert_eq!(fs::read_to_string(&installed).unwrap(), FAKE_KTLINT);

    fs::remove_file(&source).expect("remove source to prove cached reuse");
    let second = run_bootstrap(&cache, &source);
    assert!(
        second.status.success(),
        "{}",
        String::from_utf8_lossy(&second.stderr)
    );
    assert_eq!(
        String::from_utf8(second.stdout).unwrap().trim(),
        installed.to_string_lossy(),
    );

    fs::remove_dir_all(&root).expect("remove fixture root");
}

#[test]
fn makefile_puts_the_managed_formatter_first_on_path() {
    let makefile = fs::read_to_string(repo_root().join("Makefile")).expect("read Makefile");
    let target = makefile
        .split_once("bindings-kotlin:")
        .expect("bindings-kotlin target")
        .1
        .split_once("bindings-swift:")
        .expect("bindings-swift target follows Kotlin target")
        .0;

    let bootstrap = target
        .find("ensure-ktlint.sh")
        .expect("ktlint bootstrap call");
    let bindgen = target.find("uniffi-bindgen").expect("UniFFI bindgen call");
    assert!(
        bootstrap < bindgen,
        "ktlint must be ready before UniFFI runs"
    );
    assert!(target.contains("PATH=\"$$(dirname \"$$KTLINT\"):$$PATH\""));
}
