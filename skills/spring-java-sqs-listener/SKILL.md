---
name: spring-java-sqs-listener
description: Implementa workers (consumidores) SQS em Java 25 + Spring Boot 4 com Spring Cloud AWS 4 e Jackson 3 — @SqsListener desserializando direto para records, @SqsHandler/sealed interface para múltiplos tipos de evento, AcknowledgementMode (MANUAL/ON_SUCCESS/ALWAYS), tuning de container (concorrência, visibilityTimeout, maxMessagesPerPoll, pollTimeout, backpressure), MDC via MessageInterceptor e @SnsNotificationMessage/SnsNotification para filas subscritas em tópicos SNS. Use sempre que o usuário pedir um worker/listener/consumer SQS, mencionar @SqsListener, @SqsHandler, AcknowledgementMode, SqsAsyncClient, consumir/processar mensagens ou eventos de uma fila SQS, desserializar payload de SQS, configurar concorrência/visibility timeout/DLQ de SQS, perguntar o que acontece quando o worker lança exceção, ou mencionar @SnsNotificationMessage, SnsNotification, fila subscrita em tópico SNS, SNS fan-out para SQS — mesmo sem citar "skill" ou "Spring Cloud AWS".
---

# Worker SQS — Spring Cloud AWS 4 · Spring Boot 4 · Java 25

Use esta skill para implementar **consumidores (workers)** de filas Amazon SQS. O foco é o lado de consumo: receber a mensagem, desserializar o payload, processar e confirmar (ack) corretamente. **Publicação de mensagens, consumo em lote e filas FIFO estão fora do escopo** — se o usuário pedir isso, avise que esta skill cobre apenas consumo e ofereça orientação geral.

## Stack definida

| Decisão | Escolha |
|---|---|
| Linguagem | Java 25 (records + sealed interfaces + switch com pattern matching) |
| Framework | Spring Boot 4.x |
| Integração SQS | Spring Cloud AWS 4.0.x (`io.awspring.cloud`) |
| Serialização JSON | Jackson 3 (`tools.jackson`) — auto-configurado pelo starter |
| Cliente AWS | `SqsAsyncClient` (auto-configurado) |
| Build | Maven |
| Logs | Skill `spring-java-log-standardization` (MDC via `MessageInterceptor`) |

## Como usar esta skill

1. **Passo 0 — pergunte antes de gerar** (ack mode e, se houver múltiplos tipos, a abordagem). Não assuma.
2. Gere dependências + configuração do cliente + listener no formato dos blocos abaixo.
3. Para tópicos mais profundos, leia o arquivo de referência adequado:

| Quando | Leia |
|---|---|
| O worker recebe **mais de um tipo** de evento na mesma fila | `references/multi-type-events.md` |
| Precisa **tunar throughput/concorrência**, entender blocking vs não-blocking, backpressure, dimensionamento de threads | `references/container-tuning.md` |
| Dúvidas sobre **exceção, retry, DLQ, redrive, ErrorHandler, at-least-once** | `references/error-handling-and-dlq.md` |
| A fila recebe mensagens de um **tópico SNS** (raw delivery OFF) | seção *10* |

---

## Passo 0 — Perguntar antes de gerar

Antes de escrever qualquer código, confirme com o usuário (se o contexto for automático e não houver resposta, use os defaults indicados):

**1. Modo de acknowledge.** Explique e pergunte qual prefere:

- **`ON_SUCCESS`** *(default recomendado)* — o ack é automático quando o método do listener **retorna sem lançar exceção**. Simples e cobre a maioria dos casos.
- **`MANUAL`** — o código chama `acknowledgement.acknowledge()` explicitamente após processar. Mais controle (ex.: confirmar só depois de persistir), mas exige cuidado para não esquecer o ack nem chamá-lo cedo demais.
- **`ALWAYS`** — o ack é feito **independente de sucesso ou falha**. A mensagem nunca é reentregue, mesmo com erro. Use **apenas quando perder a mensagem for aceitável**.

