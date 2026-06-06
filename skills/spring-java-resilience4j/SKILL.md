---
name: spring-java-resilience4j
description: 'Use esta skill quando, num projeto Java 25+ / Spring Boot 4, o usuário precisar tornar uma chamada a um recurso instável (outro microserviço, API externa, banco, broker, SDK de terceiro) tolerante a falhas com Resilience4J — os padrões Circuit Breaker e Retry. Inclui pedidos em linguagem simples como "adiciona retry e circuit breaker nessa chamada", "esse downstream cai e derruba a gente, protege", "quero retentar no 5xx mas não no 4xx", "preciso de fallback quando o serviço X estiver fora", "expõe as métricas do circuit breaker no Prometheus/Micrometer", "logar quando o breaker abre/fecha", "logar as tentativas de retry", além de menções a @CircuitBreaker, @Retry, resilience4j, CallNotPermittedException, fallbackMethod, sliding window, failure-rate-threshold, backoff exponencial, ou à skill de "política fina de resiliência" referida pela skill de HTTP client. NÃO acione para: criar o cliente HTTP em si (declarar @HttpExchange/RestClient — isso é a skill spring-java-http-client), padronizar logs/MDC (skill spring-java-log-standardization), consumir filas SQS, rate limiting de API exposta (lado servidor), ou resiliência fora do ecossistema Spring/Java.'
---

# Resiliência com Resilience4J — Circuit Breaker + Retry · Spring Boot 4 · Java 25

Use esta skill para deixar **chamadas a recursos instáveis** tolerantes a falhas com os dois padrões centrais do Resilience4J: **Retry** (retenta falhas transitórias) e **Circuit Breaker** (para de bater num downstream doente e dá tempo dele se recuperar). O foco é o que torna isso production-grade: **mapear corretamente o que é retentável**, **expor métricas via Micrometer**, e **logar os eventos que importam para operar o sistema** — quando o breaker muda de estado e quando um retry acontece ou se esgota.

**Fora do escopo:** declarar o cliente HTTP em si (`@HttpExchange`/`RestClient` → skill `spring-java-http-client`), o padrão de log estruturado/MDC (skill `spring-java-log-standardization`, da qual esta depende para o formato dos logs), Rate Limiter, Bulkhead e Time Limiter (mencionados em `references/tuning-avancado.md`, mas não são o foco — esta skill entrega CB + Retry).

> **Por que não a abstração do Spring Cloud CircuitBreaker?** Ela é neutra de fornecedor (`circuitBreaker.run(call, fallback)`), mas modela só **CircuitBreaker + TimeLimiter** — **Retry não é cidadão de primeira classe** nela. Como aqui os dois padrões-alvo são CB *e* Retry, e queremos acesso direto aos *event publishers* para logar transições e tentativas, o **starter nativo do Resilience4J** (`resilience4j-spring-boot4`, anotações `@CircuitBreaker`/`@Retry`) é a escolha mais direta e expressiva. A portabilidade que a abstração oferece não vale nada depois que o Resilience4J já foi escolhido.

## Stack definida

| Decisão | Escolha |
|---|---|
| Linguagem | Java 25 (records, sealed interfaces para o resultado) |
| Framework | Spring Boot 4.x (Spring Framework 7) |
| Resiliência | **Resilience4J** via starter nativo `io.github.resilience4j:resilience4j-spring-boot4:2.4.0` |
| Estilo | Declarativo — anotações `@Retry` e `@CircuitBreaker` (AOP) |
| Padrões | **Circuit Breaker** + **Retry** (os demais ficam na ref. de tuning) |
| Métricas | **Micrometer** (binding automático do R4J) + Actuator; Prometheus opcional |
| Logs de evento | `RegistryEventConsumer` + SLF4J `kv()` (skill `spring-java-log-standardization`) |
| Erros do transporte | Exceções nativas do `RestClient` (vindas da skill de HTTP client) |
| Build | Maven |

## Como usar esta skill

