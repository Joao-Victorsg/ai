# Tuning do container, throughput e modelo de threads

Esta referência aprofunda a configuração do container de listeners: parâmetros, throughput/backpressure, e a diferença entre processamento blocking e não-blocking (que também explica a limitação do MDC).

## Parâmetros e onde definir

| Conceito | `@SqsListener` | Factory (`options`) | `application.yml` (`spring.cloud.aws.sqs.listener`) | Default |
|---|---|---|---|---|
| Concorrência por fila | `maxConcurrentMessages` | `.maxConcurrentMessages(int)` | `max-concurrent-messages` | 10 |
| Mensagens por poll (≤ 10) | `maxMessagesPerPoll` | `.maxMessagesPerPoll(int)` | `max-messages-per-poll` | 10 |
| Espera por poll (long polling) | `pollTimeoutSeconds` | `.pollTimeout(Duration)` | `poll-timeout` | 10s |
| Espera entre polls | — | `.maxDelayBetweenPolls(Duration)` | `max-delay-between-polls` | 10s |
| Visibility timeout | `messageVisibilitySeconds` | `.messageVisibility(Duration)` | *(não há)* | o da fila |
| Modo de ack | `acknowledgementMode` | `.acknowledgementMode(...)` | *(não há)* | `ON_SUCCESS` |
| Backpressure | — | `.backPressureMode(...)` | *(não há)* | `AUTO` |
| Auto-startup | — | — | `auto-startup` | true |

> `acknowledgement-mode`, `message-visibility` e `back-pressure-mode` **não** têm propriedade no `application.yml`. Defina-os na anotação (por listener) ou na factory (global).

## Modelo de threads

O container dimensiona o pool de threads como **`maxConcurrentMessages × número de filas`**. Ou seja, `maxConcurrentMessages = 10` em um listener de 1 fila processa até 10 mensagens em paralelo, em 10 threads.

Implicações:
- Aumentar a concorrência aumenta o paralelismo, mas também a pressão sobre recursos downstream (conexões de banco, rate limits de APIs). Dimensione o pool de conexões do banco coerentemente.
- Cada mensagem em processamento conta como "inflight" no SQS — e o `visibilityTimeout` deve cobrir o tempo total que ela fica retida.

## Throughput: low vs high

Por padrão o container começa em **low throughput mode** (um poll por vez). Quando um poll retorna ao menos uma mensagem, ele entra em **high throughput mode** e passa a fazer polls em paralelo até atingir `maxConcurrentMessages`. Quando um poll volta vazio, retorna a low throughput. Isso economiza chamadas em filas ociosas e escala automaticamente quando há volume.

### `BackPressureMode`

Configurável na factory via `.backPressureMode(...)`:

| Modo | Comportamento | Quando usar |
|---|---|---|
| `AUTO` (default) | Alterna automaticamente entre low e high throughput | Maioria dos casos |
| `ALWAYS_POLL_MAX_MESSAGES` | Só faz novo poll quando há permits para o batch completo; menos polls, menor throughput | Reduzir nº de chamadas ao SQS |
| `FIXED_HIGH_THROUGHPUT` | Nunca entra em low throughput; mantém polls paralelos mesmo ocioso | Filas com latência crítica e volume constante |

```java
import io.awspring.cloud.sqs.listener.BackPressureMode;

@Bean
SqsMessageListenerContainerFactory<Object> sqsListenerContainerFactory(SqsAsyncClient client) {
    return SqsMessageListenerContainerFactory.builder()
        .sqsAsyncClient(client)
        .configure(options -> options
            .maxConcurrentMessages(20)
            .maxMessagesPerPoll(10)
            .pollTimeout(Duration.ofSeconds(10))
            .backPressureMode(BackPressureMode.AUTO))
        .build();
}
```

## Blocking vs não-blocking

**Blocking (padrão):** o método do listener retorna `void` (ou um valor) e o container espera ele terminar. `intercept` → listener → `afterProcessing` rodam na **mesma thread** do pool. É o que a maioria dos workers usa.

```java
@SqsListener("minha-fila")
public void listen(MeuEvento e) { /* processamento síncrono */ }
```

**Não-blocking:** o método retorna `CompletableFuture<Void>`. O container não fica preso esperando — pode iniciar outras mensagens enquanto a operação assíncrona não completa, melhorando throughput em I/O-bound.

```java
@SqsListener("minha-fila")
public CompletableFuture<Void> listen(MeuEvento e) {
    return service.processarAsync(e);   // não bloqueia a thread de processamento
}
```

### Impacto no MDC (thread-local)

O MDC é **thread-local**. Em listeners **blocking**, o `MessageInterceptor` (seção 9 do SKILL) cobre tudo: o `correlationId` colocado em `intercept` permanece visível no listener e é limpo em `afterProcessing`, pois é a mesma thread.

Em listeners **não-blocking**, a continuação do `CompletableFuture` pode rodar em **outra thread** — onde o MDC populado em `intercept` não existe. Nesses casos:
- Propague o `correlationId` explicitamente (parâmetro/contexto), ou
- Use um wrapper que copie o MDC para a thread da continuação (`MDC.getCopyOfContextMap()` / `setContextMap`), ou
- Prefira listeners blocking quando rastreabilidade via MDC for essencial e o ganho de throughput não justificar a complexidade.
</content>
