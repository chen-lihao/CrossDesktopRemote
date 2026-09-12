package com.crossdesktopremote.controlplane.signaling;

import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import org.springframework.stereotype.Component;
import org.springframework.web.socket.WebSocketSession;

/**
 * Ephemeral online routing for trusted devices.
 *
 * <p>The control plane never receives or validates private keys, trust grants,
 * or session permissions. It only joins two online sockets by a public machine
 * code; endpoint signatures remain the authorization boundary.</p>
 */
@Component
final class TrustedRouteRegistry {

	private final HostSessionArbiter arbiter;
	private final Map<String, WebSocketSession> hostsByMachineCode = new HashMap<>();
	private final Map<WebSocketSession, TrustedRoute> routesBySession = new HashMap<>();

	TrustedRouteRegistry(HostSessionArbiter arbiter) {
		this.arbiter = arbiter;
	}

	synchronized boolean registerHost(String machineCode, WebSocketSession host) {
		var current = hostsByMachineCode.get(machineCode);
		if (current != null && current != host && current.isOpen()) return false;
		hostsByMachineCode.put(machineCode, host);
		return true;
	}

	synchronized Optional<TrustedRoute> joinController(
			String targetMachineCode,
			WebSocketSession controller) {
		var host = hostsByMachineCode.get(targetMachineCode);
		if (host == null || !host.isOpen() || routesBySession.containsKey(host)
				|| !arbiter.tryAcquire(
						host,
						controller,
						HostSessionArbiter.AuthenticationMode.TRUSTED_DEVICE)) {
			return Optional.empty();
		}
		var route = new TrustedRoute(UUID.randomUUID().toString(), targetMachineCode, host, controller);
		routesBySession.put(host, route);
		routesBySession.put(controller, route);
		return Optional.of(route);
	}

	synchronized Optional<WebSocketSession> peer(WebSocketSession session) {
		var route = routesBySession.get(session);
		if (route == null) return Optional.empty();
		var peer = route.host() == session ? route.controller() : route.host();
		return peer.isOpen() ? Optional.of(peer) : Optional.empty();
	}

	synchronized Optional<TrustedRoute> route(WebSocketSession session) {
		return Optional.ofNullable(routesBySession.get(session));
	}

	synchronized Optional<WebSocketSession> leave(WebSocketSession session) {
		var route = routesBySession.remove(session);
		arbiter.release(session);
		if (route == null) {
			hostsByMachineCode.entrySet().removeIf(entry -> entry.getValue() == session);
			return Optional.empty();
		}
		var peer = route.host() == session ? route.controller() : route.host();
		routesBySession.remove(peer, route);
		if (route.host() == session) {
			hostsByMachineCode.remove(route.targetMachineCode(), session);
		}
		return peer.isOpen() ? Optional.of(peer) : Optional.empty();
	}

	record TrustedRoute(
			String sessionId,
			String targetMachineCode,
			WebSocketSession host,
			WebSocketSession controller) {
	}
}
