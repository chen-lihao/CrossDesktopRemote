package com.crossdesktopremote.controlplane.signaling;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class SignalingRoleTests {

	@Test
	void parsesOnlyKnownRoles() {
		assertThat(SignalingRole.parse("host")).contains(SignalingRole.HOST);
		assertThat(SignalingRole.parse("CONTROLLER")).contains(SignalingRole.CONTROLLER);
		assertThat(SignalingRole.parse("observer")).isEmpty();
		assertThat(SignalingRole.parse(null)).isEmpty();
	}

	@Test
	void resolvesTheOppositeRole() {
		assertThat(SignalingRole.HOST.peerRole()).isEqualTo(SignalingRole.CONTROLLER);
		assertThat(SignalingRole.CONTROLLER.peerRole()).isEqualTo(SignalingRole.HOST);
	}
}
