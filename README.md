# ai

Repository containing skills, agents, rules, hooks, and other files related to AI/Copilot tooling.

---

## Skills

Skills are reusable instruction sets for GitHub Copilot agents, scoped to specific technical domains. Each skill lives under `skills/<skill-name>/` and includes a `SKILL.md` with the full specification and optional `references/` for advanced topics.

| Skill | Description |
|---|---|
| [spring-java-log-standardization](#spring-java-log-standardization) | Structured JSON logging with MDC, masking and SLF4J + Logback |
| [spring-java-sqs-listener](#spring-java-sqs-listener) | SQS consumer workers with Spring Cloud AWS 4 |
| [spring-java-event-publisher](#spring-java-event-publisher) | SQS/SNS event publisher with Spring Cloud AWS 4 |
| [spring-java-http-client](#spring-java-http-client) | Declarative HTTP client with Spring Boot 4 HTTP Interfaces |

---

### spring-java-log-standardization

**Path:** `skills/spring-java-log-standardization/`

Standardizes logging in Spring Boot 4+ / Java 25 applications using **SLF4J + Logback** with JSON output (via `logstash-logback-encoder`). Enforces structured logs with mandatory MDC fields (`correlationId`, `transactionId`), automatic masking of sensitive data via `MaskingJsonGeneratorDecorator`, and a `SensitiveDataMasker` utility for manual fallback.

**Key deliverables:** Maven dependencies, `logback-spring.xml`, `MdcContext` utility, `MdcFilter` (`OncePerRequestFilter`), `SensitiveDataMasker`, and usage examples with `StructuredArguments.kv()`.

**Trigger:** Use whenever logging standardization, observability, MDC, `correlationId`/`transactionId`, or troubleshooting in Spring Boot is needed.

---

### spring-java-sqs-listener

**Path:** `skills/spring-java-sqs-listener/`

Implements **SQS consumer workers** (listeners) using **Spring Cloud AWS 4** on Java 25 + Spring Boot 4. Covers `@SqsListener` with direct deserialization to records, `@SqsHandler` with sealed interfaces for multi-type events, all three acknowledgement modes (`ON_SUCCESS` / `MANUAL` / `ALWAYS`), container tuning (concurrency, visibility timeout, backpressure), MDC propagation via `MessageInterceptor`, and SNS-wrapped message handling via `@SnsNotificationMessage`.

**References:** `multi-type-events.md`, `container-tuning.md`, `error-handling-and-dlq.md`.

**Trigger:** Use whenever SQS worker/listener/consumer, `@SqsListener`, ack modes, DLQ, or SNS fan-out to SQS is needed.

---

### spring-java-event-publisher

**Path:** `skills/spring-java-event-publisher/`

Implements **SQS and SNS event publishers** using **Spring Cloud AWS 4** on Java 25 + Spring Boot 4. Covers `SqsTemplate` (sync/async send, delay, options builder, FIFO with `messageGroupId`/`messageDeduplicationId`, batch) and `SnsTemplate`/`SnsOperations` (`sendNotification`, `SnsNotification` for headers and FIFO, `SnsAsyncClient` for async SNS). Jackson 3 serialization is auto-configured; `correlationId` propagation via MDC headers is included.

**References:** `sqs-advanced.md`, `sns-advanced.md`.

**Trigger:** Use whenever publishing/sending/producing messages or events to SQS or SNS, FIFO queues/topics, or correlationId propagation in events is needed.

---

### spring-java-http-client

**Path:** `skills/spring-java-http-client/`

Implements **declarative HTTP clients** using **Spring Boot 4's native HTTP Interfaces** (`@HttpExchange` + `@ImportHttpServices`) — the official successor to Spring Cloud OpenFeign. Covers interface declaration with `@GetExchange`/`@PostExchange`, per-client configuration via `spring.http.serviceclient.<group>.*` properties (base-url, timeouts, default headers), `RestClientHttpServiceGroupConfigurer` for dynamic auth headers, native `RestClient` exception hierarchy without custom wrapper classes, and Resilience4J integration (`@Retry` + `@CircuitBreaker`) scoped to retryable exceptions only.

**References:** `configuracao-e-transporte.md`, `erros-e-resiliencia.md`.

**Trigger:** Use whenever an HTTP client is needed to consume a REST API from a Spring Boot 4 service, or when migrating from `@FeignClient`/OpenFeign.

---

## Rules

Rules are **always-on** standards that Claude Code applies to every session in a repository — unlike skills, they are not triggered on demand but loaded as a baseline quality filter for all generated, reviewed, or refactored code.

To take effect, a rule file must be placed under **`.claude/rules/`** in the target repository. Copy the desired rule from this repo's `rules/` folder into the consuming project's `.claude/rules/` directory.

| Rule | Description |
|---|---|
| [java-standards](#java-standards) | Java 25 + Spring Boot 4 coding standards (always-on) |

---

### java-standards

**Path:** `rules/java-standards.md`

Always-on coding standards for **Java 25 + Spring Boot 4** projects. Enforces records for DTOs, self-constructing objects via contextual static factories (no MapStruct/external mappers), restricted Lombok usage (`@Data` forbidden), dependency inversion (inner domain classes depend on interfaces, not external infra implementations), modern Java features (sealed interfaces, pattern matching, virtual threads, text blocks, Scoped Values), JSpecify null safety, Jackson 3, and domain-meaningful exceptions instead of control-flow exceptions.

**Installation:** Copy `rules/java-standards.md` into the target repository's `.claude/rules/` directory.
