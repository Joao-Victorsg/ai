# ai

Repository containing skills, agents, rules, hooks, and other files related to AI/Copilot tooling.

| Component | Folder | Loaded |
|---|---|---|
| Skills | `skills/` | On demand (triggered by task) |
| Rules | `rules/` | Always-on (baseline quality filter) |
| Hooks | `hooks/` | On agent lifecycle events |
| Agents | `agents/` | Invoked for bounded, specialized tasks |

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

---

## Hooks

Hooks are shell commands Claude Code runs on agent lifecycle events (`PreToolUse`, `Stop`, etc.) — deterministic enforcement and feedback loops, distinct from git hooks. Each lives under `hooks/<name>/` with the script, a `settings.example.json` to merge into the consuming repo's `.claude/settings.json`, and a README. Copy the script into the target repo's `.claude/hooks/`.

| Hook | Event | Description |
|---|---|---|
| [java-build-check](#java-build-check) | `Stop` | Verifies the build once per turn before the agent finishes |
| [java-standards-guard](#java-standards-guard) | `PreToolUse` | Blocks edits that introduce patterns banned by `java-standards` |

---

### java-build-check

**Path:** `hooks/java-build-check/`

Fires **once when the agent ends its turn** and runs scoped Maven goals (default `mvn -q -B test`; override via `MVN_GOALS`, up to `clean install`). Silent on success; on failure it returns the truncated errors and **blocks the stop** so Claude fixes the build before handing back. Loop-guarded via `stop_hook_active`. This is the right home for heavier verification — running it per-edit would be the expensive anti-pattern.

---

### java-standards-guard

**Path:** `hooks/java-standards-guard/`

A `PreToolUse` gate that inspects the content about to be written to a `.java` file and **blocks** (exit 2) high-confidence violations of `java-standards` before they hit disk: `@Data`, MapStruct/`@Mapper`, `System.out/err`/`printStackTrace`, and generic control-flow exceptions (`throw new RuntimeException(...)`). Turns the advisory rule into hard enforcement. Softer/contextual rules are left to the reviewer agent to avoid false positives.

---

## Agents

Agents (subagents) are specialized assistants with their own context window and tool permissions, invoked for bounded tasks to keep the main session focused. Each lives under `agents/<name>.md` with YAML frontmatter (`name`, `description`, `tools`, `model`). Copy into the target repo's `.claude/agents/`.

| Agent | Description |
|---|---|
| [spring-java-reviewer](#spring-java-reviewer) | Reviews Java/Spring changes against `java-standards` + the skills |

---

### spring-java-reviewer

**Path:** `agents/spring-java-reviewer.md`

A **senior-level**, read-only reviewer for **Java 25 + Spring Boot 4** changes. Reads the diff (or named files) and consults `rules/java-standards.md` plus the relevant skill (and its `references/`). Reviews across eleven dimensions: standards conformance, **null safety** (every realistic NPE path), **concurrency & parallelism** (shared mutable state, virtual-thread pinning, scope traps, parallel streams/`CompletableFuture`), **resilience** (timeouts, bounded idempotent retries, circuit breakers, messaging ack/DLQ, transaction boundaries, graceful shutdown), error handling & **observability** (logs/metrics/tracing — all three pillars, low-cardinality tags, context propagation), security, performance & data access (N+1, caching), **configuration & secrets hygiene** (validated `@ConfigurationProperties`, no secrets in config, fail-fast defaults), **change completeness** (blast radius — flags missing companions like a timeout for a new outbound call or a test for a behavior change), **Dockerfile / container hygiene** (multi-stage, non-root, container-aware JVM, signal handling), and tests. Reports findings grouped by severity (Blocker / Should-fix / Nitpick) with file:line, the concrete failure scenario, the violated rule, and a fix — ending in an approve / approve-with-nits / changes-requested verdict. It reports; it never edits.
