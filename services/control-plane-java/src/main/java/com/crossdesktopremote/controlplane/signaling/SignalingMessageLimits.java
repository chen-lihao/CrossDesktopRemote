package com.crossdesktopremote.controlplane.signaling;

/** Limit for a complete UTF-8 JSON envelope, including signed SDP metadata. */
final class SignalingMessageLimits {
	static final int MAX_TEXT_BYTES = 64 * 1024;
	static final String TOO_LARGE_REASON = "SIGNALING_MESSAGE_TOO_LARGE";

	private SignalingMessageLimits() {}
}
