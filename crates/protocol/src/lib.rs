pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/crossdesktop.v1.rs"));
}

#[cfg(test)]
mod tests {
    use prost::Message;

    use super::v1::{
        ClientCapabilities, ProtocolVersion, RequestContext, TransferEnvelope, TransferFileChunk,
        transfer_envelope,
    };

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

    #[test]
    fn old_capabilities_decode_without_new_data_features() {
        let old_capabilities = ClientCapabilities {
            supports_file_resume: true,
            ..Default::default()
        };

        let encoded = old_capabilities.encode_to_vec();
        let decoded = ClientCapabilities::decode(encoded.as_slice()).expect("message must decode");

        assert!(decoded.supports_file_resume);
        assert!(decoded.clipboard.is_none());
        assert!(decoded.transfer.is_none());
    }

    #[test]
    fn transfer_chunk_round_trips_as_binary_protobuf() {
        let envelope = TransferEnvelope {
            message: Some(transfer_envelope::Message::FileChunk(TransferFileChunk {
                protocol_version: 1,
                transfer_id: "transfer-1".to_owned(),
                entry_index: 2,
                offset: 16,
                payload: vec![1, 2, 3],
                end_of_entry: false,
            })),
        };

        let encoded = envelope.encode_to_vec();
        let decoded = TransferEnvelope::decode(encoded.as_slice()).expect("message must decode");

        assert_eq!(decoded, envelope);
    }
}
