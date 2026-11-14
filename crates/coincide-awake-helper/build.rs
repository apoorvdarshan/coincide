fn main() {
    println!("cargo:rerun-if-changed=src/macos.m");
    #[cfg(target_os = "macos")]
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("src/macos.m")
            .flag("-fobjc-arc")
            .flag("-fblocks")
            .flag("-std=gnu11")
            .compile("coincide_awake_macos");
        for framework in ["Foundation", "CoreFoundation", "IOKit", "CoreAudio"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
    }
}
