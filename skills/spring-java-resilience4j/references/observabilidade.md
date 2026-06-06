# Observabilidade — métricas Micrometer e endpoints do Actuator

Aprofundamento da seção 1, 3 e 4 do `SKILL.md`. Cobre **quais métricas** o Resilience4J publica via Micrometer, **como expô-las** (Actuator/Prometheus) e **o que vale alarmar**.

## Sumário

1. [Como o binding acontece](#1-binding)
2. [Métricas do Circuit Breaker](#2-métricas-do-circuit-breaker)
3. [Métricas do Retry](#3-métricas-do-retry)
4. [Endpoints do Actuator](#4-endpoints-do-actuator)
5. [Scrape Prometheus e o que alarmar](#5-prometheus)
6. [Correlação log ↔ métrica](#6-correlação)

---

## 1. Binding

O starter `resilience4j-spring-boot4` depende transitivamente de `resilience4j-micrometer`. Quando há um `MeterRegistry` no contexto (o Actuator fornece um), o binding é **automático**: cada instância de `CircuitBreaker`/`Retry` registrada vira uma série de métricas, **sem nenhum código**. É por isso que o `spring-boot-starter-actuator` é obrigatório nesta skill — ele é o que materializa o requisito "métricas expostas via Micrometer".

Todas as métricas carregam a tag `name="<instância>"` (ex.: `name="paymentGateway"`). É essa tag que liga a métrica à anotação, ao yaml e ao `kv("instance", ...)` do log.

## 2. Métricas do Circuit Breaker

| Métrica | Tipo | Tags | O que diz |
|---|---|---|---|
| `resilience4j.circuitbreaker.state` | gauge | `name`, `state` | 1 no estado atual, 0 nos demais. Série por estado (`closed`/`open`/`half_open`/...). |
| `resilience4j.circuitbreaker.calls` | timer/contador | `name`, `kind` | Chamadas por desfecho: `kind=successful` / `failed` / `not_permitted` (rejeitadas com o breaker aberto). |
| `resilience4j.circuitbreaker.failure.rate` | gauge | `name` | % de falhas na janela atual (−1 antes do `minimum-number-of-calls`). |
| `resilience4j.circuitbreaker.slow.call.rate` | gauge | `name` | % de chamadas lentas (acima do `slow-call-duration-threshold`). |
| `resilience4j.circuitbreaker.buffered.calls` | gauge | `name`, `kind` | Chamadas na janela deslizante. |

**Leitura operacional:** `state{state="open"}=1` é o sinal de incidente. `not_permitted > 0` quantifica o tráfego que o breaker está barrando — útil para dimensionar impacto. `failure.rate` cruzando o `failure-rate-threshold` antecede a abertura.

## 3. Métricas do Retry

| Métrica | Tipo | Tags | O que diz |
|---|---|---|---|
| `resilience4j.retry.calls` | contador | `name`, `kind` | Desfecho por categoria: `successful_without_retry`, `successful_with_retry`, `failed_without_retry`, `failed_with_retry`. |

**Leitura operacional:** `successful_with_retry` subindo = o downstream está instável mas o retry está salvando as chamadas (degradação silenciosa — vale investigar antes de virar incidente). `failed_with_retry` subindo = retry não está adiantando; provavelmente é hora do breaker agir. A razão `failed_with_retry / (successful_with_retry + failed_with_retry)` é um bom indicador de eficácia do retry.

## 4. Endpoints do Actuator

Expostos pelo `include` do `application.yml`:

| Endpoint | Conteúdo |
|---|---|
| `/actuator/circuitbreakers` | Estado atual de cada breaker. |
| `/actuator/circuitbreakerevents` | Buffer dos últimos eventos (transições, chamadas) — ótimo para depurar "por que abriu?". |
| `/actuator/retries` | Configuração/estado dos retries. |
| `/actuator/retryevents` | Buffer dos últimos eventos de retry. |
| `/actuator/health` | Com `management.health.circuitbreakers.enabled: true`, o estado do breaker entra no health (um breaker `OPEN` pode degradar o health — útil, mas cuidado para não derrubar o readiness probe por um downstream secundário; ver nota abaixo). |
| `/actuator/metrics` | Lista e detalha as métricas das seções 2–3. |
| `/actuator/prometheus` | Formato de scrape (requer `micrometer-registry-prometheus`). |

> **Health × readiness:** por padrão um breaker `OPEN` deixa o health `DOWN`. Se esse downstream **não** é essencial para a aplicação servir, isso pode reprovar o readiness probe e tirar o pod de rotação indevidamente. Nesse caso, mapeie o health indicator do breaker para **fora** do grupo `readiness`, ou desabilite-o para aquela instância. Para um downstream crítico, o comportamento default é o desejado.

## 5. Prometheus

Exemplo de scrape (`prometheus.yml`):

```yaml
scrape_configs:
  - job_name: 'minha-app'
    metrics_path: /actuator/prometheus
    static_configs:
      - targets: ['minha-app:8080']
```

Alarmes que valem a pena (PromQL):

```promql
# Breaker aberto agora
resilience4j_circuitbreaker_state{state="open"} == 1

# Taxa de falha acima de 50% sustentada por 1min
resilience4j_circuitbreaker_failure_rate > 50

# Retries falhando mais do que salvando (eficácia ruim)
rate(resilience4j_retry_calls_total{kind="failed_with_retry"}[5m])
  > rate(resilience4j_retry_calls_total{kind="successful_with_retry"}[5m])
```

> Sufixos podem variar conforme o `MeterRegistry` (o Prometheus adiciona `_total` em contadores, `_seconds` em timers). Confira os nomes exatos em `/actuator/prometheus` do seu serviço — não confie na memória.

## 6. Correlação

O ponto que torna isso operável de verdade: o **mesmo nome de instância** aparece na tag da métrica (`name`), no `kv("instance", ...)` do log de transição e no `@CircuitBreaker(name=...)`. Quando um alarme dispara em `resilience4j_circuitbreaker_state{name="paymentGateway",state="open"}`, você filtra os logs por `instance=paymentGateway` e encontra exatamente o WARN "circuit breaker ABRIU" com `from/to` e o `correlationId` do MDC daquele fluxo. Métrica diz *que* abriu; log diz *quando e em qual request*.
