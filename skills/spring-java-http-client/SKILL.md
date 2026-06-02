---
name: spring-java-http-client
description: 'Use esta skill quando, num projeto Java + Spring Boot 4, o usuário precisar do LADO CLIENTE de uma integração HTTP: chamar, consumir ou integrar com a API REST de outro serviço (microserviço interno, downstream, API externa como CEP, pagamentos, notificações, catálogo). Inclui pedidos em linguagem simples como "adiciona um cliente http pro serviço X", "consumir o endpoint de Y", "BFF/agregador que orquestra chamadas a várias APIs internas", "começar um serviço que consome APIs", "organizar vários downstreams", além de menções a @HttpExchange, @ImportHttpServices, RestClient, spring.http.serviceclient, configurar base-url/timeout de um client, ou migrar @FeignClient/OpenFeign para o cliente nativo do Boot 4. NÃO acione para EXPOR endpoints próprios (@RestController/lado servidor), consumir filas SQS/mensageria, acesso a banco/JPA, Spring Security, ou clientes HTTP fora do ecossistema Spring/Java.'
---

# Cliente HTTP Declarativo — HTTP Interfaces · Spring Boot 4 · Java 25

Use esta skill para implementar **consumidores de APIs HTTP** com as **HTTP Interfaces nativas do Spring Boot 4** (`@HttpExchange` + `@ImportHttpServices`) — o sucessor oficial do Spring Cloud OpenFeign. O foco é o lado cliente: declarar a interface do contrato remoto, registrá-la como grupo, configurar por propriedades e tratar erros.

**Fora do escopo:** controllers/lado servidor (você está *expondo* a API, não consumindo), GraphQL, e o mergulho profundo em WebClient reativo (esta skill usa o adapter `RestClient` síncrono; veja a nota em `references/configuracao-e-transporte.md` se o stack for WebFlux).

## Stack definida

| Decisão | Escolha |
|---|---|
| Linguagem | Java 25 (records para DTOs) |
| Framework | Spring Boot 4.x (`spring-boot-starter-web`) |
| Estilo do client | HTTP Interface declarativa (`@HttpExchange`), registrada via `@ImportHttpServices` |
| Engine HTTP | `RestClient` síncrono sobre o **JDK `HttpClient` nativo** (default do Boot 4) |
| Configuração | **Nativa por propriedades** — `spring.http.serviceclient.<grupo>.*` + `spring.http.clients.*` |
| Erros | Exceções nativas do `RestClient` (sem classes custom) |
| Resiliência | Resilience4J opcional (`@Retry`/`@CircuitBreaker`) — política fina fica na skill de Resilience4J |
| Build | Maven |
| Logs | Skill `spring-java-log-standardization` (MDC via interceptor) |

## Como usar esta skill

1. **Passo 0 — pergunte antes de gerar** (base-url, endpoints, DTOs, auth, resiliência). Não assuma.
2. Gere, por cliente: a interface `@HttpExchange`, os DTOs (records), o registro `@ImportHttpServices` e o bloco de propriedades. Adicione um group configurer **só se** precisar de interceptor.
3. Para tópicos mais profundos, leia o arquivo de referência adequado:

| Quando | Leia |
|---|---|
| Lista completa das propriedades `spring.http.*`, escolha do **engine de transporte** (JDK nativo × Apache HttpComponents 5), prós/contras, organização do yaml, múltiplos proxies do mesmo tipo, nota sobre WebClient reativo | `references/configuracao-e-transporte.md` |
| Hierarquia de exceções nativas, quando criar um `defaultStatusHandler` (ex.: `ProblemDetail`), e a **configuração completa de Resilience4J** mapeada nas exceções nativas (retry/circuit breaker, fallback, idempotência) | `references/erros-e-resiliencia.md` |

---

## Passo 0 — Perguntar antes de gerar

Antes de escrever qualquer código, confirme com o usuário (em contexto automático sem resposta, use os defaults indicados):

1. **Nome do grupo/cliente** e **base-url** do serviço remoto. O nome do grupo é a chave que amarra tudo (veja o quadro abaixo).
2. **Endpoints**: método HTTP, path, parâmetros (path/query/body) e tipo de retorno de cada operação.
3. **DTOs**: o payload de request/response — sempre `record`.
4. **Autenticação / headers dinâmicos?** (ex.: `Authorization: Bearer`, propagação de `correlationId`). Se sim → group configurer com `requestInterceptor` (seção 4). Se não, pule.
5. **Resiliência (Resilience4J)?** (default recomendado: **sim**, no formato do POC). Confirme — a *política* fina (tentativas, janelas) será refinada depois pela skill dedicada de Resilience4J.

