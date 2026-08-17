package com.crossdesktopremote.controlplane.signaling;

import java.net.InetSocketAddress;
import java.time.Duration;
import java.util.EnumMap;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;
import java.util.function.LongSupplier;
import java.util.regex.Pattern;

import org.springframework.stereotype.Component;
import org.springframework.web.socket.WebSocketSession;

@Component
final class SignalingRoomRegistry {

	private static final Pattern ROOM_CODE = Pattern.compile("[0-9]{6}");
	private static final Duration DEFAULT_ROOM_TTL = Duration.ofMinutes(5);
	private static final Duration DEFAULT_ATTEMPT_WINDOW = Duration.ofMinutes(1);
	private static final int DEFAULT_MAX_FAILED_ATTEMPTS = 5;

	private final ConcurrentMap<String, Room> rooms = new ConcurrentHashMap<>();
	private final ConcurrentMap<String, AttemptWindow> failedAttempts = new ConcurrentHashMap<>();
	private final LongSupplier currentTimeMillis;
	private final long roomTtlMillis;
	private final long attemptWindowMillis;
	private final int maxFailedAttempts;

	SignalingRoomRegistry() {
		this(System::currentTimeMillis, DEFAULT_ROOM_TTL, DEFAULT_ATTEMPT_WINDOW, DEFAULT_MAX_FAILED_ATTEMPTS);
	}

	SignalingRoomRegistry(
			LongSupplier currentTimeMillis,
			Duration roomTtl,
			Duration attemptWindow,
			int maxFailedAttempts) {
		this.currentTimeMillis = currentTimeMillis;
		this.roomTtlMillis = roomTtl.toMillis();
		this.attemptWindowMillis = attemptWindow.toMillis();
		this.maxFailedAttempts = maxFailedAttempts;
	}

	JoinResult join(String roomCode, SignalingRole role, WebSocketSession session) {
		if (!ROOM_CODE.matcher(roomCode).matches()) {
			if (role == SignalingRole.CONTROLLER) {
				recordFailedAttempt(clientKey(session));
			}
			return JoinResult.INVALID_ROOM;
		}

		return role == SignalingRole.HOST
				? registerHost(roomCode, session)
				: joinController(roomCode, session);
	}

	Optional<WebSocketSession> peer(String roomCode, SignalingRole role) {
		var room = rooms.get(roomCode);
		if (room == null) {
			return Optional.empty();
		}
		if (room.isExpired(currentTimeMillis.getAsLong(), roomTtlMillis)) {
			rooms.remove(roomCode, room);
			return Optional.empty();
		}
		return room.session(role.peerRole());
	}

	void leave(String roomCode, SignalingRole role, WebSocketSession session) {
		rooms.computeIfPresent(roomCode, (ignored, room) -> {
			if (role == SignalingRole.HOST && room.contains(role, session)) {
				return null;
			}
			room.leave(role, session);
			return room.isEmpty() ? null : room;
		});
	}

	private JoinResult registerHost(String roomCode, WebSocketSession session) {
		var result = new AtomicReference<>(JoinResult.ROLE_OCCUPIED);
		var now = currentTimeMillis.getAsLong();
		rooms.compute(roomCode, (ignored, existing) -> {
			if (existing == null
					|| existing.isExpired(now, roomTtlMillis)
					|| !existing.hasOpenHost()) {
				result.set(JoinResult.JOINED);
				return Room.withHost(session, now);
			}
			return existing;
		});
		return result.get();
	}

	private JoinResult joinController(String roomCode, WebSocketSession session) {
		var key = clientKey(session);
		var now = currentTimeMillis.getAsLong();
		if (failedAttempts.computeIfAbsent(
				key,
				ignored -> new AttemptWindow(now)).isBlocked(now, attemptWindowMillis, maxFailedAttempts)) {
			return JoinResult.RATE_LIMITED;
		}

		var room = rooms.get(roomCode);
		if (room == null || room.isExpired(now, roomTtlMillis) || !room.hasOpenHost()) {
			if (room != null) {
				rooms.remove(roomCode, room);
			}
			recordFailedAttempt(key);
			return JoinResult.INVALID_ROOM;
		}

		var result = room.joinController(session);
		if (result == JoinResult.JOINED) {
			failedAttempts.remove(key);
		}
		return result;
	}

	private void recordFailedAttempt(String key) {
		var now = currentTimeMillis.getAsLong();
		failedAttempts.computeIfAbsent(key, ignored -> new AttemptWindow(now))
				.recordFailure(now, attemptWindowMillis);
	}

	private String clientKey(WebSocketSession session) {
		InetSocketAddress remoteAddress = session.getRemoteAddress();
		if (remoteAddress == null) {
			return "session:" + session.getId();
		}
		if (remoteAddress.getAddress() != null) {
			return remoteAddress.getAddress().getHostAddress();
		}
		return remoteAddress.getHostString();
	}

	enum JoinResult {
		JOINED,
		INVALID_ROOM,
		ROLE_OCCUPIED,
		CODE_CONSUMED,
		RATE_LIMITED
	}

	private static final class Room {
		private final Map<SignalingRole, WebSocketSession> participants = new EnumMap<>(SignalingRole.class);
		private final long createdAtMillis;
		private boolean controllerCodeConsumed;

		private Room(WebSocketSession host, long createdAtMillis) {
			this.createdAtMillis = createdAtMillis;
			participants.put(SignalingRole.HOST, host);
		}

		static Room withHost(WebSocketSession host, long createdAtMillis) {
			return new Room(host, createdAtMillis);
		}

		synchronized JoinResult joinController(WebSocketSession session) {
			if (controllerCodeConsumed) {
				return JoinResult.CODE_CONSUMED;
			}
			if (!hasOpenHost()) {
				return JoinResult.INVALID_ROOM;
			}
			controllerCodeConsumed = true;
			participants.put(SignalingRole.CONTROLLER, session);
			return JoinResult.JOINED;
		}

		synchronized Optional<WebSocketSession> session(SignalingRole role) {
			return Optional.ofNullable(participants.get(role)).filter(WebSocketSession::isOpen);
		}

		synchronized void leave(SignalingRole role, WebSocketSession session) {
			participants.remove(role, session);
		}

		synchronized boolean contains(SignalingRole role, WebSocketSession session) {
			return participants.get(role) == session;
		}

		synchronized boolean hasOpenHost() {
			return session(SignalingRole.HOST).isPresent();
		}

		synchronized boolean isExpired(long nowMillis, long ttlMillis) {
			return !controllerCodeConsumed && nowMillis - createdAtMillis >= ttlMillis;
		}

		synchronized boolean isEmpty() {
			return participants.isEmpty();
		}
	}

	private static final class AttemptWindow {
		private long startedAtMillis;
		private int failures;

		private AttemptWindow(long startedAtMillis) {
			this.startedAtMillis = startedAtMillis;
		}

		synchronized boolean isBlocked(long nowMillis, long windowMillis, int maximumFailures) {
			resetIfExpired(nowMillis, windowMillis);
			return failures >= maximumFailures;
		}

		synchronized void recordFailure(long nowMillis, long windowMillis) {
			resetIfExpired(nowMillis, windowMillis);
			failures++;
		}

		private void resetIfExpired(long nowMillis, long windowMillis) {
			if (nowMillis - startedAtMillis >= windowMillis) {
				startedAtMillis = nowMillis;
				failures = 0;
			}
		}
	}
}
