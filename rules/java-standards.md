# Java & Spring Boot — Coding Standards

Regras **always-on**: aplicam-se a todo código Java/Spring gerado, revisado ou
refatorado. São o filtro de qualidade padrão.

## Stack base

| Decisão          | Escolha                                        |
| ---------------- | ---------------------------------------------- |
| Linguagem        | Java 25 (LTS)                                  |
| Framework        | Spring Boot 4.x (Spring Framework 7)           |
| Build            | Maven                                          |
| JSON             | Jackson 3 (default do Boot 4)                  |
| Null Safety      | JSpecify (`@NullMarked` / `@Nullable`)         |
| Lombok           | Apenas `@RequiredArgsConstructor` e `@Builder` |

## Princípios

- **SOLID, DRY, YAGNI, KISS** guiam todo design. A solução mais simples que
  resolve o problema é a correta; não implemente o que não foi pedido.
- **Composição sobre herança.** `extends` só quando o framework exige
  (ex: `OncePerRequestFilter`).
- **Imutabilidade como padrão** — campos `final`, sem setters, coleções
  defensivas (`List.copyOf`), records.
- **Sem classes anêmicas** — a lógica pertence ao objeto que possui os dados.

## Convenções

- **Todo DTO/VO/payload é `record`**, nunca `class` com getters/setters.
  Validação e cópia defensiva no construtor compacto.
- **Objetos sabem se construir.** Use métodos estáticos contextuais
  (`fromDomain`, `createNew`); builder interno via `@Builder(access = PRIVATE)`.
  **Nunca use MapStruct nem mappers externos** — a transformação pertence ao
  objeto criado.
- **Lombok restrito:** `@RequiredArgsConstructor` e `@Builder` em qualquer
  classe; `@AllArgsConstructor`/`@NoArgsConstructor` **apenas** em entidades JPA.
  **`@Data` é proibido.** Em entidades JPA, escreva `equals`/`hashCode` por
  identificador de negócio e `toString` sem campos sensíveis.

```java
// Padrão de auto-construção
public record OrderResponse(String orderId, String status, BigDecimal total) {
    public static OrderResponse fromDomain(Order order) {
        return new OrderResponse(order.getId(), order.getStatus().name(), order.calculateTotal());
    }
}
```

## Inversão de dependência

Classes mais internas (domínio/negócio) **não chamam diretamente** classes mais
externas/de infra — clientes HTTP, repositories, produtores de mensagem. Defina
uma **interface no nível interno** e implemente-a no nível externo. O domínio
depende da abstração, não do detalhe de infraestrutura.

## Features modernas do Java — use sempre que aplicável

- **Sealed interfaces + records** para modelar variantes de domínio.
- **Pattern matching para switch** (com exaustividade) — sem cadeias
  `if-else instanceof`. **Record patterns** para deconstrução.
- **Switch expressions** (`->`, retornando valor) em vez de statements.
- **Text blocks** para SQL/JSON/strings multi-linha.
- **Sequenced Collections** quando a ordem importa (`getFirst`/`getLast`).
- **Virtual threads** para I/O-bound (`spring.threads.virtual.enabled: true`);
  **nunca** para CPU-bound.
- **Scoped Values** em vez de `ThreadLocal` para propagar contexto.
- **Flexible constructor bodies** para validação fail-fast antes de `super()`.

## Null safety & Jackson

- `@NullMarked` em todo pacote de produção; `@Nullable` explícito onde aplicável.
- Jackson 3: records são cidadãos de primeira classe (sem anotações extras);
  exceção base é `JacksonException`.

## Exceções

- **Exceptions não são fluxo de negócio.** Para resultados com múltiplos caminhos
  (sucesso/falha/indisponível), use sealed interfaces + records, não exceptions.
- **Exceptions de domínio nomeadas com significado de negócio**
  (`OrderAlreadyConfirmedException`), nunca `RuntimeException`/`IllegalStateException`
  genéricos.

## Antes de entregar

Releia estas regras e confirme conformidade do código gerado antes de finalizar.
