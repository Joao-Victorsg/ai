---
name: spring-java-log-standardization
description: Padroniza logs em aplicações Spring Boot 4+/Java com SLF4J + Logback em JSON, com MDC obrigatório (correlationId e transactionId), mascaramento automático de dados sensíveis via MaskingJsonGeneratorDecorator e política de níveis INFO/WARN/ERROR. Use esta skill sempre que o usuário pedir observabilidade, logging estruturado, logback-spring.xml, rastreabilidade de requests/eventos, troubleshooting de erros em Spring Boot, MDC, correlationId, transactionId, ou melhoria de qualidade de logs mesmo sem citar explicitamente "padrão de log".
---

# Spring/Java Logging Standard

Use esta skill para implementar ou revisar logging em aplicações Spring Boot 4+ / Java 25+ com foco em rastreabilidade e investigação de incidentes.

## Stack definida

| Decisão | Escolha |
|---|---|
| Logging API | SLF4J (`slf4j-api`) |
| Implementação | `logback-classic` |
| Encoder JSON | `logstash-logback-encoder` |
| Campos estruturados | `StructuredArguments.kv()` |
| Masking automático | `MaskingJsonGeneratorDecorator` no logback |
| Masking manual (fallback) | `SensitiveDataMasker` (utilitário Java) |
| MDC HTTP | `OncePerRequestFilter` |
| Saída | Console/stdout (ideal para containers) |
| Build | Maven |
| Níveis permitidos | `INFO`, `WARN`, `ERROR` |

## Passo 0 — Perguntar sobre o contexto MDC antes de implementar

Antes de gerar qualquer código, pergunte ao usuário (ou ao agente que chamou a skill):

> "Os campos padrão de MDC desta skill são: `correlationId`, `transactionId`, `userId`, `serviceName`, `requestPath`, `httpMethod`. **Esses campos fazem sentido para o seu contexto?** Há campos adicionais relevantes (ex: `tenantId`, `orderId`, `eventType`, `clientIp`) ou algum que deva ser removido?"

Só avance para a implementação após confirmar quais campos compõem o MDC. Se o usuário não responder (ex: contexto automático/agente), use os campos padrão acima.

## Entrega — sempre nesta ordem

Quando o usuário confirmar os campos MDC, entregue estes blocos na sequência:

1. Dependências Maven (`pom.xml`)
2. `logback-spring.xml` com encoder JSON + masking automático
3. `MdcContext` — classe utilitária para inicialização e limpeza do MDC
4. `MdcFilter` — `OncePerRequestFilter` que usa `MdcContext`
5. `SensitiveDataMasker` — utilitário Java de fallback
6. Exemplos de uso: `INFO`, `WARN`, `ERROR` com `kv()`
7. Checklist de conformidade

---

## 1 — Dependências Maven

```xml
<!-- SLF4J API -->
<dependency>
    <groupId>org.slf4j</groupId>
    <artifactId>slf4j-api</artifactId>
</dependency>

<!-- Logback Classic (implementação SLF4J) -->
<dependency>
    <groupId>ch.qos.logback</groupId>
    <artifactId>logback-classic</artifactId>
</dependency>

<!-- Encoder JSON para Logback -->
<dependency>
    <groupId>net.logstash.logback</groupId>
    <artifactId>logstash-logback-encoder</artifactId>
    <version>8.0</version>
</dependency>
```

> Spring Boot já gerencia `slf4j-api` e `logback-classic`. Só declare versão explícita se precisar sobrescrever o BOM.

---

## 2 — logback-spring.xml

