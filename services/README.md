# Services

- `control-plane-java`：Java/Spring Boot 控制平面，由 Spring Initializr 官方接口生成。
- `migrations`：数据库迁移审阅与共享位置；接入 Flyway 前必须明确运行时路径和回滚策略。

控制平面只负责身份、设备、授权、信令、策略和审计，不处理视频热路径。

当前 Spring Boot 基座已接入本地 PostgreSQL/Redis 和 Flyway V1；测试、`local` profile 启动及 Actuator 健康检查均通过。`/ws/signaling` 开发态双端房间只接受六位连接码、host/controller 两个角色、白名单消息类型和 64KiB 消息上限。Mac 必须先注册连接码；连接码 5 分钟有效、只允许一个控制端成功消费，并对同一来源一分钟内 5 次失败尝试限流，相关单元和真实 WebSocket 集成测试已通过。

`compileJava`、`test`和`bootRun`会先执行`generateProtocolJava`，用当前`proto/`完整重建 Java Protobuf 目录，避免删除或重命名消息后残留旧 descriptor 类。需要将`protoc`加入`PATH`，或用`CROSSDESKTOP_PROTOC`指定可执行文件：

```bash
CROSSDESKTOP_PROTOC=/absolute/path/to/protoc \
  ./services/control-plane-java/gradlew \
  -p services/control-plane-java bootRun
```

`scripts/generate-proto.sh`也会先在临时目录完成 Java/Dart 生成与校验，成功后再替换忽略型`build/generated`目录，不再将新旧生成物混合编译。

该信令端点仅用于局域网原型。TTL、单次消费和限流目前只在单 JVM 内存中实现；尚无用户身份、设备签名、独立短期会话票据、Redis 跨实例路由或 WSS，不能部署到公网。其他 HTTP 路径仍默认拒绝。