> **O nome do grupo amarra 3 pontos — mantenha idêntico nos três:**
> 1. `@ImportHttpServices(group = "github", ...)`
> 2. `spring.http.serviceclient.github.*` (propriedades)
> 3. `groups.filterByName("github")` (no group configurer, se houver)
>
> Use o mesmo nome também na instância do Resilience4J (`@Retry(name = "github")`) para rastreabilidade.

---

## Arquitetura — um pacote por cliente (Open-Closed)

Cada cliente é um **pacote autocontido**. Adicionar um novo cliente = **criar arquivos novos**, sem tocar em config compartilhada — só um bloco a mais no `application.yml`. Esse é o ganho central de SOLID aqui (OCP): nada de uma `HttpClientConfig` central que cresce e vira ponto de conflito.

```
com.example.<app>
├── Application.java
└── client
    ├── github
    │   ├── GithubClient.java          // interface @HttpExchange (o contrato)
    │   ├── GithubClientConfig.java     // @ImportHttpServices (+ configurer só se precisar)
    │   ├── GithubService.java          // wrapper Resilience4J (opcional)
    │   └── dto/
    │       └── Repository.java         // records
    └── billing
        └── ...                         // novo cliente = novo pacote, zero edição no github
```

> **Por que não centralizar o registro?** `@ImportHttpServices` é repetível e poderia listar todos os clientes em uma classe só. Evite: isso recria o acoplamento que a OCP combate. Um `@Configuration` por cliente mantém cada contrato isolado e testável.

---

## 1 — Dependências Maven

```xml
<dependencies>
    <!-- Lado servidor (Web MVC + Tomcat). A interface RestClient vive no spring-web,
         mas o starter-web sozinho NÃO traz o autoconfig de cliente HTTP (veja abaixo). -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>

    <!-- OBRIGATÓRIO para a config nativa funcionar. Fornece o autoconfig que LIGA
         spring.http.serviceclient.* / spring.http.clients.* aos grupos @ImportHttpServices
         (HttpServiceClientAutoConfiguration + HttpServiceClientPropertiesAutoConfiguration)
         e aplica base-url/timeouts/default-header ao RestClient de cada grupo.
         Puxa spring-boot-http-client transitivamente. Engine default: JDK HttpClient nativo. -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-restclient</artifactId>
    </dependency>

    <!-- Resiliência (opcional). A POLÍTICA detalhada pertence à skill de Resilience4J. -->
    <dependency>
        <groupId>io.github.resilience4j</groupId>
        <artifactId>resilience4j-spring-boot4</artifactId>
        <version>2.4.0</version>
    </dependency>
    <!-- AOP: sem ele as anotações @Retry/@CircuitBreaker silenciosamente não fazem nada.
         Renomeado de spring-boot-starter-aop no Boot 4. -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-aspectj</artifactId>
    </dependency>
    <!-- Expõe /actuator/circuitbreakers para inspecionar o estado do breaker. -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
</dependencies>
```

> **`spring-boot-restclient` não é opcional — é o que faz a config nativa existir.** No Boot 4 modularizado, o autoconfig de cliente HTTP saiu do `spring-boot-autoconfigure`; o `spring-boot-starter-web` é só lado servidor (Web MVC + Tomcat) e **não** o inclui. Sem essa dependência, o app sobe normalmente, o proxy do `@ImportHttpServices` é até criado, mas **`spring.http.serviceclient.*` é silenciosamente ignorado** — base-url e timeouts não são aplicados e a chamada falha por host ausente. *(Verificado em runtime no Boot 4.0.0: com a dependência, `base-url` e `default-header` são realmente aplicados; sem ela, as propriedades não bindam.)*
>
> Sem Resilience4J? Remova os três últimos. O cliente HTTP precisa de `spring-boot-starter-web` **e** `spring-boot-restclient`.

---

## 2 — A interface `@HttpExchange` (o contrato)

Declare o contrato remoto como uma interface. Atributos comuns (path base, `accept`) vão no nível do tipo; cada método mapeia um endpoint. **Nunca** coloque a base-url aqui — ela vem das propriedades (seção 3).

