# SNS Avançado — SnsTemplate e SnsOperations

## Message Attributes tipados

Os headers adicionados via `SnsNotification.builder(...).header(key, value)` são propagados como `MessageAttributes` do SNS. O SNS suporta três tipos de atributo: `String`, `Number` e `Binary`.

O Spring Cloud AWS serializa automaticamente valores `String` como tipo `String`. Para tipos `Number` (importante para filtros de subscrição baseados em atributos numéricos), declare o atributo explicitamente como `SnsMessageAttribute`:

```java
import io.awspring.cloud.sns.core.SnsNotification;
import io.awspring.cloud.sns.core.TopicMessageChannel;
import org.springframework.messaging.MessageHeaders;

// Usando MessageHeaders para atributos tipados:
Map<String, Object> headers = new HashMap<>();
headers.put("correlationId", MDC.get("correlationId"));         // String
headers.put("version", "1");                                     // String (não Number)
// Para Number no filtro SNS, use SnsHeaders ou atributo nativo via SnsAsyncClient

snsOperations.sendNotification(pedidosTopic,
    SnsNotification.builder(event)
        .headers(headers)
        .subject("PedidoCriado")
        .build());
```

> Para filtros de subscrição SNS baseados em atributos numéricos (ex.: filtrar por `valorTotal > 1000`), o atributo precisa ser do tipo `Number` no SNS. Isso requer o `SnsAsyncClient` de baixo nível, pois o `SnsTemplate` não expõe a API de tipo de atributo. Avalie se filtros numéricos são necessários antes de optar por publicação de baixo nível.

---

## Customização do ObjectMapper (SnsPublishMessageConverter)

O starter registra um `SnsPublishMessageConverter` automático baseado em Jackson 3. Para customizar — por exemplo, para registrar módulos ou mudar features de serialização — declare um bean `SnsPublishMessageConverter`:

```java
import io.awspring.cloud.sns.core.SnsTemplate;
import software.amazon.awssdk.services.sns.SnsClient;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.SerializationFeature;

@Bean
SnsTemplate snsTemplate(SnsClient snsClient) {
    JsonMapper mapper = JsonMapper.builder()
        .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)  // ISO-8601 para datas
        .build();

    // SnsTemplate aceita um MessageConverter no construtor
    return new SnsTemplate(snsClient,
        new SnsPublishMessageConverter(mapper));
}
```

> Se você declarar um bean `SnsTemplate` manualmente, o auto-configurado **não** é criado. Certifique-se de injetar todos os colaboradores necessários (ex.: `TopicArnResolver` se usar nomes lógicos em vez de ARNs).

---

## TopicArnResolver — Resolução de nome para ARN

O `SnsTemplate` aceita ARN completo ou nome lógico do tópico. Com nome lógico, o `TopicArnResolver` faz uma chamada à API SNS (`listTopics`) para encontrar o ARN — uma chamada extra por publicação na primeira vez (o resultado é cacheado).

Em produção, **prefira ARNs** para eliminar a chamada de resolução. Em desenvolvimento (LocalStack), o nome lógico é mais conveniente.

Para ambientes onde criação de tópicos não é permitida mas a listagem está disponível, use `TopicsListingTopicArnResolver`:

```java
import io.awspring.cloud.sns.core.TopicsListingTopicArnResolver;
import software.amazon.awssdk.services.sns.SnsClient;

@Bean
SnsTemplate snsTemplate(SnsClient snsClient) {
    return new SnsTemplate(snsClient,
        new TopicsListingTopicArnResolver(snsClient),
        null);   // messageConverter null = usa o padrão
}
```

---

## Envio de SMS

O starter SNS também suporta envio de SMS diretamente via `SmsMessageAttributes`:

```java
import io.awspring.cloud.sns.sms.SnsSmsTemplate;
import io.awspring.cloud.sns.sms.SmsMessageAttributes;
import io.awspring.cloud.sns.sms.SmsType;

@Component
public class SmsNotificationService {

    private final SnsSmsTemplate smsTemplate;

    public SmsNotificationService(SnsSmsTemplate smsTemplate) {
        this.smsTemplate = smsTemplate;
    }

    public void enviarSms(String numero, String mensagem) {
        smsTemplate.send(numero, mensagem,
            SmsMessageAttributes.builder()
                .smsType(SmsType.TRANSACTIONAL)   // TRANSACTIONAL ou PROMOTIONAL
                .senderID("MeuApp")
                .maxPrice("0.50")
                .build());
    }
}
```

> **`TRANSACTIONAL`** — alta confiabilidade, para alertas críticos (OTP, confirmação de pedido). **`PROMOTIONAL`** — menor custo, para marketing.

---

## Propagação de MessageAttributes via Subscrição SNS → SQS

Quando o tópico SNS entrega em uma fila SQS subscrita (fan-out), os `MessageAttributes` (incluindo `correlationId`) só chegam ao consumidor SQS se a **política de filtragem de atributos da subscrição** estiver configurada para passá-los.

Por padrão, sem política de filtragem, **todos os atributos são propagados**. Se houver uma política de filtragem, apenas os atributos listados passam.

Verifique a configuração da subscrição (Terraform/CDK/Console) se o `correlationId` não estiver chegando ao consumidor. A skill `spring-java-sqs-listener` (seção 10.4) detalha o comportamento do lado do consumidor.

---

## SnsHeaders — Constantes de header

O `io.awspring.cloud.sns.core.SnsHeaders` expõe constantes úteis:

```java
import io.awspring.cloud.sns.core.SnsHeaders;

// Header adicionado automaticamente pelo SnsTemplate nas mensagens enviadas:
// SnsHeaders.NOTIFICATION_SUBJECT_HEADER = "notificationSubject"
// SnsHeaders.MESSAGE_GROUP_ID_HEADER      = "messageGroupId"
// SnsHeaders.MESSAGE_DEDUPLICATION_ID_HEADER = "messageDeduplicationId"
```

Esses headers são gerenciados pelo framework — você não precisa defini-los manualmente quando usa `SnsNotification.builder()`.
