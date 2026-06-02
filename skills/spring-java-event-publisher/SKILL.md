---
name: spring-java-event-publisher
description: Publica eventos/mensagens em filas Amazon SQS e tópicos Amazon SNS em Java 25 + Spring Boot 4 com Spring Cloud AWS 4 e Jackson 3 — SqsTemplate (send/sendAsync, options builder, FIFO, delay, batch) e SnsTemplate/SnsOperations (sendNotification com payload tipado, SnsNotification para FIFO e subject). Use sempre que o usuário pedir para publicar/enviar/produzir mensagens ou eventos em uma fila SQS ou tópico SNS, mencionar SqsTemplate, SnsTemplate, SqsOperations, SnsOperations, SnsNotification, publicar em tópico SNS, enviar mensagem para fila SQS, producer/publisher SQS ou SNS, FIFO SQS/SNS com groupId/deduplicationId, integrar um serviço Spring Boot como produtor de eventos, ou propagação de correlationId em eventos — mesmo sem citar "skill" ou "Spring Cloud AWS".
---

# Publisher de Eventos SQS/SNS — Spring Cloud AWS 4 · Spring Boot 4 · Java 25

Use esta skill para implementar **produtores (publishers)** de eventos para Amazon SQS e/ou Amazon SNS. O foco é o lado de publicação: serializar o payload, enviar para a fila/tópico e lidar com o resultado. **Consumo de mensagens está fora do escopo** — use a skill `spring-java-sqs-listener` para workers/listeners.

## Stack definida

| Decisão | Escolha |
|---|---|
| Linguagem | Java 25 (records) |
| Framework | Spring Boot 4.x |
| Publicação SQS | Spring Cloud AWS 4.0.x — `SqsTemplate` / `SqsOperations` |
| Publicação SNS | Spring Cloud AWS 4.0.x — `SnsTemplate` / `SnsOperations` |
| Serialização JSON | Jackson 3 (`tools.jackson`) — auto-configurado pelo starter |
| Build | Maven |
| Logs | Skill `spring-java-log-standardization` (MDC) |

## Como usar esta skill

1. **Passo 0 — pergunte antes de gerar** (destino, FIFO, sync/async). Não assuma.
2. Gere dependências + configuração + publisher no formato dos blocos abaixo.
3. Para tópicos avançados, leia o arquivo de referência adequado:

| Quando | Leia |
|---|---|
| Precisa de **envio em lote** (batch), `SendResult` detalhado, `defaultEndpointName`, `SqsTemplate.builder()` ou estratégia de falha parcial (`SendBatchOperationFailedException` / `DO_NOT_THROW`) | `references/sqs-advanced.md` |
| Precisa de **message attributes tipados** (String/Number), personalizar `SnsPublishMessageConverter`, usar `TopicArnResolver` ou SMS | `references/sns-advanced.md` |

---

## Passo 0 — Perguntar antes de gerar

Antes de escrever qualquer código, confirme com o usuário:

**1. Destino**: SQS direto, tópico SNS, ou ambos?

**2. Fila/tópico FIFO ou Standard?**
- **Standard** *(default)* — sem ordenação garantida.
- **FIFO** — exige `messageGroupId` (obrigatório) e `messageDeduplicationId` (recomendado). Nome da fila termina em `.fifo`.

**3. Modo de operação**: síncrono (resultado imediato) ou assíncrono (`CompletableFuture`)?
- **Sync** *(default)* — bloqueia até confirmar. Simples para a maioria dos casos.
- **Async** — retorna `CompletableFuture<SendResult<T>>`. Para SQS; para SNS assíncrono use `SnsAsyncClient` direto (ver seção 7).

**4. Payload**: qual é o record/DTO do evento? DTOs devem ser `record`.

**5. Delay (SQS Standard apenas)**: a mensagem deve ficar invisível por N segundos antes de ser entregue? (Default: sem delay.)

> Se o usuário não souber se a fila/tópico é FIFO, assuma **Standard**. Se não souber sync/async, assuma **sync**.

---

## 1 — Dependências Maven

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>io.awspring.cloud</groupId>
            <artifactId>spring-cloud-aws-dependencies</artifactId>
            <version>4.0.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>

<dependencies>
    <!-- Para publicar em filas SQS (também cobre o consumo — não repita se já declarado) -->
    <dependency>
        <groupId>io.awspring.cloud</groupId>
        <artifactId>spring-cloud-aws-starter-sqs</artifactId>
    </dependency>

    <!-- Para publicar em tópicos SNS (starter separado do SQS) -->
    <dependency>
        <groupId>io.awspring.cloud</groupId>
        <artifactId>spring-cloud-aws-starter-sns</artifactId>
    </dependency>
