# Múltiplos tipos de evento na mesma fila

Quando uma fila entrega vários tipos de evento, o worker precisa desserializar e rotear cada mensagem para o tratamento certo. Há duas abordagens. **Confirme com o usuário antes de gerar; se ele não indicar, use a sealed interface.**

## Como decidir

| Critério | Sealed interface (default) | `@SqsHandler` |
|---|---|---|
| Onde fica o discriminador de tipo | No **payload** (`@JsonTypeInfo`) | Em um **header** da mensagem (tipo Java) |
| Acoplamento com o produtor | Baixo — só precisam concordar no nome lógico do tipo | Alto se usar o header `JavaType` (FQCN compartilhado) |
| Idiomático em Java 25 | Sim — `switch` com pattern matching exaustivo | Um método por tipo |
| Quando preferir | Default; produtor é seu ou você controla o contrato do payload | Já existe um header de tipo, ou você quer um método isolado por tipo |

---

## Abordagem 1 — Sealed interface (recomendada)

O tipo concreto é declarado **dentro do JSON** via Jackson. Não depende de o produtor enviar header de tipo.

```java
import com.fasterxml.jackson.annotation.JsonSubTypes;
import com.fasterxml.jackson.annotation.JsonTypeInfo;

// Discriminador no payload: campo "tipo" decide o record concreto.
@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, property = "tipo")
@JsonSubTypes({
    @JsonSubTypes.Type(value = PedidoCriado.class,   name = "PEDIDO_CRIADO"),
    @JsonSubTypes.Type(value = PedidoCancelado.class, name = "PEDIDO_CANCELADO"),
    @JsonSubTypes.Type(value = PedidoEnviado.class,   name = "PEDIDO_ENVIADO")
})
public sealed interface PedidoEvent
        permits PedidoCriado, PedidoCancelado, PedidoEnviado {
    String pedidoId();
}

public record PedidoCriado(String pedidoId, String clienteId, BigDecimal valor)
        implements PedidoEvent {}

public record PedidoCancelado(String pedidoId, String motivo)
        implements PedidoEvent {}

public record PedidoEnviado(String pedidoId, String rastreio)
        implements PedidoEvent {}
```

> **Nota Jackson:** `@JsonTypeInfo`/`@JsonSubTypes` são do pacote `com.fasterxml.jackson.annotation` — esse pacote de **anotações** permanece o mesmo no Jackson 3 (apenas `databind`/`core` migraram para `tools.jackson`).

Um único listener recebe a interface; o `switch` exaustivo garante, em tempo de compilação, que todos os tipos foram tratados:

```java
@SqsListener("${app.queues.pedidos}")
public void onPedidoEvent(PedidoEvent event) {
    switch (event) {
        case PedidoCriado e    -> pedidoService.criar(e);
        case PedidoCancelado e -> pedidoService.cancelar(e);
        case PedidoEnviado e   -> pedidoService.marcarEnviado(e);
    }
}
```

O payload na fila fica assim:

```json
{ "tipo": "PEDIDO_CRIADO", "pedidoId": "P-1", "clienteId": "C-9", "valor": 199.90 }
```

---

## Abordagem 2 — `@SqsHandler` (roteamento por tipo Java)

A classe é anotada com `@SqsListener` e cada método `@SqsHandler` trata um tipo de payload. O framework **roteia pelo tipo Java desserializado** — então ele precisa saber em qual classe desserializar **antes** de rotear. Isso vem de um header de tipo.

```java
import io.awspring.cloud.sqs.annotation.SqsListener;
import io.awspring.cloud.sqs.annotation.SqsHandler;

@SqsListener("${app.queues.pedidos}")
public class PedidoEventListener {

    @SqsHandler
    public void handle(PedidoCriado event)    { pedidoService.criar(event); }

    @SqsHandler
    public void handle(PedidoCancelado event) { pedidoService.cancelar(event); }

    @SqsHandler(isDefault = true)             // fallback p/ tipos não mapeados
    public void handleUnknown(Object event)   { log.warn("Evento não mapeado: {}", event); }
}
```

### Como o framework descobre o tipo: o header `JavaType`

Por padrão, o conversor lê o header cujo nome é `SqsHeaders.SQS_DEFAULT_TYPE_HEADER` (valor literal **`"JavaType"`**), espera o **nome totalmente qualificado da classe** e faz `Class.forName(...)`. Ou seja, o produtor precisa enviar um atributo de mensagem `JavaType = com.exemplo.PedidoCriado`.

Isso **acopla produtor e consumidor ao FQCN** (mesmo pacote/classe nos dois lados) — frágil entre serviços distintos.

### Desacoplando: `payloadTypeMapper` com header de domínio

Para usar um header de domínio estável (ex.: `eventType = PEDIDO_CRIADO`) em vez do FQCN, registre um conversor com um mapeamento explícito header → classe:

```java
import io.awspring.cloud.sqs.support.converter.SqsMessagingMessageConverter;

@Bean
SqsMessagingMessageConverter sqsMessagingMessageConverter() {
    SqsMessagingMessageConverter converter = new SqsMessagingMessageConverter();
    converter.setPayloadTypeMapper(message -> {
        String eventType = message.getHeaders().get("eventType", String.class);
        if (eventType == null) {
            return Object.class;   // cai no @SqsHandler(isDefault = true)
        }
        return switch (eventType) {
            case "PEDIDO_CRIADO"    -> PedidoCriado.class;
            case "PEDIDO_CANCELADO" -> PedidoCancelado.class;
            case "PEDIDO_ENVIADO"   -> PedidoEnviado.class;
            default                 -> Object.class;
        };
    });
    return converter;
}
```

Assim a mensagem só precisa do header de domínio `eventType` — sem expor nomes de classe.

---

## Recomendação prática

- Se você controla o produtor e o contrato do payload, prefira a **sealed interface**: discriminador no payload, `switch` exaustivo e zero configuração de conversor.
- Use `@SqsHandler` quando já houver um header de tipo na mensagem (legado/integração) ou quando isolar um método por tipo for desejável. Nesse caso, prefira o `payloadTypeMapper` com header de domínio em vez do header `JavaType` com FQCN.
</content>
