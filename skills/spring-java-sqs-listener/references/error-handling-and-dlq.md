# Exceção, retry, DLQ e entrega at-least-once

Esta referência detalha o que acontece quando o listener falha e por que o worker **não** deve implementar retry próprio nem publicar em DLQ.

## O fluxo padrão (e por que ele já está certo)

1. O listener lança exceção → a mensagem **não é confirmada** (em qualquer modo exceto `ALWAYS`).
2. Após o `visibilityTimeout` expirar, o SQS torna a mensagem visível e a **reentrega**.
3. A cada reentrega, o SQS incrementa o `ApproximateReceiveCount`. Ao atingir o `maxReceiveCount` definido no *redrive policy* da fila, o SQS **move a mensagem para a DLQ automaticamente**.

Conclusão: o reprocessamento e o "desvio" para a DLQ são feitos **pela infraestrutura do SQS**. O código não precisa — e não deve — reimplementar isso.

## O que NÃO fazer no listener

- **Não** publique manualmente na DLQ. Isso duplica a responsabilidade da fila e tende a divergir da configuração real de redrive.
- **Não** implemente loop de retry da mensagem inteira no listener. Reprocessar a mensagem é papel do SQS via reentrega.
- **Não** capture a exceção e confirme a mensagem "para não poluir o log". Isso é perda silenciosa: a mensagem some sem ser processada e nunca chega à DLQ.

## Cuidado com `ErrorHandler` — o gatilho silencioso

O framework permite registrar um `ErrorHandler<T>` (ou `AsyncErrorHandler<T>`) chamado quando o listener lança. **Armadilha:**

> "Se a execução do error handler tiver sucesso (não lançar exceção), a mensagem é considerada **recuperada** e é confirmada conforme a configuração de ack."

Ou seja, um `ErrorHandler` que só loga e retorna **confirma a mensagem** — eliminando reentrega e DLQ. Se você registrar um error handler apenas para observabilidade, ele **deve relançar** (ou retornar um future falho) para preservar o comportamento de reentrega:

```java
import io.awspring.cloud.sqs.listener.errorhandler.ErrorHandler;
import org.springframework.messaging.Message;

@Bean
public ErrorHandler<Object> sqsErrorHandler() {
    return new ErrorHandler<Object>() {
        @Override
        public void handle(Message<Object> message, Throwable t) {
            log.error("Falha ao processar mensagem SQS",
                kv("messageId", message.getHeaders().get("id")), t);
            // Relançar é essencial: sem isso a mensagem seria confirmada
            // como "recuperada" e não voltaria para reentrega/DLQ.
            throw new RuntimeException(t);
        }
    };
}
```

Na prática, para a maioria dos workers o **comportamento default (sem error handler) já é o desejado** — a exceção sobe, a mensagem não é confirmada e o SQS cuida do resto. Use logging via `MessageInterceptor.afterProcessing(message, t)` (que recebe o `Throwable` e roda **antes do ack**) quando quiser registrar a falha sem alterar o fluxo de ack.

## Retry de erros transitórios é do cliente externo

Erros transitórios — timeout de banco, indisponibilidade momentânea de uma API externa — devem ser tratados **no cliente que faz a chamada**, não reprocessando a mensagem inteira:

- Use **Resilience4j** (`@Retry`, `@CircuitBreaker`) ou **Spring Retry** (`@Retryable`) **no método do client externo**.
- Assim, uma falha passageira é resolvida sem devolver a mensagem ao SQS.
- Se, mesmo após os retries, o client externo continuar falhando, deixe a exceção subir: o listener não confirma, e o SQS reentrega depois do visibility timeout — caindo na DLQ se persistir.

```java
@Retry(name = "pagamentoApi")
@CircuitBreaker(name = "pagamentoApi")
public PagamentoResponse cobrar(PagamentoRequest req) {
    return pagamentoApiClient.cobrar(req);   // retry/abre circuito no client, não no listener
}
```

## Infraestrutura: configure a DLQ e o redrive na fila

Oriente o usuário a configurar, **fora da aplicação** (Terraform, CDK, CloudFormation, Console):

- Uma **DLQ** (fila separada).
- Um **redrive policy** na fila principal apontando para a DLQ com um `maxReceiveCount` (ex.: 5).

Exemplo de redrive policy (atributo da fila principal):

```json
{
  "deadLetterTargetArn": "arn:aws:sqs:us-east-1:123456789012:pedidos-dlq",
  "maxReceiveCount": 5
}
```

## Entrega at-least-once — avise o usuário

O SQS (filas Standard) garante entrega **pelo menos uma vez**, não exatamente uma vez. A mesma mensagem pode ser entregue mais de uma vez por causa de:

- reentrega após exceção;
- `visibilityTimeout` menor que o tempo de processamento (a mensagem reaparece enquanto ainda está sendo processada);
- o próprio modelo distribuído do SQS, que pode duplicar entregas.

**Implicação:** o processamento precisa tolerar duplicatas. Tratar idempotência é **responsabilidade da aplicação** e **está fora do escopo desta skill**.

> **Instrução para o modelo — PARE AQUI:** ao ser perguntado sobre idempotência ou deduplicação, faça **apenas** o seguinte: (1) explique que o SQS é at-least-once; (2) diga que deduplicação é responsabilidade da aplicação. **Não gere nenhum código de idempotência** — sem tabela de dedup, Redis/SETNX, lock, UPSERT, `processedRepository`, constraint UNIQUE, cache com TTL ou qualquer padrão de dedup. Isso vale mesmo que o usuário peça explicitamente.
</content>