1. **Passo 0 — pergunte antes de gerar** (instância, política, o que é retentável, tipo de janela). Não assuma.
2. Entregue, na ordem da seção "Entrega": deps → port/adapter com as anotações + fallback → `application.yml` (instâncias + actuator/métricas) → beans de log de evento → checklist.
3. Para aprofundar, leia a referência adequada:

| Quando | Leia |
|---|---|
| Catálogo completo das métricas Micrometer expostas (nomes, tags, o que significam), endpoints do Actuator, exemplo de scrape Prometheus e o que alarmar | `references/observabilidade.md` |
| Tuning fino: tipos de sliding window (COUNT × TIME), slow calls, backoff exponencial + jitter, ordem dos aspectos e a regra de **onde colocar o `fallbackMethod`**, idempotência do retry, e quando agregar Time Limiter / Bulkhead | `references/tuning-avancado.md` |

---

## Passo 0 — Perguntar antes de gerar

Antes de escrever qualquer código, confirme (em contexto automático sem resposta, use os defaults indicados):

1. **Nome da instância** — a chave que amarra tudo (anotação ↔ yaml ↔ métrica ↔ log). Use o **nome do recurso protegido** (ex.: `paymentGateway`, `inventory`). Veja o quadro abaixo.
2. **O que conta como falha?** Quais exceções devem **retentar** e **abrir o breaker**, e quais devem ser **ignoradas** (não é doença do downstream — ex.: um `404`/4xx). Default para chamada HTTP: retenta/conta `5xx` + timeout; ignora `4xx`.
3. **Volume e regularidade do tráfego?** Peça o TPS médio (ou req/min) e se há períodos de silêncio (madrugada, fora do horário de pico). Use o quadro abaixo para escolher entre `COUNT_BASED` e `TIME_BASED`. Default: `COUNT_BASED`.
4. **A operação é idempotente?** (GET/PUT/DELETE sim; POST que cria recurso, normalmente não). Retry de timeout em operação **não idempotente** pode duplicar efeito — confirme antes de retentar `POST`. Detalhe em `references/tuning-avancado.md`.
5. **Fallback (resultado degradado)?** O que retornar quando todas as tentativas falharem ou o breaker estiver aberto. Default recomendado: um **resultado de domínio degradado** (ver seção 2), nunca relançar `RuntimeException` genérica.
6. **Prometheus?** Se o ambiente faz scrape Prometheus, inclua `micrometer-registry-prometheus`. Se não, as métricas ainda aparecem em `/actuator/metrics`. Default: incluir Prometheus.

**Como escolher o tipo de janela (pergunta 3):**

| Cenário | Tipo | Raciocínio |
|---|---|---|
| Tráfego estável, ≥ 20 req/min sem longos silêncios | `COUNT_BASED` | Janela de N chamadas fixas é previsível; o breaker sempre tem amostra fresca para decidir |
| Tráfego irregular, bursty ou com períodos de baixíssimo volume | `TIME_BASED` | Evita que falhas de um pico contaminem o breaker horas depois; a janela avança pelo tempo, não pela contagem |
| TPS < 5 (< 5 req/min) | `TIME_BASED` + `minimum-number-of-calls` baixo | Com `COUNT_BASED` e volume muito baixo, `minimum-number-of-calls` pode nunca ser atingido — o breaker fica eternamente "sem dados" |
| Serviço batch com rajadas esporádicas | `TIME_BASED` | As rajadas preenchem e esvaziam a janela COUNT muito rapidamente, causando decisões ruidosas |

> **O nome da instância amarra 4 pontos — mantenha idêntico em todos:**
> 1. `@CircuitBreaker(name = "paymentGateway")` e `@Retry(name = "paymentGateway")`
> 2. `resilience4j.circuitbreaker.instances.paymentGateway.*` e `resilience4j.retry.instances.paymentGateway.*`
> 3. As **tags** das métricas (`name="paymentGateway"`) — é como você filtra no Grafana
> 4. O campo `kv("instance", ...)` nos logs de evento — é como você correlaciona log ↔ métrica

---

## Onde a resiliência mora — no adapter, atrás de um port

