# Erros e resiliência

Aprofundamento das seções 6 e 7 do `SKILL.md`. Cobre a hierarquia de exceções nativas, quando enriquecer com um `defaultStatusHandler`, e a configuração completa de Resilience4J mapeada nessas exceções.

## Sumário

1. [Hierarquia de exceções do RestClient](#1-hierarquia-de-exceções)
2. [Quando criar um `defaultStatusHandler`](#2-quando-criar-um-defaultstatushandler)
3. [Configuração Resilience4J completa](#3-configuração-resilience4j)
4. [Padrão de fallback](#4-padrão-de-fallback)
5. [Idempotência e ordem dos aspectos](#5-idempotência-e-ordem)
6. [Fronteira com a skill de Resilience4J](#6-fronteira)

---

## 1. Hierarquia de exceções

`RestClient` lança, por default, sob `org.springframework.web.client`:

```
RestClientException                       (base — NÃO use em retry/record)
├── RestClientResponseException
│   ├── HttpClientErrorException          4xx  → não retentar, não contar no breaker
│   └── HttpServerErrorException          5xx  → retentar, contar no breaker
└── ResourceAccessException               timeout / I/O → retentar (se idempotente), contar
```

Erros de desserialização do corpo chegam como `RestClientException` (subtipos de conversão) — determinísticos, **não** retentáveis.

**Por que não precisamos de exceções custom:** o par 4xx/5xx já está em subtipos distintos. Decidir o que é retentável é responsabilidade da camada de resiliência (seção 3), não do client. Inventar `RetryableException`/`NonRetryableException` apenas acopla uma decisão de política dentro do transporte.

## 2. Quando criar um `defaultStatusHandler`

Por padrão, **não crie** — as exceções nativas bastam. Crie um handler só quando um downstream específico devolve um corpo de erro estruturado (`ProblemDetail` / RFC 7807) que você quer parsear, ou quando quer anexar contexto (nome do cliente). Faça-o no group configurer daquele grupo:

```java
@Bean
RestClientHttpServiceGroupConfigurer githubGroupConfigurer() {
    return groups -> groups.filterByName("github").forEachClient((group, client) ->
            client.defaultStatusHandler(HttpStatusCode::isError, (req, res) -> {
                // parse do ProblemDetail do corpo, log, ou enriquecimento —
                // continue lançando um subtipo compatível para a resiliência funcionar.
            }));
}
```

> Não troque a exceção por uma custom genérica aqui: se você "achatar" 4xx e 5xx no mesmo tipo, perde a distinção que o Resilience4J usa para decidir retry/record.

## 3. Configuração Resilience4J

Keada **diretamente nas exceções nativas**. Instância com o mesmo nome do grupo (`github`).

```yaml
resilience4j:
  retry:
    instances:
      github:
        max-attempts: 3
        wait-duration: 500ms
        retry-exceptions:
          - org.springframework.web.client.HttpServerErrorException   # 5xx
          - org.springframework.web.client.ResourceAccessException     # timeout/IO
        ignore-exceptions:
          - org.springframework.web.client.HttpClientErrorException    # 4xx: não adianta retentar
  circuitbreaker:
    instances:
      github:
        sliding-window-type: COUNT_BASED
        sliding-window-size: 20
        minimum-number-of-calls: 5
        failure-rate-threshold: 50
        wait-duration-in-open-state: 10s
        permitted-number-of-calls-in-half-open-state: 3
        record-exceptions:
          - org.springframework.web.client.HttpServerErrorException
          - org.springframework.web.client.ResourceAccessException
        ignore-exceptions:
          - org.springframework.web.client.HttpClientErrorException    # um 404 não é o downstream doente
```

Dois pontos que costumam passar batido:

- **`ignore-exceptions` no breaker para 4xx é essencial.** Uma enxurrada de 404 (tráfego normal de "não encontrado") não deve abrir o circuito — só falha real do downstream (5xx/timeout) conta.
- **Nunca liste `RestClientException` (a base)** em `retry-`/`record-exceptions`: ela englobaria 4xx e erros de decode.

Actuator para inspecionar:

```yaml
management:
  endpoints.web.exposure.include: health,circuitbreakers,retries
  endpoint.health.show-details: always
```

## 4. Padrão de fallback

A assinatura do método de fallback = **mesmos parâmetros + um `Throwable`** ao final. Ele captura o que **não** está em `ignore-exceptions` (5xx, timeout) e também `CallNotPermittedException` quando o breaker está aberto. Os 4xx, por estarem ignorados, **propagam** para o chamador — que é o correto (um 404 deve virar 404, não resposta degradada).

```java
private Repository getRepositoryFallback(String owner, String repo, Throwable t) {
    // t ∈ { HttpServerErrorException, ResourceAccessException, CallNotPermittedException }
    log.warn("github indisponível, retornando degradado", kv("owner", owner), kv("repo", repo));
    return Repository.unavailable(owner, repo);
}
```

## 5. Idempotência e ordem

- **Retry de `ResourceAccessException` (timeout) só é seguro para métodos idempotentes** (GET/PUT/DELETE). Para POST não-idempotente, retentar pode duplicar efeito — restrinja a política de retry desses métodos. Essa é uma decisão de política: detalhe-a com a skill de Resilience4J.
- **Ordem dos aspectos (default Resilience4J):** `Retry( CircuitBreaker( chamada ) )` — o retry envolve o breaker, então cada tentativa passa pelo circuito. Geralmente é o que se quer; ajuste fino fica para a skill dedicada.

## 6. Fronteira

Esta skill gera a **estrutura** (deps, wrapper, mapeamento nas exceções nativas, fallback). A **política fina** — número de tentativas, backoff exponencial, tamanho/tipo de janela, thresholds, time limiter, bulkhead, retry por método idempotente — pertence à **skill de Resilience4J**. Ao terminar, avise o usuário que esses valores são pontos de partida a serem calibrados lá.
