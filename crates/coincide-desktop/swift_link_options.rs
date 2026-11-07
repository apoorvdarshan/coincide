//! Darwin object autolink metadata, per Apple's mach-o/loader.h LC_LINKER_OPTION.
//! Swift's ELF-only autolink extractor is not a Darwin developer tool.
pub fn extract(object: &[u8]) -> Result<Vec<String>, &'static str> {
    fn number(bytes: &[u8], offset: usize) -> Result<u32, &'static str> {
        let value = bytes
            .get(offset..offset.checked_add(4).ok_or("Mach-O offset overflow")?)
            .ok_or("Truncated Mach-O integer")?;
        Ok(u32::from_le_bytes(value.try_into().unwrap()))
    }
    if object.len() > 32 * 1024 * 1024 || number(object, 0)? != 0xfeedfacf {
        return Err("Expected bounded little-endian 64-bit Mach-O object");
    }
    if number(object, 12)? != 1 {
        return Err("Expected MH_OBJECT");
    }
    let commands = number(object, 16)? as usize;
    let end = 32usize
        .checked_add(number(object, 20)? as usize)
        .ok_or("Mach-O commands overflow")?;
    if commands > 65_536 || end > object.len() {
        return Err("Invalid Mach-O load commands");
    }
    let mut cursor = 32usize;
    let mut flags = Vec::new();
    for _ in 0..commands {
        let command = number(object, cursor)?;
        let size = number(object, cursor + 4)? as usize;
        let next = cursor.checked_add(size).ok_or("Mach-O command overflow")?;
        if size < 8 || !size.is_multiple_of(4) || next > end {
            return Err("Invalid Mach-O command size");
        }
        if command == 0x2d {
            if size < 12 {
                return Err("Truncated LC_LINKER_OPTION");
            }
            let count = number(object, cursor + 8)? as usize;
            if count > 64 || flags.len().saturating_add(count) > 4096 {
                return Err("Excessive autolink options");
            }
            let mut strings = &object[cursor + 12..next];
            for _ in 0..count {
                let length = strings
                    .iter()
                    .position(|byte| *byte == 0)
                    .ok_or("Unterminated autolink option")?;
                let option = std::str::from_utf8(&strings[..length])
                    .map_err(|_| "Invalid autolink UTF-8")?;
                if option.is_empty()
                    || option.len() > 256
                    || option.chars().any(|c| c.is_control() || c.is_whitespace())
                {
                    return Err("Invalid autolink option");
                }
                flags.push(option.to_owned());
                strings = &strings[length + 1..];
            }
            if strings.iter().any(|byte| *byte != 0) {
                return Err("Unexpected LC_LINKER_OPTION trailing bytes");
            }
        }
        cursor = next;
    }
    if cursor != end || !flags.iter().any(|flag| flag == "-lswiftCore") {
        return Err("Missing complete Swift runtime autolink metadata");
    }
    Ok(flags)
}
#[cfg(test)]
mod tests {
    use super::extract;
    fn object(options: &[&str]) -> Vec<u8> {
        let mut command = Vec::new();
        command.extend_from_slice(&0x2du32.to_le_bytes());
        command.extend_from_slice(&0u32.to_le_bytes());
        command.extend_from_slice(&(options.len() as u32).to_le_bytes());
        for option in options {
            command.extend_from_slice(option.as_bytes());
            command.push(0);
        }
        while !command.len().is_multiple_of(8) {
            command.push(0);
        }
        let length = command.len() as u32;
        command[4..8].copy_from_slice(&length.to_le_bytes());
        let mut object = vec![0; 32];
        object[0..4].copy_from_slice(&0xfeedfacfu32.to_le_bytes());
        object[12..16].copy_from_slice(&1u32.to_le_bytes());
        object[16..20].copy_from_slice(&1u32.to_le_bytes());
        object[20..24].copy_from_slice(&length.to_le_bytes());
        object.extend(command);
        object
    }
    #[test]
    fn darwin_autolink_retains_framework_pairs_and_runtime_libraries() {
        assert_eq!(
            extract(&object(&[
                "-lswiftCore",
                "-framework",
                "Speech",
                "-lswift_Concurrency"
            ]))
            .unwrap(),
            vec!["-lswiftCore", "-framework", "Speech", "-lswift_Concurrency"]
        );
    }
    #[test]
    fn malformed_or_missing_runtime_metadata_is_rejected() {
        let valid = object(&["-lswiftCore"]);
        for length in 0..valid.len() {
            assert!(extract(&valid[..length]).is_err());
        }
        assert!(extract(&object(&["-framework", "Speech"])).is_err());
        let mut changed = valid;
        changed[36..40].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(extract(&changed).is_err());
    }
}
