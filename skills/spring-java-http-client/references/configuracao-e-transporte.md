# Configuração nativa e transporte

Aprofundamento da seção 4 do `SKILL.md`. Cobre o conjunto completo de propriedades `spring.http.*`, a escolha do engine de transporte e casos menos comuns.

## Sumário

1. [Propriedades `spring.http.serviceclient.<grupo>.*` (por cliente)](#1-propriedades-por-cliente)
2. [Propriedades `spring.http.clients.*` (defaults compartilhados)](#2-defaults-compartilhados)
3. [Engine de transporte: JDK nativo × Apache HttpComponents](#3-engine-de-transporte)
4. [Organização do yaml](#4-organização-do-yaml)
5. [Múltiplos proxies do mesmo tipo](#5-múltiplos-proxies-do-mesmo-tipo)
6. [Nota: WebClient (reativo) em vez de RestClient](#6-webclient-reativo)

---

## 1. Propriedades por cliente

Prefixo: `spring.http.serviceclient.<grupo>` — onde `<grupo>` é o nome em `@ImportHttpServices(group = "...")`. Bind para `Map<String, HttpClientProperties>` (módulo `spring-boot-http-client`).

```yaml
spring:
  http:
    serviceclient:
      github:
        base-url: https://api.github.com
        connect-timeout: 2s
        read-timeout: 10s
        default-header:                 # SINGULAR — Map<String, List<String>>
          X-App-Name: my-service        # headers ESTÁTICOS (token dinâmico → interceptor)
        # versionamento de API, redirects e ssl-bundle também são suportados por grupo
```

Campos suportados por grupo (lidos da classe `HttpClientProperties` do Boot 4.0): `base-url`, `connect-timeout`, `read-timeout`, `default-header` (**singular**, não `default-headers`), `apiversion`, `redirects` e `ssl.bundle`.

> **Pré-requisito:** essas propriedades só bindam se a dependência **`spring-boot-restclient`** estiver no projeto (ela fornece o autoconfig `HttpServiceClientPropertiesAutoConfiguration` e puxa `spring-boot-http-client`). O `spring-boot-starter-web` sozinho **não** traz isso — sem a dependência, todo este bloco é silenciosamente ignorado. Veja a seção 1 do `SKILL.md`.
>
> Headers que dependem de valor em runtime (Bearer token, `correlationId`) **não** vão aqui — use `requestInterceptor` no group configurer (seção 5 do `SKILL.md`). `default-header` é só para valores fixos.

## 2. Defaults compartilhados

Prefixo: `spring.http.clients` — aplica-se a todos os clientes; cada grupo sobrescreve o que precisar.

```yaml
spring:
  http:
    clients:
      connect-timeout: 2s
      read-timeout: 5s
      redirects: dont-follow
```

Padrão recomendado: defina `connect-timeout`/`read-timeout` conservadores em `clients`, e só suba o `read-timeout` no `serviceclient.<grupo>` do downstream comprovadamente mais lento. Assim um único serviço lento não impõe o pior caso a todos (bulkhead de timeout).

## 3. Engine de transporte

O `RestClient` do Boot 4 roda, por default, sobre o **JDK `HttpClient` nativo** — sem dependência extra. Troca-se o engine por **propriedade**, não por código:

```yaml
spring:
  http:
    clients:
      imperative:
        factory: jdk        # jdk (default) | http-components | jetty
```

> Prefira selecionar o engine pela propriedade `spring.http.clients.imperative.factory` (acima) em vez de montar um `ClientHttpRequestFactory` na mão — é mais simples e consistente, e mantém timeouts/redirects/SSL vindos das propriedades. Se realmente precisar de um engine específico por cliente, faça-o dentro do group configurer daquele grupo (`forEachClient(... client.requestFactory(...))`), adicionando a dependência do engine (ex.: `httpclient5`).

### JDK nativo × Apache HttpComponents 5 — quando trocar

| | **JDK `HttpClient`** (default) | **Apache HttpComponents 5** |
|---|---|---|
| Como obter | nada — já é o default | adicionar `org.apache.httpcomponents.client5:httpclient5` + `factory: http-components` |
| Prós | zero dependência; HTTP/2; menos superfície de CVE para gerenciar | pool de conexões rico (limites por rota, eviction, validate-on-borrow), métricas maduras, workhorse de alta carga |
| Contras | tuning de pool limitado | dependência extra e seu próprio ciclo de CVEs |

**Regra:** fique no JDK nativo para a maioria dos serviços (carga moderada, dependências enxutas). Migre para Apache quando houver **necessidade medida** — um cliente de alta vazão batendo num downstream onde você precisa controlar pool/keep-alive/limites por rota. A troca é só dependência + propriedade; as interfaces e o código não mudam.

## 4. Organização do yaml

Decisão tomada nesta skill: **um bloco por cliente, todos sob `spring.http.serviceclient` no `application.yml`**. Mantém os clientes visivelmente separados sem espalhar arquivos.

```yaml
spring:
  http:
    serviceclient:
      github:  { base-url: https://api.github.com, read-timeout: 10s }
      billing: { base-url: https://billing.internal }
      catalog: { base-url: https://catalog.internal }
```

Se o projeto preferir um arquivo por cliente, é possível usar `spring.config.import: clients/github.yml` — mas o default desta skill é o bloco único acima.

## 5. Múltiplos proxies do mesmo tipo

Injeção por tipo (`@Autowired GithubClient`) atende o caso comum (um proxy por tipo). Se você precisar do **mesmo tipo de interface apontando para dois grupos** (ex.: mesma API em duas regiões), injete via registry:

```java
public EchoController(HttpServiceProxyRegistry registry) {
    this.usEast = registry.getClient("echo-us-east", EchoService.class);
    this.euWest = registry.getClient("echo-eu-west", EchoService.class);
}
```

## 6. WebClient (reativo)

Esta skill usa o adapter `RestClient` (síncrono) — a escolha certa para a maioria dos serviços, ainda mais com **virtual threads** no Java 25 (`spring.threads.virtual.enabled=true`), onde código bloqueante escala como assíncrono.

Troque para o adapter **WebClient** só se o stack for WebFlux ponta a ponta, ou se houver streaming real (SSE, `Flux<T>`). Nesse caso:
- as interfaces podem retornar `Mono<T>`/`Flux<T>`;
- o configurer vira `WebClientHttpServiceGroupConfigurer`;
- **atenção:** a resiliência passa para a cadeia reativa (operadores Reactor / Resilience4J reativo) — as anotações AOP `@Retry`/`@CircuitBreaker` da seção 7 **não** compõem com retornos reativos.
