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
	void createsAndAtomicallyRotatesAServerOwnedInvitation() {
		var now = new AtomicLong(1_000);
		var registry = new SignalingRoomRegistry(now::get, Duration.ofMinutes(5), Duration.ofMinutes(1), 5, 20);
		var host = openSession("host", "192.168.1.10");
		var controller = openSession("controller", "192.168.1.20");

		var initial = registry.createHostInvitation(host);
		assertThat(initial.roomCode()).matches("[0-9]{6}");
		assertThat(initial.expiresInMillis()).isEqualTo(Duration.ofMinutes(5).toMillis());

		var rotated = registry.rotateHostInvitation(
				initial.roomCode(), initial.leaseId(), initial.generation(), host).orElseThrow();
		assertThat(rotated.roomCode()).isNotEqualTo(initial.roomCode());
		assertThat(rotated.generation()).isEqualTo(2);
		assertThat(registry.join(initial.roomCode(), SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.INVALID_ROOM);
		assertThat(registry.join(rotated.roomCode(), SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);
	}

	@Test
	void refusesToRotateAnInvitationAfterAControllerConsumesIt() {
		var registry = new SignalingRoomRegistry();
		var host = openSession("host", "192.168.1.10");
		var controller = openSession("controller", "192.168.1.20");
		var invitation = registry.createHostInvitation(host);

		assertThat(registry.join(invitation.roomCode(), SignalingRole.CONTROLLER, controller))
				.isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);
		assertThat(registry.rotateHostInvitation(
				invitation.roomCode(), invitation.leaseId(), invitation.generation(), host)).isEmpty();
		assertThat(registry.peer(invitation.roomCode(), SignalingRole.HOST)).contains(controller);
	}

	@Test
	void rejectsAStaleInvitationLeaseRotation() {
		var registry = new SignalingRoomRegistry();
		var host = openSession("host", "192.168.1.10");
		var invitation = registry.createHostInvitation(host);

		assertThat(registry.rotateHostInvitation(
				invitation.roomCode(), "stale-lease", invitation.generation(), host)).isEmpty();
		assertThat(registry.rotateHostInvitation(
				invitation.roomCode(), invitation.leaseId(), invitation.generation() + 1, host)).isEmpty();
		assertThat(registry.invitationRemainingMillis(
				invitation.roomCode(), SignalingRole.HOST, host)).isPresent();
	}

	@Test
	void acceptsLeaseBoundRotationFromClientsWithoutAGenerationField() {
		var registry = new SignalingRoomRegistry();
		var host = openSession("host", "192.168.1.10");
		var invitation = registry.createHostInvitation(host);

		var rotated = registry.rotateHostInvitation(
				invitation.roomCode(), invitation.leaseId(), -1, host).orElseThrow();

		assertThat(rotated.generation()).isEqualTo(invitation.generation() + 1);
		assertThat(rotated.roomCode()).isNotEqualTo(invitation.roomCode());
	}

	@Test
	void expiresAHostRegistrationAndConsumesAValidCodeOnce() {
		var now = new AtomicLong(1_000);
		var registry = new SignalingRoomRegistry(now::get, Duration.ofMinutes(5), Duration.ofMinutes(1), 5, 20);
		var host = openSession("host", "192.168.1.10");
		var controller = openSession("controller", "192.168.1.20");

		assertThat(registry.join("123456", SignalingRole.HOST, host))
				.isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);
		assertThat(registry.invitationRemainingMillis("123456", SignalingRole.HOST, host))
				.hasValue(Duration.ofMinutes(5).toMillis());
		assertThat(registry.invitationRemainingMillis("123456", SignalingRole.CONTROLLER, controller))
				.isEmpty();
		now.addAndGet(1_000);
		assertThat(registry.invitationRemainingMillis("123456", SignalingRole.HOST, host))
				.hasValue(Duration.ofMinutes(5).minusSeconds(1).toMillis());
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
