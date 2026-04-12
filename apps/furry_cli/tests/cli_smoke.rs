use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const TEST_MASTER_KEY_HEX: &str =
    "46555252595f4d41535445525f4b45595f323032365f56315f53454352455421";

fn cli_binary() -> PathBuf {
    if let Ok(path) = std::env::var("CARGO_BIN_EXE_furry-cli") {
        return PathBuf::from(path);
    }
    if let Ok(path) = std::env::var("CARGO_BIN_EXE_furry_cli") {
        return PathBuf::from(path);
    }

    let mut path = std::env::current_exe().expect("current test binary path");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push(format!("furry-cli{}", std::env::consts::EXE_SUFFIX));
    path
}

fn unique_temp_path(prefix: &str, ext: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!("{prefix}_{}_{}.{}", std::process::id(), nanos, ext))
}

#[test]
fn info_reports_bad_magic_for_plain_file() {
    let path = unique_temp_path("furry_cli_bad_magic", "bin");
    std::fs::write(&path, b"plain audio bytes").expect("write temp file");

    let output = Command::new(cli_binary())
        .env("FURRY_MASTER_KEY_HEX", TEST_MASTER_KEY_HEX)
        .arg("info")
        .arg(&path)
        .output()
        .expect("run furry-cli");

    assert_eq!(output.status.code(), Some(3));
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        r#"{"valid":false,"error":"bad_magic"}"#
    );

    let _ = std::fs::remove_file(path);
}

#[test]
fn info_fails_fast_when_master_key_env_is_invalid() {
    let output = Command::new(cli_binary())
        .env("FURRY_MASTER_KEY_HEX", "not-hex")
        .arg("info")
        .arg("ignored.furry")
        .output()
        .expect("run furry-cli");

    assert_eq!(output.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Failed to load runtime master key"),
        "stderr was: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn pack_rejects_invalid_padding_argument_without_creating_output() {
    let input_path = unique_temp_path("furry_cli_pack_input", "mp3");
    let output_path = unique_temp_path("furry_cli_pack_output", "furry");
    std::fs::write(&input_path, b"fake audio bytes").expect("write temp input");

    let output = Command::new(cli_binary())
        .env("FURRY_MASTER_KEY_HEX", TEST_MASTER_KEY_HEX)
        .arg("pack")
        .arg(&input_path)
        .arg(&output_path)
        .arg("not-a-number")
        .output()
        .expect("run furry-cli");

    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Invalid padding_kb argument"),
        "stderr was: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !output_path.exists(),
        "output should not be created on invalid padding argument"
    );

    let _ = std::fs::remove_file(input_path);
    let _ = std::fs::remove_file(output_path);
}

#[test]
fn unpack_rejects_invalid_input_without_creating_output() {
    let input_path = unique_temp_path("furry_cli_unpack_input", "bin");
    let output_path = unique_temp_path("furry_cli_unpack_output", "mp3");
    std::fs::write(&input_path, b"plain bytes").expect("write temp input");

    let output = Command::new(cli_binary())
        .env("FURRY_MASTER_KEY_HEX", TEST_MASTER_KEY_HEX)
        .arg("unpack")
        .arg(&input_path)
        .arg(&output_path)
        .output()
        .expect("run furry-cli");

    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Failed to inspect input file"),
        "stderr was: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !output_path.exists(),
        "output should not be created on invalid unpack input"
    );

    let _ = std::fs::remove_file(input_path);
    let _ = std::fs::remove_file(output_path);
}
