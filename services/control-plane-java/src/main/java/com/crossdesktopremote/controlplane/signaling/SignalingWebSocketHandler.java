package com.crossdesktopremote.controlplane.signaling;

import java.io.IOException;
import java.util.HashMap;
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
			"rotate-invitation",
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
		if (role.isEmpty() ||
				(role.get() == SignalingRole.CONTROLLER && !StringUtils.hasText(roomCode))) {
			session.close(CloseStatus.BAD_DATA.withReason("Invalid room or role"));
			return;
		}

		SignalingRoomRegistry.HostInvitation invitation = null;
		if (role.get() == SignalingRole.HOST && !StringUtils.hasText(roomCode)) {
			invitation = rooms.createHostInvitation(session);
			roomCode = invitation.roomCode();
		} else {
			var result = rooms.join(roomCode, role.get(), session);
			if (result != SignalingRoomRegistry.JoinResult.JOINED) {
				session.close(CloseStatus.POLICY_VIOLATION.withReason(
						rooms.rejectionReason(result, roomCode, session)));
				return;
			}
		}

		session.getAttributes().put(ROOM_ATTRIBUTE, roomCode);
		session.getAttributes().put(ROLE_ATTRIBUTE, role.get());
		var ready = new HashMap<String, Object>();
		ready.put("type", "ready");
		ready.put("protocolVersion", 2);
		ready.put("capabilities", Set.of("server-invitations", "invitation-rotation"));
		ready.put("room", roomCode);
		ready.put("role", role.get().wireName());
		if (invitation != null) {
			ready.put("invitationLeaseId", invitation.leaseId());
			ready.put("invitationExpiresAtUnixMillis", invitation.expiresAtUnixMillis());
			ready.put("invitationExpiresInMillis", invitation.expiresInMillis());
		} else {
			rooms.invitationRemainingMillis(roomCode, role.get(), session)
					.ifPresent(value -> ready.put("invitationExpiresInMillis", value));
		}
		sendJson(session, ready);
		var joinedRoomCode = roomCode;
		rooms.peer(joinedRoomCode, role.get()).ifPresent(peer -> {
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

		if (messageType.equals("rotate-invitation")) {
			if (role != SignalingRole.HOST) {
				session.close(CloseStatus.POLICY_VIOLATION.withReason("Host role required"));
				return;
			}
			var rotated = rooms.rotateHostInvitation(roomCode, session);
			if (rotated.isEmpty()) {
				sendJson(session, Map.of(
						"type", "invitation-rotation-error",
						"code", "INVITATION_NOT_ROTATABLE"));
				return;
			}
			var invitation = rotated.get();
			session.getAttributes().put(ROOM_ATTRIBUTE, invitation.roomCode());
			var response = new HashMap<String, Object>();
			response.put("type", "invitation-rotated");
			response.put("room", invitation.roomCode());
			response.put("invitationLeaseId", invitation.leaseId());
			response.put("invitationExpiresAtUnixMillis", invitation.expiresAtUnixMillis());
			response.put("invitationExpiresInMillis", invitation.expiresInMillis());
			var requestId = payload.path("requestId").asText();
			if (StringUtils.hasText(requestId)) response.put("requestId", requestId);
			sendJson(session, response);
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
