package com.crossdesktopremote.controlplane.signaling;

import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Bean;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;
import org.springframework.web.socket.server.standard.ServletServerContainerFactoryBean;

@Configuration(proxyBeanMethods = false)
@EnableWebSocket
class SignalingWebSocketConfiguration implements WebSocketConfigurer {

	private final SignalingWebSocketHandler handler;

	SignalingWebSocketConfiguration(SignalingWebSocketHandler handler) {
		this.handler = handler;
	}

	@Bean
	ServletServerContainerFactoryBean signalingWebSocketContainer() {
		var container = new ServletServerContainerFactoryBean();
		// Tomcat otherwise rejects whole text messages above its 8 KiB default
		// before our handler can apply the protocol limit. The container counts
		// UTF-16 chars; the handler additionally enforces the UTF-8 byte budget.
		container.setMaxTextMessageBufferSize(SignalingMessageLimits.MAX_TEXT_BYTES);
		return container;
	}

	@Override
	public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
		registry.addHandler(handler, "/ws/signaling").setAllowedOriginPatterns("*");
	}
}