> Em qualquer modo exceto `ALWAYS`, uma exceção no listener faz com que a mensagem **não** seja confirmada — o SQS a reentrega automaticamente após o `visibilityTimeout` expirar. É assim que se obtém reprocessamento sem código de retry próprio (ver `references/error-handling-and-dlq.md`).

**2. Um tipo de evento ou múltiplos?**

- **Um tipo** → siga a seção *3 — Listener de evento único*.
- **Múltiplos tipos** na mesma fila → pergunte e encaminhe para `references/multi-type-events.md`:
  1. Qual **abordagem**: *sealed interface* (default recomendado — o tipo é autodescrito no payload via Jackson, sem acoplar consumidor e produtor) ou `@SqsHandler` (roteamento por tipo Java, exige header de tipo na mensagem)?
  2. Quais são os **tipos de evento** esperados?
  3. Qual o **payload (DTO — devem ser `record`)** de cada tipo?
  4. Se `@SqsHandler` com discriminação por header: **qual header** carrega o tipo?

**3. Rastreabilidade (logs).** De qual header/atributo da mensagem vem o `correlationId`? (Default: atributo de mensagem `correlationId`; se ausente, gera-se um novo — ver seção *9*.)

**4. Origem das mensagens: a fila é subscrita em um tópico SNS?**

- **Não / SQS direto** *(default)* — produtor publica diretamente na fila. Siga as seções 3 ou 4.
- **SNS → SQS (fan-out), *raw message delivery* OFF** *(default do SNS)* — o SNS envolve o payload num envelope JSON antes de entregar ao SQS. Use `@SnsNotificationMessage` para desembrulhar automaticamente (ver seção *10*).
- **SNS → SQS, *raw message delivery* ON** — o SNS entrega o payload bruto, sem envelope. Trate exatamente como SQS direto: siga a seção *3*.

> Se o usuário não souber se raw delivery está ativo, assuma **OFF** (é o default do SNS) e use `@SnsNotificationMessage`.

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
    <!-- Starter SQS: traz o SqsAsyncClient auto-configurado, o container de
         listeners e o conversor Jackson. -->
    <dependency>
        <groupId>io.awspring.cloud</groupId>
        <artifactId>spring-cloud-aws-starter-sqs</artifactId>
    </dependency>
