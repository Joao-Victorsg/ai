# Tuning avançado — janelas, backoff, ordem dos aspectos e idempotência

Aprofundamento das seções 2 e 3 do `SKILL.md`. Os valores do `SKILL.md` são **pontos de partida**; aqui está o como e o porquê de calibrá-los.

## Sumário

1. [Sliding window: COUNT × TIME](#1-sliding-window)
2. [Slow calls](#2-slow-calls)
3. [Backoff exponencial + jitter](#3-backoff)
4. [Ordem dos aspectos e onde fica o fallback](#4-ordem-dos-aspectos)
5. [Idempotência: quando NÃO retentar](#5-idempotência)
6. [Quando agregar Time Limiter / Bulkhead](#6-time-limiter-bulkhead)
7. [Config compartilhada e fronteira com a skill de HTTP client](#7-fronteira)

---

## 1. Sliding window

O breaker decide olhando uma janela deslizante das últimas chamadas.

- **`COUNT_BASED`** (`sliding-window-type`): janela das últimas *N* chamadas (`sliding-window-size`). Previsível, bom para volume estável. É o default da skill.
- **`TIME_BASED`**: janela dos últimos *N* segundos. Melhor quando o tráfego é irregular — evita que poucas chamadas espaçadas no tempo "lembrem" de falhas muito antigas.

`minimum-number-of-calls` é o anti-ruído: abaixo dele o breaker **não calcula taxa** (e a métrica `failure.rate` fica −1). Sem isso, 1 falha em 1 chamada = 100% e o circuito abre por nada. Regra prática: `minimum-number-of-calls` ≥ 5 e ≤ `sliding-window-size`.

`wait-duration-in-open-state` é quanto o circuito fica aberto antes de ir para `HALF_OPEN`. `permitted-number-of-calls-in-half-open-state` são as chamadas de teste; se a taxa delas estiver boa, fecha; senão, reabre. `automatic-transition-from-open-to-half-open-enabled: true` faz a transição sozinha (usa uma thread interna); sem isso, a transição só ocorre quando chega uma chamada.

## 2. Slow calls

Um downstream pode não estar *falhando* e ainda assim estar *doente* — respondendo a 8s quando deveria responder a 200ms. O breaker trata isso:

```yaml
slow-call-duration-threshold: 2s
slow-call-rate-threshold: 100   # % de chamadas lentas que conta para abrir
```

Chamada acima do threshold conta como "lenta"; se a taxa de lentas cruzar `slow-call-rate-threshold`, o breaker abre **mesmo sem exceções**. Útil quando o downstream degrada antes de cair. Combine com o `read-timeout` do client (skill de HTTP) — o timeout é o teto absoluto; o slow-call abre o circuito *antes* de cada chamada bater no teto.

## 3. Backoff

Retentar imediatamente, em massa, é como bater na porta mais forte quando ninguém atende — vira *retry storm*. Duas defesas, combináveis:

```yaml
enable-exponential-backoff: true
exponential-backoff-multiplier: 2        # 500ms → 1s → 2s ...
exponential-max-wait-duration: 5s        # teto por tentativa
enable-randomized-wait: true             # jitter
randomized-wait-factor: 0.5              # ±50% no intervalo
```

- **Exponencial**: dá tempo crescente para o downstream respirar entre tentativas.
- **Jitter** (`enable-randomized-wait`): espalha as tentativas de instâncias diferentes no tempo. Sem jitter, N pods que falharam juntos retentam juntos — e batem no downstream sincronizados, justamente quando ele está frágil. Combinar os dois usa a `ExponentialRandomBackoffIntervalFunction`.

Mantenha `max-attempts` baixo (2–3). Retry não é para downstream que está *fora* (disso cuida o breaker) — é para a falha *transitória* (um pacote perdido, um GC pause). Mais de 3 tentativas raramente ajuda e só aumenta latência e carga.

## 4. Ordem dos aspectos

Com `@Retry` e `@CircuitBreaker` no mesmo método, a ordem padrão (do mais externo para o mais interno) é:

```
Retry ( CircuitBreaker ( chamada ) )
```

Ou seja, **cada tentativa do retry passa pelo circuito**. Consequências:

- Quando o breaker está **aberto**, ele lança `CallNotPermittedException` *na hora*. Esse erro sobe até o Retry. **Por isso o retry deve ignorá-lo** (`ignore-exceptions`): senão você gasta todas as tentativas (com o `wait-duration` entre elas) recebendo o mesmo erro instantâneo — latência pura sem nenhum ganho.
- **`fallbackMethod` vai no aspecto mais externo (o `@Retry`).** Cada aspecto que tem `fallbackMethod` intercepta a exceção dos internos e devolve o fallback ali mesmo. Se o fallback estivesse no `@CircuitBreaker` (interno), ele engoliria a falha na **primeira** tentativa e devolveria o degradado como se fosse sucesso — o Retry veria sucesso e **nunca retentaria**. Logo: fallback no `@Retry` ⇒ *retenta, e só degrada depois de esgotar*.

Para inverter a ordem (fazer o breaker contar a *sequência inteira de retries* como uma única chamada lógica, em vez de cada tentativa), ajuste os `*-aspect-order`:

```yaml
resilience4j:
  retry:
    retry-aspect-order: 1            # menor = mais interno
  circuitbreaker:
    circuit-breaker-aspect-order: 2  # maior = mais externo
```

Isso dá `CircuitBreaker ( Retry ( chamada ) )` — útil se você quer que "uma operação com todas as suas tentativas falhou" conte como **uma** falha no breaker, e não como N. É uma decisão de semântica; o default (Retry externo) é o mais comum e o que a skill entrega.

## 5. Idempotência

Retry de **timeout** (`ResourceAccessException`) é traiçoeiro: a requisição pode ter chegado e sido processada no downstream — o timeout foi só na *resposta*. Retentar então **duplica o efeito**.

- **Idempotente** (GET, PUT, DELETE, ou POST com chave de idempotência): retentar é seguro.
- **Não idempotente** (POST que cria/cobra sem chave): **não** liste `ResourceAccessException` em `retry-exceptions`, ou restrinja o retry a 5xx "limpos" (onde você sabe que nada foi processado). Melhor ainda: peça ao downstream uma **idempotency key** e aí o retry volta a ser seguro.

Confirme isso no Passo 0 — é a pergunta nº 3. Retry cego em operação financeira não idempotente é um bug de produção esperando para acontecer.

## 6. Time Limiter / Bulkhead

Fora do escopo central (CB + Retry), mas reconheça quando o usuário precisa:

- **Time Limiter** (`@TimeLimiter`): teto de latência para chamadas **assíncronas** (retorno `CompletableFuture`). Para o client síncrono `RestClient`, o teto já vem do `read-timeout` (skill de HTTP) — não precisa de Time Limiter. Só agregue se a chamada for `CompletableFuture`/reativa.
- **Bulkhead** (`@Bulkhead`): limita chamadas concorrentes a um recurso, isolando-o para que um downstream lento não esgote todas as threads do serviço. Considere quando um downstream lento puder causar *thread starvation* que derruba fluxos não relacionados. No Boot 4, o `@ConcurrencyLimit` nativo do Spring Framework 7 também resolve o caso simples.

Se o usuário pedir esses, vale uma skill/seção dedicada — não os enfie na entrega de CB + Retry sem necessidade (YAGNI).

## 7. Fronteira

A skill `spring-java-http-client` gera o **client** e mapeia os erros nas exceções nativas do `RestClient`; o `references/erros-e-resiliencia.md` dela mostra um esqueleto de Resilience4J e **aponta para cá** para a política fina. Esta skill é o dono de: número de tentativas, backoff, tipo/tamanho de janela, thresholds, ordem dos aspectos, idempotência, e a observabilidade (métricas + logs de evento). Quando as duas skills atuam juntas, **não duplique** o bloco `resilience4j:` — ele mora aqui.

**Config compartilhada:** para muitos clients com a mesma política, use a instância `default` e herde:

```yaml
resilience4j:
  circuitbreaker:
    configs:
      default: { sliding-window-size: 20, failure-rate-threshold: 50, ... }
    instances:
      paymentGateway: { base-config: default }
      inventory:      { base-config: default, failure-rate-threshold: 70 }   # só o override
```

Mantém DRY e deixa cada instância só com o que difere.
