package com.crossdesktopremote.controlplane.signaling;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.ActiveProfiles;

// Exercise the production WebSocket endpoint and embedded Tomcat, without
// unrelated database services. Signaling registries are process-local.
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
		"spring.autoconfigure.exclude=org.springframework.boot.jdbc.autoconfigure.DataSourceAutoConfiguration,"
				+ "org.springframework.boot.flyway.autoconfigure.FlywayAutoConfiguration,"
				+ "org.springframework.boot.hibernate.autoconfigure.HibernateJpaAutoConfiguration"
})
@ActiveProfiles("test")
class SignalingWebSocketIntegrationTests {

	@LocalServerPort
	private int port;

	@Test
	void allocatesAndRotatesAHostInvitationWithoutReconnecting() throws Exception {
		var hostMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

		var host = connectHost(client, hostMessages);
		var ready = hostMessages.next();
		assertThat(ready).contains("\"type\":\"ready\"");
		assertThat(ready).contains("\"invitation-rotation\"");
		assertThat(ready).contains("\"capability-manifest-v1\"");
		var initialCode = roomCode(ready);

		var leaseId = jsonString(ready, "invitationLeaseId");
		host.sendText("{\"type\":\"rotate-invitation\",\"requestId\":\"test-1\","
				+ "\"leaseId\":\"" + leaseId + "\",\"generation\":1}", true).join();
		var rotated = hostMessages.next();
		assertThat(rotated).contains("\"type\":\"invitation-rotated\"");
		assertThat(rotated).contains("\"requestId\":\"test-1\"");
		assertThat(roomCode(rotated)).isNotEqualTo(initialCode);
		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	@Test
	void relaysAllowedMessagesBetweenHostAndController() throws Exception {
		var hostMessages = new RecordingListener();
		var controllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

		var host = connect(client, "123456", "host", hostMessages);
		assertThat(hostMessages.next()).contains("\"type\":\"ready\"");

		var controller = connect(client, "123456", "controller", controllerMessages);
		assertThat(controllerMessages.next()).contains("\"type\":\"ready\"");
		assertThat(hostMessages.next()).contains("\"type\":\"peer-joined\"");
		assertThat(controllerMessages.next()).contains("\"type\":\"peer-joined\"");

		host.sendText("{\"type\":\"offer\",\"sdp\":\"prototype-sdp\"}", true).join();
		assertThat(controllerMessages.next()).isEqualTo("{\"type\":\"offer\",\"sdp\":\"prototype-sdp\"}");
		controller.sendText("{\"type\":\"trusted-session-authorization-accepted\","
				+ "\"acknowledgement\":{\"policyRevision\":7}}", true).join();
		assertThat(hostMessages.next()).isEqualTo(
				"{\"type\":\"trusted-session-authorization-accepted\","
						+ "\"acknowledgement\":{\"policyRevision\":7}}");

		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		controller.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	@Test
	void endsAPeerSessionAndReusesTheHostSocketWithANewInvitation() throws Exception {
		var hostMessages = new RecordingListener();
		var controllerMessages = new RecordingListener();
		var nextControllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

		var host = connectHost(client, hostMessages);
		var initialReady = hostMessages.next();
		assertThat(initialReady).contains("persistent-signaling-session-v1");
		var controller = connect(
				client, roomCode(initialReady), "controller", controllerMessages);
		assertThat(controllerMessages.next()).contains("\"type\":\"ready\"");
		assertThat(hostMessages.next()).contains("\"type\":\"peer-joined\"");
		assertThat(controllerMessages.next()).contains("\"type\":\"peer-joined\"");

		controller.sendText("{\"type\":\"end-session\"}", true).join();

		assertThat(hostMessages.next()).contains("\"type\":\"peer-left\"");
		var rotated = hostMessages.next();
		assertThat(rotated)
				.contains("\"type\":\"invitation-updated\"")
				.contains("\"reason\":\"session-ended\"");
		assertThat(controllerMessages.next()).contains("\"type\":\"session-ended\"");

		var nextController = connect(
				client, roomCode(rotated), "controller", nextControllerMessages);
		assertThat(nextControllerMessages.next()).contains("\"type\":\"ready\"");
		assertThat(hostMessages.next()).contains("\"type\":\"peer-joined\"");
		assertThat(nextControllerMessages.next()).contains("\"type\":\"peer-joined\"");

		nextController.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		controller.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	@Test
	void announcesControllerPlatformCapabilitiesBeforeHostCaptureStarts() throws Exception {
		var hostMessages = new RecordingListener();
		var controllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

		var host = connectHost(client, hostMessages);
		var room = roomCode(hostMessages.next());
		var controller = client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port
						+ "/ws/signaling?room=" + room
						+ "&role=controller&platform=windows"
						+ "&deviceId=0123456789abcdef0123456789abcdef"
						+ "&capabilities=active-content-geometry-v2"
						+ "&capability=active-content-geometry-v2"
						+ "&capability=text-clipboard-v1"), controllerMessages)
				.join();

		assertThat(controllerMessages.next()).contains("\"type\":\"ready\"");
		assertThat(hostMessages.next())
				.contains("\"peerDeviceId\":\"0123456789abcdef0123456789abcdef\"")
				.contains("\"peerPlatform\":\"windows\"")
				.contains("active-content-geometry-v2")
				.contains("text-clipboard-v1");
		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		controller.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	@Test
	void relaysTheCompleteWindowsTrustedCapabilityManifest() throws Exception {
		var hostMessages = new RecordingListener();
		var controllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
		var capabilities = List.of(
				"display-switch-transaction-v1",
				"active-content-geometry-v2",
				"active-content-geometry-v3",
				"texture-crop-rendering-v1",
				"text-clipboard-v1",
				"explicit-file-transfer-v1",
				"destination-leased-file-paste-v1",
				"atomic-shortcut-v1",
				"scoped-input-reset-v1",
				"video-policy-v2",
				"device-identity-v1",
				"trusted-device-auth-v1",
				"signed-webrtc-binding-v1",
				"trust-lease-renewal-v1",
				"trusted-pairing-transaction-v1",
				"decoupled-trust-policy-v1",
				"host-session-authorization-v1",
				"directional-file-permissions-v1",
				"trusted-auth-suite-v2");

		var host = connectHost(client, hostMessages);
		var room = roomCode(hostMessages.next());
		var capabilityQuery = String.join("&capability=", capabilities);
		var controller = client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port
						+ "/ws/signaling?room=" + room
						+ "&role=controller&platform=windows"
						+ "&capabilities=" + capabilities.get(0)
						+ "&capability=" + capabilityQuery), controllerMessages)
				.join();

		assertThat(controllerMessages.next()).contains("\"type\":\"ready\"");
		var joined = hostMessages.next();
		assertThat(joined).contains("\"type\":\"peer-joined\"");
		for (var capability : capabilities) {
			assertThat(joined).contains(capability);
		}
		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		controller.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	@Test
	void trustedRoutingKeepsBothCompleteCapabilityManifests() throws Exception {
		var hostMessages = new RecordingListener();
		var controllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
		var machineCode = "CDR2-ABCD-EFGH-JKMN-PQRS";
		var trustedCapabilities = List.of(
				"device-identity-v1",
				"trusted-device-auth-v1",
				"signed-webrtc-binding-v1",
				"trust-lease-renewal-v1",
				"trusted-pairing-transaction-v1",
				"decoupled-trust-policy-v1",
				"host-session-authorization-v1",
				"directional-file-permissions-v1",
				"trusted-auth-suite-v2");
		var hostCapabilities = new java.util.ArrayList<>(trustedCapabilities);
		hostCapabilities.addAll(List.of(
				"text-clipboard-v1",
				"explicit-file-transfer-v1",
				"destination-leased-file-paste-v1",
				"atomic-shortcut-v1",
				"scoped-input-reset-v1",
				"video-policy-v2"));
		var controllerCapabilities = new java.util.ArrayList<>(hostCapabilities);
		controllerCapabilities.addAll(List.of(
				"display-switch-transaction-v1",
				"active-content-geometry-v2",
				"active-content-geometry-v3",
				"texture-crop-rendering-v1"));

		var host = client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port
						+ "/ws/signaling?role=host&trustedMachineCode=" + machineCode
						+ capabilityQuery(hostCapabilities)), hostMessages)
				.join();
		assertThat(hostMessages.next()).contains("\"type\":\"ready\"");
		var controller = client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port
						+ "/ws/signaling?role=controller&trustedTarget=" + machineCode
						+ capabilityQuery(controllerCapabilities)), controllerMessages)
				.join();

		assertThat(controllerMessages.next())
				.contains("\"type\":\"ready\"")
				.contains("\"authenticationMode\":\"trusted\"");
		var hostJoined = hostMessages.next();
		var controllerJoined = controllerMessages.next();
		for (var capability : controllerCapabilities) {
			assertThat(hostJoined).contains(capability);
		}
		for (var capability : hostCapabilities) {
			assertThat(controllerJoined).contains(capability);
		}
		controller.sendText("{\"type\":\"trusted-auth-start\",\"authSuiteVersion\":2}", true).join();
		assertThat(hostMessages.next()).isEqualTo(
				"{\"type\":\"trusted-auth-start\",\"authSuiteVersion\":2}");
		controller.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	@Test
	void relaysLargeTrustedOffersAndFragmentedAnswersWithoutChangingTheirContents() throws Exception {
		var hostMessages = new RecordingListener();
		var controllerMessages = new RecordingListener();
		var client = HttpClient.newHttpClient();
		var machineCode = "CDR2-1234-5678-9ABC-DEFG";
		var capabilities = List.of(
				"device-identity-v1", "trusted-device-auth-v1", "signed-webrtc-binding-v1");
		var host = client.newWebSocketBuilder()
				.buildAsync(URI.create("ws://127.0.0.1:" + port
						+ "/ws/signaling?role=host&trustedMachineCode=" + machineCode
						+ capabilityQuery(capabilities)), hostMessages).join();
		try {
			assertThat(hostMessages.next()).contains("\"type\":\"ready\"");
			var controller = connectTrustedController(client, machineCode, capabilities, controllerMessages);
			try {
				assertThat(controllerMessages.next()).contains("\"type\":\"ready\"");
				assertThat(hostMessages.next()).contains("\"type\":\"peer-joined\"");
				assertThat(controllerMessages.next()).contains("\"type\":\"peer-joined\"");
				// 8356 bytes reproduces the captured Windows failure. The relay
				// must also preserve a full-size signed envelope byte for byte.
				for (var size : List.of(8356, 32 * 1024, 64 * 1024)) {
					var offer = asciiMessage("trusted-offer", size);
					host.sendText(offer, true).join();
					assertThat(controllerMessages.next()).isEqualTo(offer);
					var answer = asciiMessage("trusted-answer", size);
					for (var offset = 0; offset < answer.length(); offset += 3000) {
						var end = Math.min(offset + 3000, answer.length());
						controller.sendText(answer.substring(offset, end), end == answer.length()).join();
					}
					assertThat(hostMessages.next()).isEqualTo(answer);
				}
			} finally {
				controller.abort();
			}
		} finally {
			host.abort();
		}
	}

	@Test
	void rejectsOversizedCompleteMessagesIncludingMultibyteAndFragmentedPayloads() throws Exception {
		var client = HttpClient.newHttpClient();
		for (var payload : List.of(
				asciiMessage("trusted-offer", 64 * 1024 + 1),
				"{\"type\":\"trusted-offer\",\"sdp\":\"" + "界".repeat(23000) + "\"}")) {
			assertThat(payload.getBytes(StandardCharsets.UTF_8).length).isGreaterThan(64 * 1024);
			for (var fragmented : List.of(false, true)) {
				var messages = new RecordingListener();
				var socket = connectHost(client, messages);
				try {
					assertThat(messages.next()).contains("\"type\":\"ready\"");
					if (fragmented) {
						var split = payload.length() / 2;
						socket.sendText(payload.substring(0, split), false).join();
						socket.sendText(payload.substring(split), true).join();
					} else {
						socket.sendText(payload, true).join();
					}
					assertThat(messages.nextClose()).startsWith("1009:");
				} finally {
					socket.abort();
				}
			}
		}
	}

	private static String asciiMessage(String type, int bytes) {
		var prefix = "{\"type\":\"" + type + "\",\"sdp\":\"";
		return prefix + "a".repeat(bytes - prefix.length() - 2) + "\"}";
	}

	@Test
	void endsATrustedRouteWithoutUnregisteringTheHost() throws Exception {
		var hostMessages = new RecordingListener();
		var controllerMessages = new RecordingListener();
		var nextControllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
		var machineCode = "CDR2-ABCD-EFGH-JKMN-PQRS";
		var capabilities = List.of(
				"device-identity-v1",
				"trusted-device-auth-v1",
				"signed-webrtc-binding-v1");

		var host = client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port
						+ "/ws/signaling?role=host&trustedMachineCode=" + machineCode
						+ capabilityQuery(capabilities)), hostMessages)
				.join();
		assertThat(hostMessages.next()).contains("\"type\":\"ready\"");
		var controller = connectTrustedController(
				client, machineCode, capabilities, controllerMessages);
		assertThat(controllerMessages.next()).contains("\"type\":\"ready\"");
		assertThat(hostMessages.next()).contains("\"type\":\"peer-joined\"");
		assertThat(controllerMessages.next()).contains("\"type\":\"peer-joined\"");

		controller.sendText("{\"type\":\"end-session\"}", true).join();

		assertThat(hostMessages.next()).contains("\"type\":\"peer-left\"");
		assertThat(controllerMessages.next()).contains("\"type\":\"session-ended\"");

		var nextController = connectTrustedController(
				client, machineCode, capabilities, nextControllerMessages);
		assertThat(nextControllerMessages.next()).contains("\"type\":\"ready\"");
		assertThat(hostMessages.next()).contains("\"type\":\"peer-joined\"");
		assertThat(nextControllerMessages.next()).contains("\"type\":\"peer-joined\"");

		nextController.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		controller.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	@Test
	void rejectsAnOversizedCapabilityManifestWithoutPartialNegotiation() throws Exception {
		var messages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
		var query = new StringBuilder("ws://127.0.0.1:")
				.append(port)
				.append("/ws/signaling?room=123456&role=controller");
		for (var index = 0; index <= 64; index++) {
			query.append("&capability=feature-").append(index);
		}

		client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create(query.toString()), messages)
				.join();

		assertThat(messages.nextClose()).contains("CAPABILITY_MANIFEST_TOO_LARGE");
	}

	@Test
	void decodesLegacyPercentEncodedCapabilityLists() throws Exception {
		var hostMessages = new RecordingListener();
		var controllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

		var host = connectHost(client, hostMessages);
		var room = roomCode(hostMessages.next());
		var controller = client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port
						+ "/ws/signaling?room=" + room
						+ "&role=controller&platform=windows"
						+ "&capabilities=active-content-geometry-v2%2Ctext-clipboard-v1"), controllerMessages)
				.join();

		assertThat(controllerMessages.next()).contains("\"type\":\"ready\"");
		assertThat(hostMessages.next())
				.contains("active-content-geometry-v2")
				.contains("text-clipboard-v1");
		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		controller.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	@Test
	void rejectsAControllerUntilTheHostRegistersTheCode() throws Exception {
		var controllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

		connect(client, "777777", "controller", controllerMessages);
		assertThat(controllerMessages.nextClose()).contains("INVALID_ROOM");
	}

	@Test
	void consumesAConnectionCodeAfterOneControllerJoins() throws Exception {
		var hostMessages = new RecordingListener();
		var firstControllerMessages = new RecordingListener();
		var secondControllerMessages = new RecordingListener();
		var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

		var host = connect(client, "654321", "host", hostMessages);
		assertThat(hostMessages.next()).contains("\"type\":\"ready\"");
		var firstController = connect(client, "654321", "controller", firstControllerMessages);
		assertThat(firstControllerMessages.next()).contains("\"type\":\"ready\"");
		assertThat(hostMessages.next()).contains("\"type\":\"peer-joined\"");
		assertThat(firstControllerMessages.next()).contains("\"type\":\"peer-joined\"");

		var secondController = connect(client, "654321", "controller", secondControllerMessages);
		assertThat(secondControllerMessages.nextClose()).contains("CODE_CONSUMED");
		firstController.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
		host.sendClose(WebSocket.NORMAL_CLOSURE, "test complete").join();
	}

	private WebSocket connect(HttpClient client, String room, String role, RecordingListener listener) {
		return client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port + "/ws/signaling?room=" + room + "&role=" + role), listener)
				.join();
	}

	private WebSocket connectHost(HttpClient client, RecordingListener listener) {
		return client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port + "/ws/signaling?role=host&protocol=2"), listener)
				.join();
	}

	private WebSocket connectTrustedController(
			HttpClient client,
			String machineCode,
			List<String> capabilities,
			RecordingListener listener) {
		return client.newWebSocketBuilder()
				.connectTimeout(Duration.ofSeconds(5))
				.buildAsync(URI.create("ws://127.0.0.1:" + port
						+ "/ws/signaling?role=controller&trustedTarget=" + machineCode
						+ capabilityQuery(capabilities)), listener)
				.join();
	}

	private String capabilityQuery(List<String> capabilities) {
		return "&capability=" + String.join("&capability=", capabilities);
	}

	private String roomCode(String message) {
		var marker = "\"room\":\"";
		var start = message.indexOf(marker);
		return message.substring(start + marker.length(), start + marker.length() + 6);
	}

	private String jsonString(String message, String name) {
		var marker = "\"" + name + "\":\"";
		var start = message.indexOf(marker) + marker.length();
		return message.substring(start, message.indexOf('"', start));
	}

	private static final class RecordingListener implements WebSocket.Listener {
		private final BlockingQueue<String> messages = new LinkedBlockingQueue<>();
		private final BlockingQueue<String> closeReasons = new LinkedBlockingQueue<>();
		private final StringBuilder currentMessage = new StringBuilder();

		@Override
		public void onOpen(WebSocket webSocket) {
			webSocket.request(1);
		}

		@Override
		public CompletionStage<?> onText(WebSocket webSocket, CharSequence data, boolean last) {
			currentMessage.append(data);
			if (last) {
				messages.add(currentMessage.toString());
				currentMessage.setLength(0);
			}
			webSocket.request(1);
			return CompletableFuture.completedFuture(null);
		}

		@Override
		public CompletionStage<?> onBinary(WebSocket webSocket, ByteBuffer data, boolean last) {
			webSocket.request(1);
			return CompletableFuture.completedFuture(null);
		}

		@Override
		public CompletionStage<?> onClose(WebSocket webSocket, int statusCode, String reason) {
			closeReasons.add(statusCode + ":" + reason);
			return CompletableFuture.completedFuture(null);
		}

		String next() throws InterruptedException {
			return messages.poll(5, TimeUnit.SECONDS);
		}

		String nextClose() throws InterruptedException {
			return closeReasons.poll(5, TimeUnit.SECONDS);
		}
	}
}