Seguindo o padrão de inversão de dependência das nossas regras: o **domínio depende de um port** (interface) e **não sabe que existe Resilience4J**. As anotações `@Retry`/`@CircuitBreaker` ficam na **implementação de infraestrutura** (o adapter), porque o AOP do Spring só intercepta chamadas que passam pelo proxy do bean. Resiliência é detalhe de infra; mantê-la no adapter deixa o domínio testável e agnóstico.

```
domínio:   PaymentGateway (port)  ──►  PaymentResult (sealed: Authorized | Declined | Unavailable)
infra:     PaymentGatewayClient (adapter, @Component) — aqui moram @Retry + @CircuitBreaker + fallback
                                   └─► PaymentHttpClient (@HttpExchange, da skill de HTTP client)
```

---

## Entrega — sempre nesta ordem

### 1 — Dependências Maven

```xml
<dependency>
    <groupId>io.github.resilience4j</groupId>
    <artifactId>resilience4j-spring-boot4</artifactId>
    <version>2.4.0</version>
</dependency>

<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-aop</artifactId>
</dependency>

<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>

<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
    <scope>runtime</scope>
</dependency>
```

> **Métricas saem de graça.** O starter já depende de `resilience4j-micrometer`; com o `micrometer-core` (vindo do Actuator) no classpath, **o binding das métricas é automático** — você não escreve nenhum `MeterBinder`. Por isso o Actuator não é opcional aqui: é o que cumpre o requisito de expor métricas via Micrometer.

### 2 — Port, adapter e resultado de domínio

O resultado é uma **sealed interface** (sucesso/recusa/indisponível são caminhos de negócio, não exceções — conforme as regras). O fallback constrói o caminho `Unavailable`.

O `fallbackMethod` fica obrigatoriamente no `@Retry` (aspecto externo), nunca no `@CircuitBreaker`. Cada aspecto que declara `fallbackMethod` captura a exceção dos aspectos internos e devolve o resultado ali mesmo — se o fallback estivesse no `@CircuitBreaker` (interno), ele engoliria a falha na primeira tentativa e o Retry nunca rodaria. A assinatura do fallback é: mesmos parâmetros do método protegido + um `Throwable` ao final.

```java
public interface PaymentGateway {
    PaymentResult authorize(PaymentRequest request);
}

public sealed interface PaymentResult permits Authorized, Declined, Unavailable {
    record Authorized(String orderId, String authorizationId) implements PaymentResult {}
    record Declined(String orderId, String reason) implements PaymentResult {}
    record Unavailable(String orderId) implements PaymentResult {}
}
```

```java
import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import io.github.resilience4j.retry.annotation.Retry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import static net.logstash.logback.argument.StructuredArguments.kv;

@Component
public class PaymentGatewayClient implements PaymentGateway {

    private static final Logger log = LoggerFactory.getLogger(PaymentGatewayClient.class);
    private final PaymentHttpClient http;

    public PaymentGatewayClient(PaymentHttpClient http) {
        this.http = http;
    }

    @Override
    @Retry(name = "paymentGateway", fallbackMethod = "authorizeFallback")
    @CircuitBreaker(name = "paymentGateway")
    public PaymentResult authorize(PaymentRequest request) {
        var response = http.authorize(request);
        return new PaymentResult.Authorized(request.orderId(), response.authorizationId());
    }

    private PaymentResult authorizeFallback(PaymentRequest request, Throwable t) {
        log.warn("gateway de pagamento indisponível — retornando resultado degradado",
                kv("instance", "paymentGateway"),
                kv("orderId", request.orderId()),
                kv("cause", t.getClass().getSimpleName()));
        return new PaymentResult.Unavailable(request.orderId());
    }
}
```

### 3 — application.yml

O `sliding-window-type` é determinado pela resposta à pergunta 3 do Passo 0. O exemplo usa `COUNT_BASED` (tráfego estável); troque por `TIME_BASED` e ajuste `sliding-window-size` para segundos quando o tráfego for irregular — veja o quadro do Passo 0 e a seção 1 de `references/tuning-avancado.md`.

