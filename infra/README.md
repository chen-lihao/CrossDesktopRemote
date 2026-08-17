# Infrastructure

- `turn`：coturn 配置模板与容量说明。
- `observability`：指标、日志和追踪配置。
- `deploy`：本地 Compose 及后续生产部署清单。

本地开发环境定义在 `deploy/compose.dev.yaml`，包含 PostgreSQL、Redis 和 coturn。所有镜像使用固定版本标签并配置健康检查；默认凭据只允许用于本机开发，可参考 `deploy/.env.example` 使用环境变量覆盖。

```bash
docker compose -f infra/deploy/compose.dev.yaml config
docker compose -f infra/deploy/compose.dev.yaml up -d
docker compose -f infra/deploy/compose.dev.yaml ps
```

本地 coturn 只开放无 TLS 的 STUN/TURN 测试端口和窄 UDP relay 范围。生产环境必须配置公网地址、证书、短期凭据、完整 relay 端口范围、防火墙和区域容量，不能直接复用 `turnserver.dev.conf`。
