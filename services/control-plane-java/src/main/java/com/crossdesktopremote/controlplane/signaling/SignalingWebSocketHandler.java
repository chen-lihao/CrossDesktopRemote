package com.crossdesktopremote.controlplane.signaling;

import java.io.IOException;
import java.util.Map;
import java.util.Set;

import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;
import org.springframework.web.util.UriComponentsBuilder;
import tools.jackson.databind.ObjectMapper;

@Component
final class SignalingWebSocketHandler extends TextWebSocketHandler {

	private static final int MAX_MESSAGE_BYTES = 64 * 1024;
	private static final Set<String> ALLOWED_MESSAGE_TYPES = Set.of(
			"approve",
			"answer",
			"candidate",
			"hangup",
			"offer",
			"reject");
	private static final String ROOM_ATTRIBUTE = "crossdesktop.room";
	private static final String ROLE_ATTRIBUTE = "crossdesktop.role";

	private final SignalingRoomRegistry rooms;
	private final ObjectMapper objectMapper;

	SignalingWebSocketHandler(SignalingRoomRegistry rooms, ObjectMapper objectMapper) {
		this.rooms = rooms;
		this.objectMapper = objectMapper;
	}

	@Override
	public void afterConnectionEstablished(WebSocketSession session) throws Exception {
		var requestUri = session.getUri();
		if (requestUri == null) {
			session.close(CloseStatus.BAD_DATA.withReason("Missing request URI"));
			return;
		}

		var query = UriComponentsBuilder.fromUri(requestUri).build().getQueryParams();
		var roomCode = query.getFirst("room");
		var role = SignalingRole.parse(query.getFirst("role"));
		if (!StringUtils.hasText(roomCode) || role.isEmpty()) {
			session.close(CloseStatus.BAD_DATA.withReason("Invalid room or role"));
			return;
		}

		var result = rooms.join(roomCode, role.get(), session);
		if (result != SignalingRoomRegistry.JoinResult.JOINED) {
			session.close(CloseStatus.POLICY_VIOLATION.withReason(result.name()));
			return;
		}

		session.getAttributes().put(ROOM_ATTRIBUTE, roomCode);
		session.getAttributes().put(ROLE_ATTRIBUTE, role.get());
		sendJson(session, Map.of("type", "ready", "room", roomCode, "role", role.get().wireName()));
		rooms.peer(roomCode, role.get()).ifPresent(peer -> {
			sendJsonQuietly(peer, Map.of("type", "peer-joined", "role", role.get().wireName()));
			sendJsonQuietly(session, Map.of("type", "peer-joined", "role", role.get().peerRole().wireName()));
		});
	}

	@Override
	protected void handleTextMessage(WebSocketSession session, TextMessage message) throws Exception {
		if (message.getPayloadLength() > MAX_MESSAGE_BYTES) {
			session.close(CloseStatus.TOO_BIG_TO_PROCESS);
			return;
		}

		var payload = objectMapper.readTree(message.getPayload());
		var messageType = payload.path("type").asText();
		if (!payload.isObject() || !ALLOWED_MESSAGE_TYPES.contains(messageType)) {
			session.close(CloseStatus.BAD_DATA.withReason("Unsupported signaling message"));
			return;
		}

		var roomCode = roomCode(session);
		var role = role(session);
		if (roomCode == null || role == null) {
			session.close(CloseStatus.POLICY_VIOLATION);
			return;
		}

		var peer = rooms.peer(roomCode, role);
		if (peer.isEmpty()) {
			sendJson(session, Map.of("type", "peer-unavailable"));
			return;
		}

		sendText(peer.get(), message);
	}

	@Override
	public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
		var roomCode = roomCode(session);
		var role = role(session);
		if (roomCode == null || role == null) {
			return;
		}

		var peer = rooms.peer(roomCode, role);
		rooms.leave(roomCode, role, session);
		peer.ifPresent(value -> sendJsonQuietly(value, Map.of("type", "peer-left")));
	}

	@Override
	public void handleTransportError(WebSocketSession session, Throwable exception) throws Exception {
		if (session.isOpen()) {
			session.close(CloseStatus.SERVER_ERROR);
		}
	}

	private void sendJson(WebSocketSession session, Map<String, ?> payload) throws IOException {
		sendText(session, new TextMessage(objectMapper.writeValueAsString(payload)));
	}

	private void sendJsonQuietly(WebSocketSession session, Map<String, ?> payload) {
		try {
			sendJson(session, payload);
		} catch (IOException ignored) {
			// The close callback removes a failed peer from its room.
		}
	}

	private void sendText(WebSocketSession session, TextMessage message) throws IOException {
		synchronized (session) {
			if (session.isOpen()) {
				session.sendMessage(message);
			}
		}
	}

	private String roomCode(WebSocketSession session) {
		return (String) session.getAttributes().get(ROOM_ATTRIBUTE);
	}

	private SignalingRole role(WebSocketSession session) {
		return (SignalingRole) session.getAttributes().get(ROLE_ATTRIBUTE);
	}
}
