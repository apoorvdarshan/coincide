#[cfg(target_os = "macos")]
mod swift_link_options;
fn main() {
    // GPUI's main-thread view construction exceeds the MSVC 1 MiB default
    // stack in debug builds (observed by the native Windows startup smoke).
    // Match the ordinary macOS main-thread reserve without moving the UI
    // event loop to a worker thread.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc")
    {
        println!("cargo:rustc-link-arg-bin=coincide-rust=/STACK:8388608");
    }
    println!("cargo:rerun-if-changed=src/appshots_macos.m");
    #[cfg(target_os = "macos")]
    compile_appshots();
    println!("cargo:rerun-if-changed=src/microphone_macos.m");
    println!("cargo:rerun-if-changed=src/microphone_macos.h");
    println!("cargo:rerun-if-changed=src/microphone_devices_macos.m");
    println!("cargo:rerun-if-changed=src/computer_use_macos.m");
    println!("cargo:rerun-if-changed=src/computer_use_macos.h");
    if std::env::var_os("CARGO_FEATURE_NATIVE_COMPUTER_USE").is_some()
        && std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos")
    {
        compile_computer_use();
    }
    if std::env::var_os("CARGO_FEATURE_NATIVE_MICROPHONE").is_none()
        || std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos")
    {
        return;
    }
    compile_microphone();
    compile_apple_speech();
}
#[cfg(all(target_os = "macos", feature = "native-microphone"))]
fn compile_microphone() {
    cc::Build::new()
        .file("src/microphone_macos.m")
        .file("src/microphone_devices_macos.m")
        .flag("-fobjc-arc")
        .flag("-fblocks")
        .flag("-std=gnu11")
        .compile("coincide_microphone");
    for framework in [
        "Foundation",
        "AVFAudio",
        "AVFoundation",
        "CoreAudio",
        "AudioToolbox",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
#[cfg(not(all(target_os = "macos", feature = "native-microphone")))]
fn compile_microphone() {
    panic!("native-microphone for macOS requires a macOS build host");
}

#[cfg(all(target_os = "macos", feature = "native-computer-use"))]
fn compile_computer_use() {
    cc::Build::new()
        .file("src/computer_use_macos.m")
        .flag("-fobjc-arc")
        .flag("-fblocks")
        .flag("-std=gnu11")
        .compile("coincide_computer_use");
    for framework in [
        "Foundation",
        "AppKit",
        "ApplicationServices",
        "CoreGraphics",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    println!("cargo:rustc-link-arg=-Wl,-weak_framework,ScreenCaptureKit");
}
#[cfg(not(all(target_os = "macos", feature = "native-computer-use")))]
fn compile_computer_use() {
    panic!("native-computer-use for macOS requires a macOS build host");
}

#[cfg(target_os = "macos")]
fn compile_appshots() {
    cc::Build::new()
        .file("src/appshots_macos.m")
        .flag("-fobjc-arc")
        .flag("-fblocks")
        .flag("-std=gnu11")
        .compile("coincide_appshots");
    for framework in [
        "Foundation",
        "AppKit",
        "ApplicationServices",
        "CoreGraphics",
        "Carbon",
        "ScreenCaptureKit",
        "AudioToolbox",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}

#[cfg(target_os = "macos")]
fn compile_apple_speech() {
    use std::{path::PathBuf, process::Command};
    println!("cargo:rerun-if-changed=src/voice_speech_macos.swift");
    fn output(args: &[&str]) -> String {
        let result = Command::new("xcrun")
            .args(args)
            .output()
            .expect("Apple Speech requires Xcode command-line tools");
        assert!(
            result.status.success(),
            "Apple Speech SDK command failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );
        String::from_utf8(result.stdout)
            .expect("Xcode tool output must be UTF-8")
            .trim()
            .to_owned()
    }
    let sdk = output(&["--sdk", "macosx", "--show-sdk-path"]);
    // Rust's cc linker and Swift must resolve the same SDK frameworks. The
    // host CLT default can differ from the active Xcode SDK used above.
    println!("cargo:rustc-link-arg=-isysroot");
    println!("cargo:rustc-link-arg={sdk}");
    println!("cargo:rustc-link-search=framework={sdk}/System/Library/Frameworks");
    println!("cargo:rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
    let requested = std::env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "14.0".into());
    let parts = requested.split('.').collect::<Vec<_>>();
    assert!(
        (2..=3).contains(&parts.len())
            && parts
                .iter()
                .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit())),
        "Invalid native Voice deployment target"
    );
    let minimum = if parts[0].parse::<u32>().expect("Deployment major version") >= 14 {
        requested
    } else {
        "14.0".into()
    };
    println!("cargo:rustc-link-arg=-mmacosx-version-min={minimum}");

    let swift = PathBuf::from(output(&["--find", "swiftc"]));
    let architecture = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        _ => panic!("Unsupported Apple Speech architecture"),
    };
    let target = format!("{architecture}-apple-macosx{minimum}");
    let directory = PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo output directory"));
    let object = directory.join("voice_speech_macos.o");
    let result = Command::new(&swift)
        .args([
            "-parse-as-library",
            "-swift-version",
            "6",
            "-emit-object",
            "-module-name",
            "CoincideVoiceSpeech",
            "-target",
            &target,
            "-sdk",
            &sdk,
            "src/voice_speech_macos.swift",
            "-o",
        ])
        .arg(&object)
        .output()
        .expect("Compile Apple Speech bridge");
    assert!(
        result.status.success(),
        "Apple Speech bridge compile failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    cc::Build::new()
        .object(&object)
        .compile("coincide_voice_speech");
    // Darwin embeds autolink flags in Mach-O LC_LINKER_OPTION. The Linux
    // swift-autolink-extract utility is not shipped by Xcode on this host.
    let object_bytes = std::fs::read(&object).expect("Read compiled Swift object");
    let options = swift_link_options::extract(&object_bytes)
        .expect("Extract Darwin Swift runtime requirements");
    let mut flags = options.iter().map(String::as_str);
    while let Some(flag) = flags.next() {
        if let Some(library) = flag.strip_prefix("-l") {
            assert!(!library.is_empty());
            println!("cargo:rustc-link-lib={library}");
        } else if flag == "-framework" {
            let framework = flags.next().expect("Framework name");
            println!("cargo:rustc-link-lib=framework={framework}");
        } else if flag == "-weak_framework" {
            let framework = flags.next().expect("Weak framework name");
            println!("cargo:rustc-link-arg=-Wl,-weak_framework,{framework}");
        } else {
            panic!("Unrecognized Swift autolink requirement: {flag}");
        }
    }
    let toolchain = swift
        .parent()
        .and_then(|p| p.parent())
        .expect("Swift toolchain layout");
    for path in [
        toolchain.join("lib/swift/macosx"),
        PathBuf::from(&sdk).join("usr/lib/swift"),
        PathBuf::from("/usr/lib/swift"),
    ] {
        println!("cargo:rustc-link-search=native={}", path.display());
    }
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    println!("cargo:rustc-link-lib=framework=Speech");
}
#[cfg(not(target_os = "macos"))]
fn compile_apple_speech() {
    panic!("Apple Speech requires a macOS build host");
}