</dependencies>
```

> A versão do Jackson vem do BOM do Spring Boot 4 (Jackson 3). Não declare Jackson manualmente.

---

## 2 — Configurar o `SqsAsyncClient` via `application.yml`

O starter registra um `SqsAsyncClient` automaticamente. Configure-o por propriedades — **não** crie o bean na mão a menos que precise de algo que as propriedades não cobrem.

```yaml
spring:
  cloud:
    aws:
      region:
        static: us-east-1
      # Em produção, NÃO declare credenciais nem endpoint:
      # o DefaultCredentialsProvider resolve via IAM role / variáveis de ambiente,
      # e o endpoint padrão da AWS é usado automaticamente.
      credentials:
        access-key: ${AWS_ACCESS_KEY_ID:noop}
        secret-key: ${AWS_SECRET_ACCESS_KEY:noop}
      # 'endpoint' só para desenvolvimento local (ex.: LocalStack):
      endpoint: ${AWS_ENDPOINT:http://localhost:4566}
      sqs:
        listener:
          # Defaults aplicados a todos os listeners (podem ser sobrescritos por listener):
          max-concurrent-messages: 10      # threads simultâneas por fila
          max-messages-per-poll: 10        # mensagens por poll (limite do SQS = 10)
          poll-timeout: 10s                # long polling: tempo de espera por mensagens
```

> **Atenção (ponto que costuma confundir):** `acknowledgement-mode` e o *visibility timeout* **não** são propriedades do `application.yml`. As propriedades de `listener` cobrem apenas concorrência, poll e auto-startup. Ack mode e visibility se definem na anotação `@SqsListener` ou na factory (seções *5* e *6*).

---

## 3 — Listener de evento único

O `@SqsListener` deve **desserializar o payload direto para o record esperado** — nunca receber `String` e desserializar à mão. O conversor Jackson 3 do starter resolve o tipo a partir da assinatura do método.

```java
// DTO do evento — sempre um record (imutável, conciso).
public record PedidoCriadoEvent(
        String pedidoId,
        String clienteId,
        BigDecimal valorTotal) {
}
```

```java
import io.awspring.cloud.sqs.annotation.SqsListener;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import static net.logstash.logback.argument.StructuredArguments.kv;

@Component
public class PedidoListener {

    private static final Logger log = LoggerFactory.getLogger(PedidoListener.class);

    @SqsListener("${app.queues.pedidos}")   // nome, URL ou ARN da fila
    public void onPedidoCriado(PedidoCriadoEvent event) {
        log.info("Processando pedido criado",
            kv("pedidoId", event.pedidoId()),
            kv("clienteId", event.clienteId()));

        // regra de negócio...
        // No modo ON_SUCCESS, retornar sem exceção confirma a mensagem.
    }
}
```

Para `AcknowledgementMode.MANUAL`, receba o `Acknowledgement` (ver seção *5*).

---

## 4 — Múltiplos tipos de evento (resumo)

Quando a mesma fila entrega vários tipos de evento, há duas abordagens. **Default: sealed interface.** Leia `references/multi-type-events.md` para o código completo das duas, incluindo a configuração do header de tipo (`SqsHeaders.SQS_DEFAULT_TYPE_HEADER = "JavaType"`) e do `payloadTypeMapper` customizado.

- **Sealed interface (recomendado):** um único `@SqsListener` recebe a interface selada que os eventos (records) implementam; o tipo concreto é resolvido pelo Jackson via `@JsonTypeInfo`/`@JsonSubTypes` (discriminador **no próprio payload**). Combina com `switch` por pattern matching. Não depende de o produtor enviar header de tipo.
- **`@SqsHandler`:** classe anotada com `@SqsListener` e vários métodos `@SqsHandler`, um por tipo de payload (`@SqsHandler(isDefault = true)` como fallback). O framework roteia pelo **tipo Java desserializado** — o que exige um header de tipo na mensagem ou um `payloadTypeMapper` que mapeie um header de domínio (ex.: `eventType`) para a classe.

---

## 5 — AcknowledgementMode

| Modo | Quando confirma | Reentrega em caso de erro? |
|---|---|---|
| `ON_SUCCESS` (default) | Ao retornar sem exceção | Sim (não confirma → SQS reentrega) |
| `MANUAL` | Quando o código chama `acknowledge()` | Sim, se você não chamar ack |
| `ALWAYS` | Sempre, com ou sem exceção | **Não** — mensagem nunca reentregue |

**Onde definir** (não há propriedade no `application.yml`):

```java
// Por listener, na anotação:
@SqsListener(value = "${app.queues.pedidos}", acknowledgementMode = "MANUAL")
```

ou globalmente na factory (seção *6*).

**Exemplo MANUAL** — confirme só depois de concluir o processamento:

```java
import io.awspring.cloud.sqs.annotation.SqsListener;
import io.awspring.cloud.sqs.listener.acknowledgement.Acknowledgement;

@SqsListener(value = "${app.queues.pedidos}", acknowledgementMode = "MANUAL")
public void onPedido(PedidoCriadoEvent event, Acknowledgement acknowledgement) {
    pedidoService.processar(event);     // se lançar, o ack abaixo não roda
    acknowledgement.acknowledge();      // confirma só após sucesso
}
```

> **Por que não dar ack no `catch`:** em `ON_SUCCESS`/`MANUAL`, deixar a exceção subir (sem confirmar) é justamente o que dispara a reentrega pelo SQS e, depois de N tentativas, o envio para a DLQ. Capturar o erro e confirmar mesmo assim transforma a falha em perda silenciosa de mensagem.

---

## 6 — Configuração do container (resumo)

Mapeamento dos parâmetros que o usuário costuma citar para os nomes reais:

| Conceito | Atributo `@SqsListener` | Opção da factory | Propriedade `application.yml` |
|---|---|---|---|
| Concorrência (threads/fila) | `maxConcurrentMessages` | `.maxConcurrentMessages(int)` | `listener.max-concurrent-messages` |
| Mensagens por poll (≤ 10) | `maxMessagesPerPoll` | `.maxMessagesPerPoll(int)` | `listener.max-messages-per-poll` |
| Tempo de espera por poll | `pollTimeoutSeconds` | `.pollTimeout(Duration)` | `listener.poll-timeout` |
| Visibility timeout | `messageVisibilitySeconds` | `.messageVisibility(Duration)` | *(não há)* |
| Modo de ack | `acknowledgementMode` | `.acknowledgementMode(...)` | *(não há)* |

**`visibilityTimeout` — regra de ouro:** deve ser **maior que o tempo máximo esperado de processamento** de uma mensagem. Se o processamento demorar mais que o visibility timeout, o SQS torna a mensagem visível de novo e ela é entregue a outra thread/instância **em paralelo** — processamento duplicado. Dimensione com folga.

Factory para aplicar opções a todos os listeners (incluindo ack mode e visibility, que não têm propriedade):

```java
import io.awspring.cloud.sqs.config.SqsMessageListenerContainerFactory;
import io.awspring.cloud.sqs.listener.acknowledgement.handler.AcknowledgementMode;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;
import java.time.Duration;

@Bean
SqsMessageListenerContainerFactory<Object> defaultSqsListenerContainerFactory(
        SqsAsyncClient sqsAsyncClient) {
    return SqsMessageListenerContainerFactory.builder()
        .sqsAsyncClient(sqsAsyncClient)
        .configure(options -> options
            .acknowledgementMode(AcknowledgementMode.ON_SUCCESS)
            .maxConcurrentMessages(10)
            .maxMessagesPerPoll(10)
            .pollTimeout(Duration.ofSeconds(10))
            .messageVisibility(Duration.ofSeconds(30)))
        .build();
}
```

Para throughput/backpressure (`BackPressureMode`), blocking vs não-blocking e dimensionamento de threads, leia `references/container-tuning.md`.

---

## 7 — Jackson 3

O starter já registra um conversor (`SqsMessagingMessageConverter`) baseado no `ObjectMapper`/`JsonMapper` Jackson 3 gerenciado pelo Spring. **Records desserializam direto, sem configuração extra.** Só declare um conversor customizado se precisar mudar features ou registrar módulos:

```java
import tools.jackson.databind.json.JsonMapper;            // Jackson 3: pacote tools.jackson
import tools.jackson.databind.DeserializationFeature;
import io.awspring.cloud.sqs.support.converter.SqsMessagingMessageConverter;

@Bean
SqsMessagingMessageConverter sqsMessagingMessageConverter() {
    JsonMapper mapper = JsonMapper.builder()
        .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)  // tolera campos novos do produtor
        .build();
    // O JsonMapper (Jackson 3) é injetado pelo construtor — não há setObjectMapper.
    return new SqsMessagingMessageConverter(mapper);
}
```

> **Tolerância a campos desconhecidos** é uma boa prática em eventos: o produtor pode adicionar campos sem quebrar o consumidor.

---

## 8 — Exceção, reentrega e DLQ (resumo)

O comportamento padrão já implementa a estratégia correta — **não escreva retry nem publicação manual em DLQ**:

1. O listener lança exceção → a mensagem **não é confirmada**.
2. Após o `visibilityTimeout`, o SQS **reentrega** a mensagem.
3. Ao atingir o `maxReceiveCount` do *redrive policy*, o SQS move a mensagem para a **DLQ automaticamente**.

Pontos-chave (detalhes em `references/error-handling-and-dlq.md`):

- **DLQ e `maxReceiveCount` são infraestrutura da fila** (Terraform/CDK/Console), não código.
- **Retry de erros transitórios** (timeout de banco, indisponibilidade de serviço externo) é responsabilidade do **cliente externo** — use Resilience4j ou Spring Retry **no client**, não no listener. Se mesmo com retry falhar, deixe a exceção subir.
- **Cuidado com `ErrorHandler`:** se você registrar um e ele **não relançar**, o framework considera a mensagem "recuperada" e a **confirma** — isso impede reentrega e DLQ. Ver a referência.
- **Entrega at-least-once — avise e PARE:** o SQS garante entrega *pelo menos uma vez*, não exatamente uma vez. A mesma mensagem pode chegar mais de uma vez (reentrega, visibility expirado, redrive). **Informe isso ao usuário e encerre o assunto.** Não gere nenhum código de idempotência ou deduplicação — nenhuma tabela de dedup, Redis/SETNX, cache com TTL, lock, UPSERT, `processedRepository`, constraint UNIQUE ou qualquer padrão de dedup. Tratar duplicidade é responsabilidade da aplicação e está **totalmente fora do escopo desta skill**. Se o usuário insistir em pedir implementação, responda: "Isso está fora do escopo desta skill. Consulte padrões de idempotência para workers específicos da sua stack."

---

## 9 — Integração com logs (MDC via `MessageInterceptor`)

Use a skill `spring-java-log-standardization` para o padrão de logs (JSON, `MdcContext`, masking). Para popular o MDC em **todos** os listeners de forma centralizada — sem repetir `try/finally` em cada método — registre um `MessageInterceptor`:

```java
import io.awspring.cloud.sqs.listener.MessageInterceptor;
import org.springframework.messaging.Message;
import org.springframework.stereotype.Component;