Salve em `src/main/resources/logback-spring.xml`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>

    <!-- Mascaramento automático de campos sensíveis no JSON de saída -->
    <conversionRule conversionWord="mask"
        converterClass="net.logstash.logback.mask.MaskingJsonGeneratorDecorator"/>

    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="net.logstash.logback.encoder.LogstashEncoder">
            <!-- Inclui todos os campos do MDC automaticamente -->
            <includeMdcKeyName>correlationId</includeMdcKeyName>
            <includeMdcKeyName>transactionId</includeMdcKeyName>
            <includeMdcKeyName>userId</includeMdcKeyName>
            <includeMdcKeyName>serviceName</includeMdcKeyName>
            <includeMdcKeyName>requestPath</includeMdcKeyName>
            <includeMdcKeyName>httpMethod</includeMdcKeyName>

            <!-- Timestamp padrão ISO-8601 UTC -->
            <timestampPattern>yyyy-MM-dd'T'HH:mm:ss.SSS'Z'</timestampPattern>
            <timeZone>UTC</timeZone>

            <!-- Mascaramento automático de campos sensíveis pelo nome -->
            <jsonGeneratorDecorator
                class="net.logstash.logback.mask.MaskingJsonGeneratorDecorator">
                <valueMask>
                    <value>password</value>
                    <mask>****</mask>
                </valueMask>
                <valueMask>
                    <value>secret</value>
                    <mask>****</mask>
                </valueMask>
                <valueMask>
                    <value>apiKey</value>
                    <mask>****</mask>
                </valueMask>
                <valueMask>
                    <value>token</value>
                    <mask>****</mask>
                </valueMask>
                <!-- Mascaramento de CPF/SSN via regex -->
                <pathMask>
                    <path>cpf</path>
                    <mask>***.***.***-**</mask>
                </pathMask>
            </jsonGeneratorDecorator>

            <!-- Stacktrace inline no JSON -->
            <throwableConverter
                class="net.logstash.logback.stacktrace.ShortenedThrowableConverter">
                <maxDepthPerCause>20</maxDepthPerCause>
                <rootCauseFirst>true</rootCauseFirst>
            </throwableConverter>
        </encoder>
    </appender>

    <!-- Nível raiz — apenas INFO, WARN e ERROR chegam ao appender -->
    <root level="INFO">
        <appender-ref ref="CONSOLE"/>
    </root>

</configuration>
```

---

## 3 — MdcContext (utilitário central)

Centralize toda manipulação de MDC nesta classe. Ela separa a responsabilidade de montar o contexto do código de infraestrutura (filtro, interceptor, handler de evento), facilitando testes e mudanças nos campos sem tocar em múltiplos lugares.

```java
import org.slf4j.MDC;

import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Utilitário central para inicialização e limpeza do MDC.
 * Todos os pontos de entrada (filtros HTTP, handlers de eventos, jobs)
 * devem usar esta classe em vez de chamar MDC.put() diretamente.
 */
public final class MdcContext {

    // Chaves padrão — ajuste conforme o contexto da aplicação
    public static final String CORRELATION_ID  = "correlationId";
    public static final String TRANSACTION_ID  = "transactionId";
    public static final String USER_ID         = "userId";
    public static final String SERVICE_NAME    = "serviceName";
    public static final String REQUEST_PATH    = "requestPath";
    public static final String HTTP_METHOD     = "httpMethod";

    private MdcContext() {}

    /** Inicializa MDC para um request HTTP. */
    public static void initHttp(String correlationId, String transactionId,
                                String requestPath, String httpMethod) {
        MDC.put(CORRELATION_ID, resolveOrGenerate(correlationId));
        MDC.put(TRANSACTION_ID, resolveOrGenerate(transactionId));
        MDC.put(REQUEST_PATH,   Optional.ofNullable(requestPath).orElse("unknown"));
        MDC.put(HTTP_METHOD,    Optional.ofNullable(httpMethod).orElse("unknown"));
    }

    /** Inicializa MDC para um evento assíncrono (Kafka, SQS, job, etc.). */
    public static void initEvent(String correlationId, String eventType, String serviceName) {
        MDC.put(CORRELATION_ID, resolveOrGenerate(correlationId));
        MDC.put(TRANSACTION_ID, UUID.randomUUID().toString());
        if (eventType   != null) MDC.put("eventType",   eventType);
        if (serviceName != null) MDC.put(SERVICE_NAME,  serviceName);
    }

    /** Adiciona campos opcionais quando disponíveis (userId, tenantId, etc.). */
    public static void enrich(Map<String, String> extraFields) {
        extraFields.forEach((key, value) -> {
            if (value != null && !value.isBlank()) MDC.put(key, value);
        });
    }

    /** Remove todos os campos do MDC. Sempre chame em finally. */
    public static void clear() {
        MDC.clear();
    }

    private static String resolveOrGenerate(String value) {
        return (value != null && !value.isBlank()) ? value : UUID.randomUUID().toString();
    }
}
```

## 4 — MdcFilter (HTTP)

`OncePerRequestFilter` delega para `MdcContext`, mantendo o filtro simples e sem lógica de negócio.

```java
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

@Component
@Order(1)
public class MdcFilter extends OncePerRequestFilter {

    private static final String HEADER_CORRELATION_ID = "X-Correlation-Id";
    private static final String HEADER_TRANSACTION_ID = "X-Transaction-Id";

