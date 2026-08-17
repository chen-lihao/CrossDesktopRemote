# Services

- `control-plane-java`：Java/Spring Boot 控制平面，由 Spring Initializr 官方接口生成。
- `migrations`：数据库迁移审阅与共享位置；接入 Flyway 前必须明确运行时路径和回滚策略。

控制平面只负责身份、设备、授权、信令、策略和审计，不处理视频热路径。

当前 Spring Boot 基座已接入本地 PostgreSQL/Redis 和 Flyway V1；测试、`local` profile 启动及 Actuator 健康检查均通过。最小安全策略匿名放行健康检查并默认拒绝其他请求。身份、设备、会话授权、WebSocket 信令、策略和审计业务仍未实现。
