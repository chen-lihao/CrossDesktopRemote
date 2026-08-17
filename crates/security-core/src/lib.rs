#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SessionPermission {
    ViewScreen = 0,
    ControlInput = 1,
    ReadClipboard = 2,
    WriteClipboard = 3,
    TransferFiles = 4,
    CaptureScreenshot = 5,
    RecordSession = 6,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PermissionSet(u64);

impl PermissionSet {
    #[must_use]
    pub const fn grant(self, permission: SessionPermission) -> Self {
        Self(self.0 | (1_u64 << permission as u8))
    }

    #[must_use]
    pub const fn contains(self, permission: SessionPermission) -> bool {
        self.0 & (1_u64 << permission as u8) != 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permissions_are_independent() {
        let permissions = PermissionSet::default()
            .grant(SessionPermission::ViewScreen)
            .grant(SessionPermission::ReadClipboard);

        assert!(permissions.contains(SessionPermission::ViewScreen));
        assert!(permissions.contains(SessionPermission::ReadClipboard));
        assert!(!permissions.contains(SessionPermission::ControlInput));
    }
}
