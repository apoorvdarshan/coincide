fn main() {
    println!("cargo:rerun-if-changed=src/microphone_macos.m");
    println!("cargo:rerun-if-changed=src/microphone_macos.h");
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
        .flag("-fobjc-arc")
        .flag("-fblocks")
        .flag("-std=gnu11")
        .compile("coincide_microphone");
    for framework in ["Foundation", "AVFAudio", "AVFoundation"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
#[cfg(not(all(target_os = "macos", feature = "native-microphone")))]
fn compile_microphone() {
    panic!("native-microphone for macOS requires a macOS build host");
}
