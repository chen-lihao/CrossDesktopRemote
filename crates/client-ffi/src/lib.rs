use session_core::core_build_info;

#[unsafe(no_mangle)]
pub extern "C" fn cdr_core_abi_version() -> u32 {
    core_build_info().abi_version
}

#[unsafe(no_mangle)]
pub extern "C" fn cdr_core_protocol_major_version() -> u32 {
    core_build_info().protocol_major_version
}

#[unsafe(no_mangle)]
pub extern "C" fn cdr_core_feature_flags() -> u64 {
    core_build_info().feature_flags
}

#[cfg(test)]
mod tests {
    use session_core::{FEATURE_NARROW_C_ABI, FEATURE_PROTOBUF_V1};

    use super::*;

    #[test]
    fn exposes_stable_scalar_abi() {
        assert_eq!(cdr_core_abi_version(), 1);
        assert_eq!(cdr_core_protocol_major_version(), 1);
        assert_eq!(
            cdr_core_feature_flags(),
            FEATURE_NARROW_C_ABI | FEATURE_PROTOBUF_V1
        );
    }
}