    @Override
    protected void doFilterInternal(
            HttpServletRequest request,
            HttpServletResponse response,
            FilterChain filterChain) throws ServletException, IOException {

        try {
            MdcContext.initHttp(
                request.getHeader(HEADER_CORRELATION_ID),
                request.getHeader(HEADER_TRANSACTION_ID),
                request.getRequestURI(),
                request.getMethod()
            );

            // Propaga correlationId para o response (útil em APIs encadeadas)
            response.setHeader(HEADER_CORRELATION_ID,
                               org.slf4j.MDC.get(MdcContext.CORRELATION_ID));

            filterChain.doFilter(request, response);

        } finally {
            MdcContext.clear();
        }
    }
}
```

### Para consumidores de eventos (Kafka, SQS, etc.)

```java
public void handle(MyEvent event) {
    try {
        MdcContext.initEvent(
            event.getCorrelationId(),
            event.getType(),
            "order-service"
        );
        // Enriqueça com campos adicionais do domínio quando disponíveis
        MdcContext.enrich(Map.of(
            MdcContext.USER_ID, event.getUserId()
        ));

        // processamento...

    } finally {
        MdcContext.clear();
    }
}
```

---

## 5 — SensitiveDataMasker (fallback)

Use este utilitário quando precisar mascarar **antes** de montar o `kv()` — por exemplo, ao logar parcialmente um valor para fins de rastreabilidade.

```java
public final class SensitiveDataMasker {

    private SensitiveDataMasker() {}

    /** Mascara completamente — use para senhas, tokens, secrets */
    public static String mask(String value) {
        if (value == null || value.isBlank()) return "****";
        return "****";
    }

    /** Expõe apenas os últimos N caracteres — use para IDs parciais, cartões */
    public static String maskKeepLast(String value, int visibleChars) {
        if (value == null || value.length() <= visibleChars) return "****";
        return "*".repeat(value.length() - visibleChars)
               + value.substring(value.length() - visibleChars);
    }

    /** Mascara e-mail preservando domínio — use para PII auditável */
    public static String maskEmail(String email) {
        if (email == null || !email.contains("@")) return "****";
        return "****@" + email.substring(email.indexOf('@') + 1);
    }
}
```

---

## 6 — Exemplos de uso com kv()

Sempre importe: `import static net.logstash.logback.argument.StructuredArguments.kv;`

### INFO — operação concluída com sucesso

```java
log.info("Pedido criado com sucesso",
    kv("orderId",    order.getId()),
    kv("customerId", order.getCustomerId()),
    kv("totalValue", order.getTotalValue()),
    kv("itemCount",  order.getItems().size())
);
```

### WARN — situação anômala, mas recuperável

```java
log.warn("Tentativa de pagamento rejeitada pelo provedor — será reenviada",
    kv("orderId",         orderId),
    kv("paymentProvider", providerName),
    kv("attempt",         attemptNumber),
    kv("nextRetryIn",     "30s")
);
```

### ERROR — falha com diagnóstico completo

```java
log.error("Falha ao processar pagamento do pedido",
    kv("orderId",         orderId),
    kv("paymentProvider", providerName),
    kv("attempt",         attemptNumber),
    kv("errorCode",       e.getCode()),
    ex   // sempre passe o Throwable como último argumento
);
```

### Dado sensível — use SensitiveDataMasker antes de kv()

```java
log.info("Usuário autenticado com sucesso",
    kv("userId", userId),
    kv("email",  SensitiveDataMasker.maskEmail(email)),
    kv("role",   userRole)
);
```

### ❌ Padrões a evitar

```java
// Mensagens sem contexto — não informam nada útil
log.info("ok");
log.error("Erro");
log.warn("Problema");

// Dado sensível em texto puro
log.info("Login de " + email + " com senha " + password);
```

---

## 7 — Checklist de conformidade

Antes de considerar o logging implementado, valide:

- [ ] Todo log produzido está em JSON (`logback-spring.xml` com `LogstashEncoder`)
- [ ] `correlationId` e `transactionId` aparecem em **todos** os logs do fluxo
- [ ] MDC é limpo em `finally` em **todos** os fluxos (HTTP, eventos, jobs)
- [ ] Nenhum dado sensível (PII, senha, token, apiKey) aparece em texto puro
- [ ] Logs de `ERROR` incluem o `Throwable` (`ex`) como último argumento
- [ ] Mensagens são descritivas e orientadas ao domínio (sem "ok", "erro", "done")
- [ ] Apenas `INFO`, `WARN` e `ERROR` são usados (sem `DEBUG`/`TRACE` no padrão)

---

## Critérios de aceitação

Considere concluído somente quando:

1. Todo log produzido esteja em JSON.
2. `correlationId` e `transactionId` apareçam nos logs de todos os fluxos.
3. Nenhum dado sensível (PII, senha, token, apiKey) seja exposto em texto puro.
4. Logs de erro permitam identificar causa, ponto de falha e contexto operacional.
5. MDC seja limpo após cada request/evento, inclusive em exceções.
6. O nível raiz do `logback-spring.xml` esteja em `INFO`.

