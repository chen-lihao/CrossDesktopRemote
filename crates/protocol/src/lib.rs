pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/crossdesktop.v1.rs"));
}

#[cfg(test)]
mod tests {
    use prost::Message;

    use super::v1::{ProtocolVersion, RequestContext};

    #[test]
    fn request_context_round_trips() {
        let context = RequestContext {
            protocol_version: Some(ProtocolVersion { major: 1, minor: 0 }),
            request_id: "request-1".to_owned(),
            sent_at_unix_ms: 42,
        };

        let encoded = context.encode_to_vec();
        let decoded = RequestContext::decode(encoded.as_slice()).expect("message must decode");

        assert_eq!(decoded, context);
    }
}
