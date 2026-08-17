pub const CORE_ABI_VERSION: u32 = 1;
pub const PROTOCOL_MAJOR_VERSION: u32 = 1;
pub const FEATURE_NARROW_C_ABI: u64 = 1 << 0;
pub const FEATURE_PROTOBUF_V1: u64 = 1 << 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreBuildInfo {
    pub abi_version: u32,
    pub protocol_major_version: u32,
    pub feature_flags: u64,
}

pub const fn core_build_info() -> CoreBuildInfo {
    CoreBuildInfo {
        abi_version: CORE_ABI_VERSION,
        protocol_major_version: PROTOCOL_MAJOR_VERSION,
        feature_flags: FEATURE_NARROW_C_ABI | FEATURE_PROTOBUF_V1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_only_compiled_core_features() {
        let info = core_build_info();

        assert_eq!(info.abi_version, 1);
        assert_eq!(info.protocol_major_version, 1);
        assert_ne!(info.feature_flags & FEATURE_NARROW_C_ABI, 0);
        assert_ne!(info.feature_flags & FEATURE_PROTOBUF_V1, 0);
    }
}