</dependencies>
```

> Declare apenas o starter do destino que o serviço usa. Se o projeto já tem `spring-cloud-aws-starter-sqs` para consumo, **não adicione novamente** — o `SqsTemplate` já vem com ele.

---

## 2 — Configuração via `application.yml`

Os starters auto-configuram `SqsTemplate` e `SnsTemplate`. Configure por propriedades — **não** crie os beans manualmente a menos que precise de customização (Jackson, TopicArnResolver).

```yaml
spring:
  cloud:
    aws:
      region:
        static: us-east-1
      credentials:
        access-key: ${AWS_ACCESS_KEY_ID:noop}
        secret-key: ${AWS_SECRET_ACCESS_KEY:noop}
      # 'endpoint' apenas para desenvolvimento local (ex.: LocalStack):
      endpoint: ${AWS_ENDPOINT:http://localhost:4566}

app:
  queues:
    pedidos: pedidos-queue
  topics:
    pedidos: arn:aws:sns:us-east-1:123456789012:pedidos
```

> Em produção, **não declare** `credentials` nem `endpoint` — o SDK resolve via IAM role e usa o endpoint padrão da AWS automaticamente.

> **Nomes de fila/tópico são injetados via `@Value`**, nunca passados como literal `"${app.queues.pedidos}"` em chamadas de método — Spring só resolve placeholders em anotações e campos, não em argumentos de método em tempo de execução.

---

## 3 — Publicar em Fila SQS

### 3.1 — Envio simples

Injete `SqsTemplate` (auto-configurado) e o nome da fila via `@Value`. O Jackson 3 serializa o record automaticamente para JSON e adiciona o header `JavaType` para que o consumidor possa desserializar o tipo correto.

```java
// DTO do evento — sempre um record
public record PedidoCriadoEvent(
        String pedidoId,
        String clienteId,
        BigDecimal valorTotal) {
}
```

```java
import io.awspring.cloud.sqs.operations.SendResult;
import io.awspring.cloud.sqs.operations.SqsTemplate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import static net.logstash.logback.argument.StructuredArguments.kv;

@Component
public class PedidoPublisher {

    private static final Logger log = LoggerFactory.getLogger(PedidoPublisher.class);

    private final SqsTemplate sqsTemplate;
    private final String pedidosQueue;

    public PedidoPublisher(SqsTemplate sqsTemplate,
                           @Value("${app.queues.pedidos}") String pedidosQueue) {
        this.sqsTemplate = sqsTemplate;
        this.pedidosQueue = pedidosQueue;
    }

    public void publicar(PedidoCriadoEvent event) {
        SendResult<PedidoCriadoEvent> result = sqsTemplate.send(pedidosQueue, event);
        log.info("Evento publicado na fila SQS",
            kv("messageId", result.messageId()),
            kv("pedidoId", event.pedidoId()));
    }
}
```

### 3.2 — Envio com opções (delay, headers, correlationId)

Quando precisar de delay, headers customizados ou propagação de `correlationId`:

```java
import org.slf4j.MDC;

public void publicar(PedidoCriadoEvent event) {
    SendResult<PedidoCriadoEvent> result = sqsTemplate.send(to -> to
        .queue(pedidosQueue)
        .payload(event)
        .header("correlationId", MDC.get("correlationId"))
        .delaySeconds(30));   // mensagem fica invisível 30s antes de ser entregue

    log.info("Evento publicado",
        kv("messageId", result.messageId()),
        kv("pedidoId", event.pedidoId()));
}
```

> `delaySeconds` só funciona em filas **Standard**. Filas FIFO **não suportam** delay por mensagem.

---

## 4 — Publicar em Tópico SNS

### 4.1 — Envio simples

`SnsTemplate` usa `SnsClient` (síncrono) auto-configurado pelo starter. O método `sendNotification` aceita um record e o serializa como JSON.

```java
import io.awspring.cloud.sns.core.SnsTemplate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import static net.logstash.logback.argument.StructuredArguments.kv;

@Component
public class PedidoSnsPublisher {

    private static final Logger log = LoggerFactory.getLogger(PedidoSnsPublisher.class);

    private final SnsTemplate snsTemplate;
    private final String pedidosTopic;

    public PedidoSnsPublisher(SnsTemplate snsTemplate,
                              @Value("${app.topics.pedidos}") String pedidosTopic) {
        this.snsTemplate = snsTemplate;
        this.pedidosTopic = pedidosTopic;
    }

    public void publicar(PedidoCriadoEvent event) {
        snsTemplate.sendNotification(
            pedidosTopic,        // ARN ou nome lógico do tópico
            event,               // payload: record serializado como JSON
            "PedidoCriado"       // subject — pode ser null; útil para subscriptions de e-mail
        );
        log.info("Evento publicado no tópico SNS",
            kv("pedidoId", event.pedidoId()));
    }
}
```

> O `SnsTemplate` aceita **ARN completo** (`arn:aws:sns:...`) ou **nome lógico** do tópico. Com nome lógico, o `TopicArnResolver` faz uma chamada extra à API SNS para resolver o ARN — prefira ARN em produção.

> `sendNotification` é `void` — diferente do SQS, o SNS não retorna um `messageId` de forma conveniente pelo template de alto nível.

### 4.2 — Com `SnsNotification` (headers e correlationId)

Quando precisar propagar headers (ex.: `correlationId`) ou usar metadados do SNS:

```java
import io.awspring.cloud.sns.core.SnsNotification;
import io.awspring.cloud.sns.core.SnsOperations;
import org.slf4j.MDC;

@Component
public class PedidoSnsPublisher {

    private final SnsOperations snsOperations;   // interface mais estreita, preferível
    private final String pedidosTopic;

    public PedidoSnsPublisher(SnsOperations snsOperations,
                              @Value("${app.topics.pedidos}") String pedidosTopic) {
        this.snsOperations = snsOperations;
        this.pedidosTopic = pedidosTopic;
    }

    public void publicar(PedidoCriadoEvent event) {
        snsOperations.sendNotification(pedidosTopic,
            SnsNotification.builder(event)
                .subject("PedidoCriado")
                .header("correlationId", MDC.get("correlationId"))
                .build());

        log.info("Evento publicado no tópico SNS",
            kv("pedidoId", event.pedidoId()));
    }
}
```

> **`SnsOperations`** é a interface preferida quando se usa `SnsNotification` — expõe o método `sendNotification(String, SnsNotification<?>)` sem os métodos de baixo nível do template.

---

## 5 — Filas e Tópicos FIFO

### 5.1 — Fila SQS FIFO

Filas FIFO (`nomeDaFila.fifo`) exigem `messageGroupId`. O `messageDeduplicationId` é opcional — se ausente e *content-based deduplication* estiver desabilitada na fila, o framework gera um UUID aleatório (não idempotente).

```java
public void publicar(PedidoCriadoEvent event) {
    SendResult<PedidoCriadoEvent> result = sqsTemplate.send(to -> to
        .queue(pedidosQueue)                                     // ex.: "pedidos.fifo"
        .payload(event)
        .messageGroupId("pedido-" + event.clienteId())          // obrigatório; define a ordenação
        .messageDeduplicationId(event.pedidoId()));              // use ID de negócio idempotente

    log.info("Evento publicado na fila FIFO",
        kv("messageId", result.messageId()),
        kv("pedidoId", event.pedidoId()));
}
```

> **`messageGroupId`** determina a partição de ordenação: mensagens do mesmo grupo chegam ao consumidor em sequência. Use um ID de negócio estável (ex.: `clienteId`, `tenantId`) para equilibrar paralelismo e ordenação.

> **Não use UUID aleatório como `messageDeduplicationId`** — ele não garante idempotência. Prefira um ID de negócio único por evento (ex.: `pedidoId`, hash do payload).

### 5.2 — Tópico SNS FIFO

Tópicos SNS FIFO usam `SnsNotification.builder()` com `groupId` e `deduplicationId`:

```java
public void publicar(PedidoCriadoEvent event) {
    snsOperations.sendNotification(pedidosTopic,
        SnsNotification.builder(event)
            .groupId("pedido-" + event.clienteId())             // obrigatório para FIFO
            .deduplicationId(event.pedidoId())                  // recomendado: ID de negócio
            .subject("PedidoCriado")
            .build());

    log.info("Evento publicado no tópico SNS FIFO",
        kv("pedidoId", event.pedidoId()));
}
```

---

## 6 — Jackson 3 e Serialização

Os starters auto-configuram conversores Jackson 3 para SQS e SNS. **Records serializam sem configuração extra.**

O `SqsTemplate` adiciona automaticamente o header `JavaType` com o nome completo da classe do payload — o consumidor (`@SqsListener`) usa esse header para desserializar o tipo correto sem configuração adicional em nenhum dos lados.

Para customizar o `ObjectMapper` do SQS (ex.: ignorar campos desconhecidos no consumo, registrar módulos):

```java
import tools.jackson.databind.json.JsonMapper;                     // pacote Jackson 3
import tools.jackson.databind.DeserializationFeature;
import io.awspring.cloud.sqs.support.converter.SqsMessagingMessageConverter;

@Bean
SqsMessagingMessageConverter sqsMessagingMessageConverter() {
    JsonMapper mapper = JsonMapper.builder()
        .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)  // tolera campos novos
        .build();
    return new SqsMessagingMessageConverter(mapper);
}
```

> **Pacote Jackson 3:** imports são `tools.jackson.*`, não `com.fasterxml.jackson.*`. O BOM do Spring Boot 4 gerencia a versão — **não declare Jackson manualmente**. Para customização do SNS, ver `references/sns-advanced.md`.

---

## 7 — Operações assíncronas

### SQS assíncrono

O `SqsTemplate` também implementa `SqsAsyncOperations`. Use `sendAsync` para não bloquear a thread:

```java
import java.util.concurrent.CompletableFuture;