```yaml
resilience4j:
  retry:
    instances:
      paymentGateway:
        max-attempts: 3
        wait-duration: 500ms
        enable-exponential-backoff: true
        exponential-backoff-multiplier: 2
        exponential-max-wait-duration: 5s
        enable-randomized-wait: true
        randomized-wait-factor: 0.5
        retry-exceptions:
          - org.springframework.web.client.HttpServerErrorException
          - org.springframework.web.client.ResourceAccessException
        ignore-exceptions:
          - org.springframework.web.client.HttpClientErrorException
          - io.github.resilience4j.circuitbreaker.CallNotPermittedException

  circuitbreaker:
    instances:
      paymentGateway:
        sliding-window-type: COUNT_BASED
        sliding-window-size: 20
        minimum-number-of-calls: 5
        failure-rate-threshold: 50
        wait-duration-in-open-state: 10s
        permitted-number-of-calls-in-half-open-state: 3
        automatic-transition-from-open-to-half-open-enabled: true
        record-exceptions:
          - org.springframework.web.client.HttpServerErrorException
          - org.springframework.web.client.ResourceAccessException
        ignore-exceptions:
          - org.springframework.web.client.HttpClientErrorException

management:
  endpoints:
    web:
      exposure:
        include: health, info, metrics, prometheus, circuitbreakers, circuitbreakerevents, retries, retryevents
  endpoint:
    health:
      show-details: always
  health:
    circuitbreakers:
      enabled: true
```

Dois pontos que costumam passar batido (detalhados em `references/tuning-avancado.md`):

- **`ignore-exceptions` do retry precisa listar `CallNotPermittedException`.** Com o breaker aberto, cada tentativa volta na hora com esse erro; se o retry não o ignorar, você queima `max-attempts × wait-duration` de latência batendo num circuito que já está aberto.
- **`ignore-exceptions` do breaker precisa listar os 4xx.** Tráfego normal de "não encontrado" (404) não pode abrir o circuito — só falha real (5xx/timeout) é doença do downstream. **Nunca** liste a base `RestClientException` em `record-`/`retry-exceptions`: ela englobaria 4xx e erros de desserialização.

### 4 — Log dos eventos (estado do breaker, retries)

Anexe os listeners via **`RegistryEventConsumer`**: o Spring o aplica a **toda instância** criada no registry, inclusive as lazy — você não precisa buscar cada breaker pelo nome. Formato de log segue a skill `spring-java-log-standardization` (`kv()` + MDC).

```java
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.core.registry.EntryAddedEvent;
import io.github.resilience4j.core.registry.EntryRemovedEvent;
import io.github.resilience4j.core.registry.EntryReplacedEvent;
import io.github.resilience4j.core.registry.RegistryEventConsumer;
import io.github.resilience4j.retry.Retry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import static net.logstash.logback.argument.StructuredArguments.kv;

@Configuration
public class ResilienceEventLoggingConfig {

    private static final Logger log = LoggerFactory.getLogger("resilience");

    @Bean
    public RegistryEventConsumer<CircuitBreaker> circuitBreakerEventLogger() {
        return new RegistryEventConsumer<>() {
            @Override
            public void onEntryAddedEvent(EntryAddedEvent<CircuitBreaker> event) {
                event.getAddedEntry().getEventPublisher().onStateTransition(e -> {
                    var transition = e.getStateTransition();
                    switch (transition.getToState()) {
                        case OPEN, FORCED_OPEN -> log.warn("circuit breaker ABRIU",
                                kv("instance", e.getCircuitBreakerName()),
                                kv("from", transition.getFromState()),
                                kv("to", transition.getToState()));
                        case CLOSED -> log.info("circuit breaker FECHOU (recuperado)",
                                kv("instance", e.getCircuitBreakerName()),
                                kv("from", transition.getFromState()),
                                kv("to", transition.getToState()));
                        default -> log.info("circuit breaker em teste de recuperação",
                                kv("instance", e.getCircuitBreakerName()),
                                kv("from", transition.getFromState()),
                                kv("to", transition.getToState()));
                    }
                });
            }
            @Override public void onEntryRemovedEvent(EntryRemovedEvent<CircuitBreaker> e) {}
            @Override public void onEntryReplacedEvent(EntryReplacedEvent<CircuitBreaker> e) {}
        };
    }

    @Bean
    public RegistryEventConsumer<Retry> retryEventLogger() {
        return new RegistryEventConsumer<>() {
            @Override
            public void onEntryAddedEvent(EntryAddedEvent<Retry> event) {
                event.getAddedEntry().getEventPublisher()
                        .onRetry(e -> log.warn("retentando chamada",
                                kv("instance", e.getName()),
                                kv("attempt", e.getNumberOfRetryAttempts()),
                                kv("waitInterval", e.getWaitInterval()),
                                kv("lastException", e.getLastThrowable() == null
                                        ? "n/a" : e.getLastThrowable().getClass().getSimpleName())))
                        .onError(e -> log.error("retry esgotado — todas as tentativas falharam",
                                kv("instance", e.getName()),
                                kv("totalAttempts", e.getNumberOfRetryAttempts()),
                                e.getLastThrowable()));
            }
            @Override public void onEntryRemovedEvent(EntryRemovedEvent<Retry> e) {}
            @Override public void onEntryReplacedEvent(EntryReplacedEvent<Retry> e) {}
        };
    }
}
```

