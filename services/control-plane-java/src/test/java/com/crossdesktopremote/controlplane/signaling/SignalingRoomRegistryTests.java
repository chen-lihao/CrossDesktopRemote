package com.crossdesktopremote.controlplane.signaling;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.net.InetSocketAddress;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicLong;

import org.junit.jupiter.api.Test;
import org.springframework.web.socket.WebSocketSession;

class SignalingRoomRegistryTests {

	@Test
	void expiresAHostRegistrationAndConsumesAValidCodeOnce() {
		var now = new AtomicLong(1_000);
		var registry = new SignalingRoomRegistry(now::get, Duration.ofMinutes(5), Duration.ofMinutes(1), 5, 20);
		var host = openSession("host", "192.168.1.10");
		var controller = openSession("controller", "192.168.1.20");

		assertThat(registry.join("123456", SignalingRole.HOST, host))
				.isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);
		assertThat(registry.join("123456", SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);
		assertThat(registry.join("123456", SignalingRole.CONTROLLER, openSession("other", "192.168.1.21")))
				.isEqualTo(SignalingRoomRegistry.JoinResult.CODE_CONSUMED);
		now.addAndGet(Duration.ofMinutes(5).toMillis());
		assertThat(registry.peer("123456", SignalingRole.HOST)).contains(controller);

		registry.leave("123456", SignalingRole.HOST, host);
		assertThat(registry.join("123456", SignalingRole.HOST, host))
				.isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);
		now.addAndGet(Duration.ofMinutes(5).toMillis());
		assertThat(registry.join("123456", SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.INVALID_ROOM);
	}

	@Test
	void rateLimitsRepeatedInvalidControllerCodesPerInvitation() {
		var now = new AtomicLong(1_000);
		var registry = new SignalingRoomRegistry(now::get, Duration.ofMinutes(5), Duration.ofMinutes(1), 5, 20);
		var controller = openSession("controller", "192.168.1.30");

		for (var attempt = 0; attempt < 5; attempt++) {
			assertThat(registry.join("999999", SignalingRole.CONTROLLER, controller))
					.isEqualTo(SignalingRoomRegistry.JoinResult.INVALID_ROOM);
		}
		assertThat(registry.join("999999", SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.RATE_LIMITED_INVITATION);
		assertThat(registry.rejectionReason(
				SignalingRoomRegistry.JoinResult.RATE_LIMITED_INVITATION,
				"999999",
				controller)).isEqualTo("RATE_LIMITED_INVITATION:60");

		var host = openSession("host", "192.168.1.10");
		assertThat(registry.join("123456", SignalingRole.HOST, host))
				.isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);
		assertThat(registry.join("123456", SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);

		now.addAndGet(Duration.ofMinutes(1).toMillis());
		assertThat(registry.join("999999", SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.INVALID_ROOM);
	}

	@Test
	void rateLimitsCodeCyclingAcrossInvitationsPerSourceAddress() {
		var now = new AtomicLong(1_000);
		var registry = new SignalingRoomRegistry(now::get, Duration.ofMinutes(5), Duration.ofMinutes(1), 5, 8);
		var controller = openSession("controller", "192.168.1.31");

		for (var attempt = 0; attempt < 8; attempt++) {
			assertThat(registry.join(String.format("%06d", 900_000 + attempt), SignalingRole.CONTROLLER, controller))
					.isEqualTo(SignalingRoomRegistry.JoinResult.INVALID_ROOM);
		}
		assertThat(registry.join("800000", SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.RATE_LIMITED_SOURCE);
		assertThat(registry.rejectionReason(
				SignalingRoomRegistry.JoinResult.RATE_LIMITED_SOURCE,
				"800000",
				controller)).isEqualTo("RATE_LIMITED_SOURCE:60");

		now.addAndGet(Duration.ofMinutes(1).toMillis());
		assertThat(registry.join("800000", SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.INVALID_ROOM);
	}

	private WebSocketSession openSession(String id, String address) {
		var session = mock(WebSocketSession.class);
		when(session.getId()).thenReturn(id);
		when(session.getRemoteAddress()).thenReturn(new InetSocketAddress(address, 40000));
		when(session.isOpen()).thenReturn(true);
		return session;
	}
}
