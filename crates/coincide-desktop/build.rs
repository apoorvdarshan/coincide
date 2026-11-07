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