```java
package com.example.client.github;

import com.example.client.github.dto.Repository;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.service.annotation.GetExchange;
import org.springframework.web.service.annotation.HttpExchange;
import org.springframework.web.service.annotation.PostExchange;

@HttpExchange(accept = "application/vnd.github+json")
public interface GithubClient {

    @GetExchange("/repos/{owner}/{repo}")
    Repository getRepository(@PathVariable String owner, @PathVariable String repo);

    @PostExchange(value = "/repos/{owner}/{repo}/issues",
                  contentType = MediaType.APPLICATION_JSON_VALUE)
    Repository createIssue(@PathVariable String owner, @PathVariable String repo,
                           @RequestBody NewIssue issue);
}
```

```java
// DTOs sempre como record — imutável, conciso, desserializa direto no Jackson.
public record Repository(Long id, String name, String fullName, boolean isPrivate) {}
public record NewIssue(String title, String body) {}
```

**Parâmetros suportados** (de `org.springframework.web.bind.annotation`): `@PathVariable`, `@RequestParam`, `@RequestBody`, `@RequestHeader`, `@CookieValue`, `@RequestPart`/`MultipartFile`. **Retornos** (RestClient): `void`, `<T>`, `HttpHeaders`, `ResponseEntity<Void>`, `ResponseEntity<T>`. Use `ResponseEntity<T>` quando precisar do status/headers além do corpo.

---

## 3 — Registro com `@ImportHttpServices`

Uma classe `@Configuration` por cliente, só com a anotação de registro. O proxy passa a ser **injetável por tipo** (`GithubClient`) em qualquer bean.

```java
package com.example.client.github;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.service.registry.ImportHttpServices;

@Configuration
@ImportHttpServices(group = "github", types = GithubClient.class)
public class GithubClientConfig {
    // Vazio de propósito: base-url/timeouts vêm do application.yml (seção 4).
    // Adicione um @Bean group configurer SÓ se precisar de interceptor (seção 5).
}
```

> Para registrar todas as interfaces de um pacote automaticamente, use `basePackageClasses = GithubClient.class` em vez de `types`.

---

## 4 — Configuração nativa por propriedades (o "feign.client.config" do Boot 4)

Aqui está o ponto-chave: **o Boot 4 já oferece configuração por propriedades equivalente ao Feign** — não crie `@ConfigurationProperties` nem helpers de request factory na mão.

- `spring.http.clients.*` → **defaults compartilhados** por todos os clientes.
- `spring.http.serviceclient.<grupo>.*` → **overrides por cliente**, keados pelo nome do grupo.

Um bloco por cliente, todos no `application.yml`:

```yaml
spring:
  http:
    clients:                         # defaults aplicados a todos os clientes
      connect-timeout: 2s
      read-timeout: 5s
    serviceclient:
      github:                        # == @ImportHttpServices(group="github")
        base-url: https://api.github.com
        read-timeout: 10s            # override só onde o downstream é mais lento
      billing:
        base-url: https://billing.internal
        # sem override → herda connect-timeout 2s / read-timeout 5s dos defaults
```

Propriedades por grupo incluem `base-url`, `connect-timeout`, `read-timeout`, `default-header` (singular), versionamento de API, redirects e SSL bundles. A lista completa está em `references/configuracao-e-transporte.md`.

> **Por que isso, e não `@ConfigurationProperties` por cliente?** Porque seria reinventar a roda. O Boot 4 liga essas propriedades ao grupo automaticamente — menos código, menos superfície de bug, e timeouts ajustáveis por ambiente sem recompilar (exatamente o que você tinha no Feign).

---

## 5 — Group configurer — só para o que propriedade não expressa

Headers **dinâmicos** (token de auth, `correlationId`) ou um engine de transporte específico não cabem em propriedade. Para isso, e só isso, declare um `RestClientHttpServiceGroupConfigurer` no `@Configuration` do cliente, filtrando pelo nome do grupo:

```java
@Configuration
@ImportHttpServices(group = "github", types = GithubClient.class)
public class GithubClientConfig {

    @Bean
    RestClientHttpServiceGroupConfigurer githubGroupConfigurer() {
        return groups -> groups.filterByName("github").forEachClient((group, client) ->
                client.requestInterceptor((request, body, execution) -> {
                    request.getHeaders().setBearerAuth(tokenProvider.current());
                    request.getHeaders().set("X-Correlation-Id", MdcContext.correlationId());
                    return execution.execute(request, body);
                }));
    }
}
```

