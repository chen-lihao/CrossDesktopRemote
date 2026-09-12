package com.crossdesktopremote.controlplane.signaling;

import java.util.HashMap;
import java.util.Map;

import org.springframework.stereotype.Component;
import org.springframework.web.socket.WebSocketSession;

/**
 * Owns the single-controller invariant for a host across every authentication
 * mode. A connection code and a trusted route are only different admission
 * mechanisms; once admitted they compete for the same host session.
 */
@Component
final class HostSessionArbiter {

	private final Map<WebSocketSession, Lease> leasesByHost = new HashMap<>();
	private final Map<WebSocketSession, Lease> leasesByController = new HashMap<>();

	synchronized boolean tryAcquire(
			WebSocketSession host,
			WebSocketSession controller,
			AuthenticationMode authenticationMode) {
		if (!host.isOpen() || !controller.isOpen()
				|| leasesByHost.containsKey(host)
				|| leasesByController.containsKey(controller)) {
			return false;
		}
		var lease = new Lease(host, controller, authenticationMode);
		leasesByHost.put(host, lease);
		leasesByController.put(controller, lease);
		return true;
	}

	synchronized void release(WebSocketSession session) {
		var lease = leasesByHost.remove(session);
		if (lease == null) lease = leasesByController.remove(session);
		if (lease == null) return;
		leasesByHost.remove(lease.host(), lease);
		leasesByController.remove(lease.controller(), lease);
	}

	synchronized boolean isBusy(WebSocketSession host) {
		return leasesByHost.containsKey(host);
	}

	enum AuthenticationMode {
		CONNECTION_CODE,
		TRUSTED_DEVICE
	}

	private record Lease(
			WebSocketSession host,
			WebSocketSession controller,
			AuthenticationMode authenticationMode) {
	}
}
