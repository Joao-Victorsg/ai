# SQS Avançado — SqsTemplate

## Envio em Lote (Batch)

O `SqsTemplate` suporta envio de múltiplas mensagens em uma única chamada via `sendMany`. O SQS limita a **10 mensagens por lote** — lotes maiores lançam `TooManyEntriesInBatchRequestException`.

### Estratégia de falha parcial (THROW vs DO_NOT_THROW)

Por padrão, se qualquer mensagem do lote falhar, `sendMany` lança `SendBatchOperationFailedException` **antes de retornar** — o `SendResult.Batch` nunca é retornado. A exceção carrega o resultado misto via `getSendBatchResult(Class<T>)`.

Há duas formas de tratar isso:

**Opção A — capturar a exceção (com a config padrão THROW):**

```java
import io.awspring.cloud.sqs.operations.SendBatchOperationFailedException;
import io.awspring.cloud.sqs.operations.SendResult;
import org.springframework.messaging.support.MessageBuilder;

private static final int SQS_BATCH_SIZE = 10;

public void publicarLote(List<PedidoCriadoEvent> eventos) {
    String correlationId = MDC.get("correlationId");  // MDC é thread-local — capture antes do loop

    for (int i = 0; i < eventos.size(); i += SQS_BATCH_SIZE) {
        var chunk = eventos.subList(i, Math.min(i + SQS_BATCH_SIZE, eventos.size()));
        var mensagens = chunk.stream()
            .map(e -> MessageBuilder.withPayload(e)
                .setHeader("correlationId", correlationId)
                .build())
            .toList();

        try {
            SendResult.Batch<PedidoCriadoEvent> batch = sqsTemplate.sendMany(pedidosQueue, mensagens);
            // Chegou aqui: todos enviados com sucesso
            batch.successful().forEach(r ->
                log.info("Evento publicado", kv("messageId", r.messageId())));

        } catch (SendBatchOperationFailedException ex) {
            // Falha parcial: extrai o resultado misto da exceção
            SendResult.Batch<PedidoCriadoEvent> batch = ex.getSendBatchResult(PedidoCriadoEvent.class);
            batch.successful().forEach(r ->
                log.info("Evento publicado (parcial)", kv("messageId", r.messageId())));
            batch.failed().forEach(f ->
                log.error("Falha ao publicar evento",
                    kv("errorCode", f.errorCode()),
                    kv("errorMessage", f.errorMessage())));
        }
    }
}
```

**Opção B — configurar DO_NOT_THROW para receber o `SendResult.Batch` sempre:**

```java
import io.awspring.cloud.sqs.operations.SqsTemplate;
import io.awspring.cloud.sqs.operations.SendBatchFailureHandlingStrategy;

@Bean
SqsTemplate sqsTemplate(SqsAsyncClient sqsAsyncClient) {
    return SqsTemplate.builder()
        .sqsAsyncClient(sqsAsyncClient)
        .configure(options -> options
            .sendBatchFailureHandlingStrategy(SendBatchFailureHandlingStrategy.DO_NOT_THROW))
        .build();
}
```

Com `DO_NOT_THROW`, `sendMany` sempre retorna o `SendResult.Batch` sem lançar exceção — `batch.failed()` contém as falhas:

```java
SendResult.Batch<PedidoCriadoEvent> batch = sqsTemplate.sendMany(pedidosQueue, mensagens);
batch.successful().forEach(r -> log.info("Enviado", kv("messageId", r.messageId())));
batch.failed().forEach(f -> log.error("Falhou", kv("errorMessage", f.errorMessage())));
```

> **Qual usar?** `DO_NOT_THROW` é mais simples de ler. `THROW` (padrão) força o chamador a tratar falhas explicitamente — o compilador não deixa ignorar a exceção. Prefira `DO_NOT_THROW` se o código vai sempre inspecionar `batch.failed()` de qualquer forma.

---

## SendResult — Detalhes

O `SendResult<T>` retornado por `send(...)` contém:

```java
public record SendResult<T>(
    UUID messageId,                        // ID atribuído pelo SQS
    String endpoint,                       // nome/URL da fila destino
    Message<T> message,                    // mensagem enviada com todos os headers adicionados
    Map<String, Object> additionalInformation  // informações extras (ex.: sequenceNumber para FIFO)
) {}
```

Para filas FIFO, o `sequenceNumber` fica em `additionalInformation`:

```java
SendResult<PedidoCriadoEvent> result = sqsTemplate.send(to -> to
    .queue(pedidosQueue)
    .payload(event)
    .messageGroupId("pedido-" + event.clienteId())
    .messageDeduplicationId(event.pedidoId()));

String sequenceNumber = (String) result.additionalInformation()
    .get("sequenceNumber");   // sequência de entrega garantida pelo FIFO
```

---

## SqsTemplate com Builder (configuração avançada)

O `SqsTemplate.newTemplate(sqsAsyncClient)` cobre a maioria dos casos. Use o builder quando precisar de:

- **`defaultEndpointName`** — fila padrão para chamadas sem especificar fila
- **`messageConverter`** — Jackson customizado
- **`observationRegistry`** — integração com Micrometer/OpenTelemetry

```java
import io.awspring.cloud.sqs.operations.SqsTemplate;
import io.awspring.cloud.sqs.support.converter.SqsMessagingMessageConverter;
import tools.jackson.databind.json.JsonMapper;

@Bean
SqsTemplate sqsTemplate(SqsAsyncClient sqsAsyncClient) {
    JsonMapper mapper = JsonMapper.builder()
        .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
        .build();

    return SqsTemplate.builder()
        .sqsAsyncClient(sqsAsyncClient)
        .messageConverter(new SqsMessagingMessageConverter(mapper))
        .configure(options -> options
            .defaultEndpointName("pedidos-queue"))    // fila default para send(payload) sem nome
        .build();
}
```

Com `defaultEndpointName` configurado, é possível omitir o nome da fila:

```java
sqsTemplate.send(event);   // usa a fila definida em defaultEndpointName
```

---

## Comportamento quando a fila não existe

Por padrão, o `SqsTemplate` lança exceção se a fila não for encontrada. Para ambientes onde a fila é criada dinamicamente ou via IaC (Terraform/CDK), configure a estratégia:

```java
import io.awspring.cloud.sqs.operations.SqsTemplate;

@Bean
SqsTemplate sqsTemplate(SqsAsyncClient sqsAsyncClient) {
    return SqsTemplate.builder()
        .sqsAsyncClient(sqsAsyncClient)
        .configure(options -> options
            .queueNotFoundStrategy(QueueNotFoundStrategy.FAIL))  // padrão: falha rápido
        .build();
}
```

> Em produção, `FAIL` é o comportamento correto — falha rápido se a infraestrutura não está provisionada, em vez de silenciosamente descartar mensagens.

---

## Async com opções completas

O `sendAsync` aceita o mesmo options builder do `send` síncrono:

```java
public CompletableFuture<SendResult<PedidoCriadoEvent>> publicarAsync(PedidoCriadoEvent event) {
    // Capture o correlationId antes de entrar no lambda — MDC é thread-local
    String correlationId = MDC.get("correlationId");

    return sqsTemplate.<PedidoCriadoEvent>sendAsync(to -> to
        .queue(pedidosQueue)
        .payload(event)
        .header("correlationId", correlationId)
        .messageGroupId("pedido-" + event.clienteId())     // se fila FIFO
        .messageDeduplicationId(event.pedidoId()));
}
```

---

## Operações de recebimento (fora do escopo)

O `SqsTemplate` também implementa operações de **recebimento** (`receive`, `receiveMany`, `receiveAsync`). Estas operações fazem polling manual, sem o ciclo automático do `@SqsListener`. Use-as **raramente** — o `@SqsListener` da skill `spring-java-sqs-listener` é o mecanismo padrão para consumo contínuo.