@Component
public class MdcSqsInterceptor implements MessageInterceptor<Object> {

    @Override
    public Message<Object> intercept(Message<Object> message) {
        // correlationId chega como atributo da mensagem → header Spring de mesmo nome.
        String correlationId = message.getHeaders().get("correlationId", String.class);
        MdcContext.initEvent(correlationId, "sqs", "pedido-worker");
        return message;   // nunca retorne null
    }

    @Override
    public void afterProcessing(Message<Object> message, Throwable t) {
        // Roda após o listener (e o ErrorHandler), antes do ack: ponto certo para limpar.
        MdcContext.clear();
    }
}
```

> **Por que interceptor e não `try/finally` no listener:** centraliza a montagem/limpeza do MDC, mantém os listeners focados em negócio e cobre automaticamente novos listeners.
>
> **Limitação (thread-local):** o MDC é thread-local. Isso funciona para listeners **blocking** (o padrão — `intercept`, listener e `afterProcessing` rodam na mesma thread). Em listeners **não-blocking** (que retornam `CompletableFuture`), o trabalho pode mudar de thread e o MDC não se propaga — nesse caso, passe o `correlationId` explicitamente. Ver `references/container-tuning.md`.

---

## 10 — Mensagens originadas do SNS (@SnsNotificationMessage)

Quando uma fila SQS é subscrita em um tópico SNS **com *raw message delivery* OFF** (o padrão), o SQS recebe o payload envolvido num envelope SNS:

```json
{
  "Type": "Notification",
  "MessageId": "abc-123",
  "TopicArn": "arn:aws:sns:us-east-1:123456789012:pedidos",
  "Subject": "Novo pedido",
  "Message": "{\"pedidoId\":\"P-1\",\"clienteId\":\"C-9\",\"valorTotal\":199.90}",
  "Timestamp": "2024-01-01T00:00:00.000Z",
  "MessageAttributes": { ... }
}
```

Sem tratamento especial, `@SqsListener` receberia esse envelope inteiro como o payload — não o DTO do evento. As anotações abaixo resolvem isso sem código adicional.

> **Raw delivery ON → não use esta seção.** Se a subscrição SNS tiver *raw message delivery* ON, o SQS já recebe o payload bruto; use o listener normal da seção *3*.

> **Sem dependência extra.** Todas as classes abaixo (`@SnsNotificationMessage`, `@SnsNotificationSubject`, `SnsNotification<T>`) fazem parte do `spring-cloud-aws-starter-sqs` — nenhuma dependência adicional.

---

### 10.1 — Payload direto (`@SnsNotificationMessage`)

Extrai e desserializa automaticamente o campo `"Message"` do envelope SNS no tipo do parâmetro:

```java
import io.awspring.cloud.sqs.annotation.SnsNotificationMessage;

