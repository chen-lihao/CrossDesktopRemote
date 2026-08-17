package com.crossdesktopremote.controlplane.signaling;

import java.util.Locale;
import java.util.Optional;

enum SignalingRole {
	HOST,
	CONTROLLER;

	static Optional<SignalingRole> parse(String value) {
		if (value == null) {
			return Optional.empty();
		}

		try {
			return Optional.of(valueOf(value.toUpperCase(Locale.ROOT)));
		} catch (IllegalArgumentException ignored) {
			return Optional.empty();
		}
	}

	SignalingRole peerRole() {
		return this == HOST ? CONTROLLER : HOST;
	}

	String wireName() {
		return name().toLowerCase(Locale.ROOT);
	}
}