public CompletableFuture<Void> publicarAsync(PedidoCriadoEvent event) {
    return sqsTemplate.<PedidoCriadoEvent>sendAsync(to -> to
            .queue(pedidosQueue)
            .payload(event)
            .header("correlationId", MDC.get("correlationId")))
        .whenComplete((result, ex) -> {
            if (ex != null) {
                log.error("Falha ao publicar evento SQS",
                    kv("pedidoId", event.pedidoId()), ex);
            } else {
                log.info("Evento publicado",
                    kv("messageId", result.messageId()),
                    kv("pedidoId", event.pedidoId()));
            }
        })
        .thenApply(_ -> null);
}
```

> **MDC e threads:** `MDC.get("correlationId")` é thread-local — capture o valor **antes** de entrar no callback assíncrono. Se o callback rodar em outra thread, o MDC estará vazio nela.

### SNS assíncrono

`SnsTemplate` usa `SnsClient` síncrono. Para publicação assíncrona no SNS, injete `SnsAsyncClient` diretamente:

```java
import software.amazon.awssdk.services.sns.SnsAsyncClient;
import software.amazon.awssdk.services.sns.model.PublishRequest;

@Component
public class PedidoSnsAsyncPublisher {

    private final SnsAsyncClient snsAsyncClient;
    private final String pedidosTopic;
    private final ObjectMapper objectMapper;