@SqsListener("${app.queues.pedidos}")
public void onPedidoCriado(@SnsNotificationMessage PedidoCriadoEvent event) {
    // 'event' já é o DTO desserializado de "Message" — sem envelope.
    log.info("Pedido criado", kv("pedidoId", event.pedidoId()));
}
```

---

### 10.2 — Com subject do SNS (`@SnsNotificationSubject`)

Quando o produtor SNS preenche o campo `"Subject"` e o consumidor precisa dele:

```java
import io.awspring.cloud.sqs.annotation.SnsNotificationMessage;
import io.awspring.cloud.sqs.annotation.SnsNotificationSubject;

@SqsListener("${app.queues.pedidos}")
public void onPedidoCriado(
        @SnsNotificationSubject String subject,
        @SnsNotificationMessage PedidoCriadoEvent event) {
    log.info("Evento SNS recebido",
        kv("subject", subject),
        kv("pedidoId", event.pedidoId()));
}
```

---

### 10.3 — Metadados completos do SNS (`SnsNotification<T>`)

Quando o listener precisa de `messageId`, `topicArn`, `subject` ou outros campos do envelope:

```java
import io.awspring.cloud.sqs.support.converter.SnsNotification;

@SqsListener("${app.queues.pedidos}")
public void onPedidoCriado(SnsNotification<PedidoCriadoEvent> notification) {
    notification.getSubject().ifPresent(s -> log.info("Subject SNS: {}", s));

    PedidoCriadoEvent event = notification.getMessage();
    log.info("Processando pedido",
        kv("pedidoId", event.pedidoId()),
        kv("topicArn", notification.getTopicArn()),
        kv("messageId", notification.getMessageId()));
}
```

---

### 10.4 — MDC / correlationId com mensagens SNS

Com *raw delivery* OFF, o `correlationId` enviado pelo produtor vai para `MessageAttributes` do SNS. O SNS propaga esses atributos como atributos de mensagem SQS **somente se a subscrição tiver a política de filtragem configurada para passá-los**. Se não forem propagados, `message.getHeaders().get("correlationId")` retorna `null` no `MdcSqsInterceptor` (seção *9*).

**Recomendação:** informe o usuário dessa dependência de configuração da subscrição SNS. Se o atributo chegar, o interceptor funciona sem alteração; se não chegar, o interceptor já gera um novo `correlationId` quando o valor é ausente — comportamento correto.

---

## Checklist de conformidade

- [ ] O modo de ack foi **escolhido com o usuário** (não assumido) e está coerente com a tolerância a perda.
- [ ] O `@SqsListener` desserializa **direto para record** — nenhum listener recebe `String` para desserializar à mão.
- [ ] DTOs de evento são `record`.
- [ ] Em múltiplos tipos, a **abordagem foi escolhida** (sealed interface por default) — ver referência.
- [ ] `visibilityTimeout` > tempo máximo de processamento.
- [ ] Nenhum código faz **retry próprio** nem **publica em DLQ** manualmente.
- [ ] Nenhum `catch` confirma a mensagem após falha (exceto modo `ALWAYS` consciente).
- [ ] MDC é populado via `MessageInterceptor` e limpo em `afterProcessing`.
- [ ] O usuário foi avisado sobre **entrega at-least-once** (idempotência é responsabilidade da aplicação) — **nenhum código de deduplicação foi gerado**.
- [ ] `maxReceiveCount` + DLQ documentados como **infraestrutura** da fila.
- [ ] Se a fila recebe mensagens de um tópico SNS com *raw delivery* OFF, usa `@SnsNotificationMessage` (ou `SnsNotification<T>`) — nunca recebe o envelope SNS como `String` para parsear à mão.
- [ ] O usuário foi informado sobre a dependência de configuração da subscrição SNS para propagação de `MessageAttributes` (correlationId).
- [ ] **Nenhum comentário desnecessário** no código gerado — sem Javadoc descritivo, sem comentários que explicam o *que* o código faz, sem referências à tarefa ou ao fix.
</content>
</invoke>