> Cada cliente tem seu próprio configurer, com seu próprio `filterByName` — o Boot agrega todos os beans `RestClientHttpServiceGroupConfigurer`. Por isso adicionar um cliente novo não toca nos existentes. Headers **estáticos** podem ir direto em `spring.http.serviceclient.<grupo>.default-header.<Nome>` no yaml (a chave é `default-header`, **singular** — é um `Map<String, List<String>>`).

---

## 6 — Tratamento de erro: use as exceções nativas (sem classes custom)

O `RestClient` **já lança uma hierarquia bem definida** — não crie `RetryableException`/`NonRetryableException`. O par 4xx/5xx já está modelado em subtipos distintos, o que é tudo o que a resiliência precisa.

| O que aconteceu | Exceção lançada (`org.springframework.web.client`) | Retentar? | Conta p/ circuit breaker? |
|---|---|---|---|
| Resposta 5xx | `HttpServerErrorException` | ✅ | ✅ |
| Timeout de conexão/leitura, I/O | `ResourceAccessException` | ✅ (só se idempotente) | ✅ |
| Resposta 4xx | `HttpClientErrorException` | ❌ | ❌ |
| Erro de desserialização do corpo | `RestClientException` | ❌ | ❌ |

> **A única armadilha:** nunca configure retry/record na **base** `RestClientException` — isso retentaria 4xx e erros de decode, que são determinísticos (um 400 será 400 de novo) e às vezes perigosos. Sempre liste os **subtipos** específicos. O mapeamento exato em Resilience4J está em `references/erros-e-resiliencia.md`.

Crie um `defaultStatusHandler` **apenas** se um downstream específico devolve um corpo `ProblemDetail` (RFC 7807) que você quer parsear — caso por caso, não por padrão (YAGNI). Veja a referência.

---

## 7 — Resiliência com Resilience4J (resumo)

Envolva o client num service com `@Retry` + `@CircuitBreaker`, keados nas **exceções nativas**. A *política* (tentativas, janela, espera) será detalhada pela skill de Resilience4J; aqui geramos a estrutura no formato do POC.

```java
@Service
public class GithubService {

    private final GithubClient client;

    public GithubService(GithubClient client) {
        this.client = client;
    }

    @Retry(name = "github")
    @CircuitBreaker(name = "github", fallbackMethod = "getRepositoryFallback")
    public Repository getRepository(String owner, String repo) {
        return client.getRepository(owner, repo);
    }

    // Assinatura = mesmos args + Throwable. Pega 5xx/timeout/breaker aberto;
    // 4xx (ignore-exceptions) NÃO cai aqui e propaga para o chamador.
    private Repository getRepositoryFallback(String owner, String repo, Throwable t) {
        return Repository.unavailable(owner, repo); // resposta degradada
    }
}
```

A config `resilience4j.*` (com `retry-exceptions`/`ignore-exceptions`/`record-exceptions` apontando para as exceções nativas) está completa em `references/erros-e-resiliencia.md`.

---

## Checklist de conformidade

- [ ] **`spring-boot-restclient` está nas dependências** — sem ele a config nativa (`spring.http.serviceclient.*`) é silenciosamente ignorada; `spring-boot-starter-web` sozinho não basta.
- [ ] **Passo 0 feito com o usuário** — base-url, endpoints, DTOs, auth e resiliência confirmados (não assumidos).
- [ ] Um **pacote por cliente**; adicionar cliente novo **não edita** config existente (OCP).
- [ ] Interface `@HttpExchange` declara o contrato; **base-url NÃO está no código** — vem de `spring.http.serviceclient.<grupo>.base-url`.
- [ ] O **nome do grupo é idêntico** em `@ImportHttpServices(group)`, `spring.http.serviceclient.<grupo>` e (se houver) `filterByName`.
- [ ] DTOs são `record`.
- [ ] **Nenhum** `@ConfigurationProperties` custom nem helper de request factory — config é nativa por propriedades.
- [ ] `spring.http.clients.*` define defaults; overrides por cliente só onde necessário.
- [ ] Group configurer existe **só** quando há header dinâmico/auth ou troca de transporte — não como boilerplate vazio.
- [ ] **Sem exceções custom** (`Retryable`/`NonRetryable`): resiliência keada em `HttpServerErrorException`/`ResourceAccessException` (retry/record) e `HttpClientErrorException` (ignore).
- [ ] Resilience4J nunca lista a base `RestClientException` em retry/record.
- [ ] Wrapper de resiliência gerado no formato do POC, com nota de que a **política fina é da skill de Resilience4J**.
