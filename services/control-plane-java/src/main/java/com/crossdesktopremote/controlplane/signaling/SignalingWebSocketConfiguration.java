package com.crossdesktopremote.controlplane.signaling;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

@Configuration(proxyBeanMethods = false)
@EnableWebSocket
class SignalingWebSocketConfiguration implements WebSocketConfigurer {

	private final SignalingWebSocketHandler handler;

	SignalingWebSocketConfiguration(SignalingWebSocketHandler handler) {
		this.handler = handler;
	}

	@Override
	public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
		registry.addHandler(handler, "/ws/signaling").setAllowedOriginPatterns("*");
	}
}
