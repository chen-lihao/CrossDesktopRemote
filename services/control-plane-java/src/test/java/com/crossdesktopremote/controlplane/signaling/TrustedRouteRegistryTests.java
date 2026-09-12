package com.crossdesktopremote.controlplane.signaling;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import org.junit.jupiter.api.Test;
import org.springframework.web.socket.WebSocketSession;

class TrustedRouteRegistryTests {

	@Test
	void routesOneControllerAtATimeAndKeepsHostOnlineAfterLeave() {
		var registry = new TrustedRouteRegistry(new HostSessionArbiter());
		var host = openSession();
		var controller = openSession();
		var secondController = openSession();

		assertThat(registry.registerHost("CDR2-1234-5678-9ABC-DEFG-HJKM-NPQR", host)).isTrue();
		var route = registry.joinController(
				"CDR2-1234-5678-9ABC-DEFG-HJKM-NPQR", controller);
		assertThat(route).isPresent();
		assertThat(registry.peer(host)).contains(controller);
		assertThat(registry.peer(controller)).contains(host);
		assertThat(registry.joinController(
				"CDR2-1234-5678-9ABC-DEFG-HJKM-NPQR", secondController)).isEmpty();

		assertThat(registry.leave(controller)).contains(host);
		assertThat(registry.joinController(
				"CDR2-1234-5678-9ABC-DEFG-HJKM-NPQR", secondController)).isPresent();
	}

	@Test
	void removesHostRegistrationWhenHostLeaves() {
		var registry = new TrustedRouteRegistry(new HostSessionArbiter());
		var host = openSession();
		var controller = openSession();
		assertThat(registry.registerHost("CDR2-1234-5678-9ABC-DEFG-HJKM-NPQR", host)).isTrue();

		registry.leave(host);

		assertThat(registry.joinController(
				"CDR2-1234-5678-9ABC-DEFG-HJKM-NPQR", controller)).isEmpty();
	}

	@Test
	void arbitratesConnectionCodeAndTrustedControllersAsOneHostSession() {
		var arbiter = new HostSessionArbiter();
		var trusted = new TrustedRouteRegistry(arbiter);
		var rooms = new SignalingRoomRegistry(arbiter);
		var host = openSession();
		var trustedController = openSession();
		var codeController = openSession();
		var invitation = rooms.createHostInvitation(host);
		var machineCode = "CDR2-1234-5678-9ABC-DEFG-HJKM-NPQR";
		assertThat(trusted.registerHost(machineCode, host)).isTrue();

		assertThat(trusted.joinController(machineCode, trustedController)).isPresent();
		assertThat(rooms.join(
				invitation.roomCode(),
				SignalingRole.CONTROLLER,
				codeController)).isEqualTo(SignalingRoomRegistry.JoinResult.HOST_BUSY);

		trusted.leave(trustedController);
		assertThat(rooms.join(
				invitation.roomCode(),
				SignalingRole.CONTROLLER,
				codeController)).isEqualTo(SignalingRoomRegistry.JoinResult.JOINED);
		assertThat(trusted.joinController(machineCode, trustedController)).isEmpty();
	}

	private WebSocketSession openSession() {
		var session = mock(WebSocketSession.class);
		when(session.isOpen()).thenReturn(true);
		return session;
	}
}
