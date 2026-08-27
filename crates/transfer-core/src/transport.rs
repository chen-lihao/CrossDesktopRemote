use std::sync::Arc;

use crate::{TransferError, TransferErrorKind, TransferResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportKind {
    WebRtc,
    Quic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferLane {
    Clipboard,
    Control,
    File(u16),
}

pub trait TransferTransport: Send + Sync {
    fn kind(&self) -> TransportKind;
    fn max_payload_bytes(&self) -> usize;
    fn buffered_amount(&self, lane: TransferLane) -> TransferResult<u64>;
    fn send(&self, lane: TransferLane, payload: &[u8]) -> TransferResult<()>;
}

pub type SendFrameCallback =
    Arc<dyn Fn(TransferLane, &[u8]) -> TransferResult<()> + Send + Sync + 'static>;
pub type BufferedAmountCallback =
    Arc<dyn Fn(TransferLane) -> TransferResult<u64> + Send + Sync + 'static>;

pub struct WebRtcTransport {
    max_payload_bytes: usize,
    max_buffered_bytes: u64,
    send_frame: SendFrameCallback,
    buffered_amount: BufferedAmountCallback,
}

impl WebRtcTransport {
    pub fn new(
        max_payload_bytes: usize,
        max_buffered_bytes: u64,
        send_frame: SendFrameCallback,
        buffered_amount: BufferedAmountCallback,
    ) -> TransferResult<Self> {
        if max_payload_bytes == 0
            || max_payload_bytes
                > usize::try_from(crate::DEFAULT_MAX_WIRE_MESSAGE_BYTES)
                    .expect("u32 must fit usize")
            || max_buffered_bytes < max_payload_bytes as u64
        {
            return Err(TransferError::new(
                TransferErrorKind::InvalidArgument,
                "invalid WebRTC transport limits",
            ));
        }
        Ok(Self {
            max_payload_bytes,
            max_buffered_bytes,
            send_frame,
            buffered_amount,
        })
    }
}

impl TransferTransport for WebRtcTransport {
    fn kind(&self) -> TransportKind {
        TransportKind::WebRtc
    }

    fn max_payload_bytes(&self) -> usize {
        self.max_payload_bytes
    }

    fn buffered_amount(&self, lane: TransferLane) -> TransferResult<u64> {
        (self.buffered_amount)(lane)
    }

    fn send(&self, lane: TransferLane, payload: &[u8]) -> TransferResult<()> {
        if payload.is_empty() || payload.len() > self.max_payload_bytes {
            return Err(TransferError::new(
                TransferErrorKind::LimitExceeded,
                "transport payload is empty or exceeds the WebRTC message limit",
            ));
        }
        let buffered = self.buffered_amount(lane)?;
        if buffered.saturating_add(payload.len() as u64) > self.max_buffered_bytes {
            return Err(TransferError::new(
                TransferErrorKind::Backpressure,
                "WebRTC data channel is above the transfer backpressure limit",
            ));
        }
        (self.send_frame)(lane, payload)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    #[test]
    fn enforces_message_size_and_backpressure() {
        let sent = Arc::new(AtomicUsize::new(0));
        let sent_for_callback = Arc::clone(&sent);
        let transport = WebRtcTransport::new(
            16,
            32,
            Arc::new(move |_, payload| {
                sent_for_callback.fetch_add(payload.len(), Ordering::Relaxed);
                Ok(())
            }),
            Arc::new(|_| Ok(0)),
        )
        .expect("transport");

        transport
            .send(TransferLane::File(1), &[1; 16])
            .expect("send");
        assert_eq!(sent.load(Ordering::Relaxed), 16);
        assert_eq!(
            transport
                .send(TransferLane::File(1), &[1; 17])
                .expect_err("oversized payload must fail")
                .kind,
            TransferErrorKind::LimitExceeded
        );

        let congested = WebRtcTransport::new(16, 32, Arc::new(|_, _| Ok(())), Arc::new(|_| Ok(24)))
            .expect("transport");
        assert_eq!(
            congested
                .send(TransferLane::File(1), &[1; 16])
                .expect_err("backpressure must fail")
                .kind,
            TransferErrorKind::Backpressure
        );
    }
}
