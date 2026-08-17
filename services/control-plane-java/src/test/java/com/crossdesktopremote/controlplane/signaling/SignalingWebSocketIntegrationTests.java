package com.crossdesktopremote.controlplane.signaling;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ActiveProfiles("test")
class SignalingWebSocketIntegrationTests {

	@LocalServerPort
	private int port;

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