    // ...

    public CompletableFuture<Void> publicarAsync(PedidoCriadoEvent event) {
        String payload = objectMapper.writeValueAsString(event);   // serialização manual
        return snsAsyncClient.publish(PublishRequest.builder()
                .topicArn(pedidosTopic)
                .message(payload)
                .subject("PedidoCriado")
                .build())
            .thenApply(_ -> null);
    }
}
```

> Para a maioria dos casos, o `SnsTemplate` síncrono é suficiente — evite a complexidade do cliente low-level a menos que o throughput exija.

---

## 8 — Tratamento de erros

O `SqsTemplate.send(...)` e `SnsTemplate.sendNotification(...)` lançam exceções de runtime em caso de falha de comunicação com a AWS. **Não silencie essas exceções** — deixe-as propagar para o chamador.

**Retry de erros transitórios:** aplique Resilience4j ou Spring Retry no **service que chama o publisher**, não dentro do publisher. O publisher deve ser stateless.

```java
// Publisher: não faz retry, apenas publica
@Component
public class PedidoPublisher {
    public void publicar(PedidoCriadoEvent event) {
        sqsTemplate.send(pedidosQueue, event);  // exceção sobe para o chamador
    }
}

// Service: retry no ponto de chamada
@Service
public class PedidoService {
    @Retry(name = "sqs-publish")                // Resilience4j
    public void processarEPublicar(PedidoCriadoEvent event) {
        pedidoPublisher.publicar(event);
    }
}
```

---

## Checklist de conformidade

- [ ] O **destino** (SQS, SNS ou ambos) foi confirmado com o usuário.
- [ ] O starter correto está declarado (`sqs` e/ou `sns`); não duplicado se já existia.
- [ ] DTOs de evento são `record`.
- [ ] Nome de fila/tópico é **injetado via `@Value`** no construtor — nenhum literal `"${...}"` é passado em chamada de método.
- [ ] O publisher injeta `SqsTemplate` ou `SnsTemplate`/`SnsOperations` — sem `SqsClient`/`SnsClient` manual para publicação de alto nível.
- [ ] Filas/tópicos FIFO: `messageGroupId` está presente e usa ID de negócio estável.
- [ ] `messageDeduplicationId` usa ID idempotente de negócio (não UUID aleatório) para filas FIFO sem *content-based deduplication*.
- [ ] `delaySeconds` só é usado em filas **Standard** (nunca FIFO).
- [ ] O `correlationId` é propagado como header/atributo de mensagem.
- [ ] Exceções do publisher **não são silenciadas** — retry fica no chamador.
- [ ] Imports Jackson 3 usam `tools.jackson.*` — não `com.fasterxml.jackson.*`.