> Se o projeto **ainda não tem** o padrão de log estruturado (`logstash-logback-encoder`, `kv()`), gere-o com a skill `spring-java-log-standardization` — esta skill assume esse encoder.

### 5 — Checklist de conformidade

- [ ] **Nome da instância idêntico** nas anotações, no yaml, nas tags de métrica e no `kv("instance", ...)`.
- [ ] `@Retry` e `@CircuitBreaker` estão no **adapter de infra**, não no domínio; o domínio depende do **port**.
- [ ] **`fallbackMethod` está no `@Retry`** (aspecto externo) — retenta antes de degradar.
- [ ] Retry **ignora** `CallNotPermittedException` e os `4xx`; **retenta** apenas `5xx`/timeout.
- [ ] Breaker **ignora** `4xx`; **conta** apenas `5xx`/timeout. Nenhuma lista usa a base `RestClientException`.
- [ ] **Tipo de janela escolhido com base no tráfego** (COUNT_BASED para volume estável; TIME_BASED para tráfego irregular ou TPS < 5).
- [ ] Retry de operação **não idempotente** foi confirmado com o usuário (risco de efeito duplicado).
- [ ] Fallback retorna **resultado de domínio degradado** (sealed interface), não relança `RuntimeException`.
- [ ] **Métricas via Micrometer ativas**: Actuator no classpath; `/actuator/metrics` lista `resilience4j.circuitbreaker.*` e `resilience4j.retry.*`.
- [ ] **Transição de estado do breaker logada** (WARN ao abrir, INFO ao fechar).
- [ ] **Retry logado**: WARN a cada tentativa, ERROR no esgotamento.
- [ ] Valores de política (janelas, thresholds, attempts, backoff) tratados como **ponto de partida** a calibrar — ver `references/tuning-avancado.md`.
- [ ] **Nenhum comentário desnecessário** no código gerado — sem Javadoc descritivo, sem comentários que explicam o *que* o código faz, sem referências à tarefa ou ao fix.

---

## Critérios de aceitação

Considere concluído somente quando:

1. A chamada protegida está atrás de um **port**, com a resiliência no **adapter**.
2. O que é retentável / contável está mapeado nas **exceções nativas** corretas, com os `ignore-exceptions` essenciais (`CallNotPermittedException` no retry; `4xx` em ambos).
3. O **tipo de janela do circuit breaker** foi escolhido com base no perfil de tráfego informado.
4. As **métricas do Resilience4J aparecem no Micrometer** (`/actuator/metrics` e, se aplicável, `/actuator/prometheus`).
5. **Toda transição de estado** do circuit breaker é logada, e **cada retry e o esgotamento** são logados, no formato estruturado do projeto.
6. O fallback devolve um **resultado de domínio** coerente, sem relançar exceção genérica.
