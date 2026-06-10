# Observabilidade Dinâmica com Prometheus e Micrometer

## Visão Geral Arquitetural

O pipeline de observabilidade dinâmica deste projeto segue o padrão **Push-Pull** de telemetria: a aplicação instrumentada expõe métricas no formato OpenMetrics (Prometheus), e um agente de coleta externo as captura periodicamente (*scrape*). A camada de visualização consome os dados do servidor de séries temporais e os apresenta em painéis analíticos.

```
Aplicação (Micrometer) → /actuator/prometheus → Prometheus (TSDB) → Grafana (Visualização)
```

Este padrão, estabelecido pela Cloud Native Computing Foundation (CNCF), oferece baixo acoplamento entre o produtor de métricas e o consumidor, garantindo que a instrumentação não interfira no comportamento funcional da aplicação instrumentada.

---

## Modelo de Dados do Prometheus

O Prometheus utiliza quatro tipos primitivos de métricas:

| Tipo | Descrição | Uso neste projeto |
|---|---|---|
| **Counter** | Valor monotonicamente crescente | Total de requisições HTTP (`_total`) |
| **Gauge** | Valor instantâneo, pode crescer ou diminuir | Heap JVM, threads ativas |
| **Histogram** | Distribui observações em buckets `le` | Latência HTTP (`_bucket`, `_sum`, `_count`) |
| **Summary** | Percentis pré-calculados no cliente | Alternativa ao Histogram (sem `histogram_quantile`) |

> **Decisão arquitetural:** este projeto usa **Histogram** (não Summary) para métricas de latência. Histogramas permitem calcular percentis arbitrários no servidor Prometheus via `histogram_quantile()` e agregar dados de múltiplas instâncias. O tradeoff é maior cardinalidade de séries temporais.

### Configuração obrigatória (Spring Boot 4.x)

Por padrão, o Spring Boot emite métricas HTTP como `summary`. Para habilitar a distribuição em histogramas:

```properties
management.metrics.distribution.percentiles-histogram.http.server.requests=true
```

Esta propriedade instrui o Micrometer a publicar linhas `_bucket{le="..."}` para cada valor de `le` (Less or Equal), possibilitando:

```promql
histogram_quantile(0.95, sum(rate(http_server_requests_seconds_bucket[1m])) by (le))
```

---

## Instrumentação via Observation API

A **Observation API** (Micrometer 1.10+, integrada ao Spring Boot 3.x/4.x) representa uma evolução sobre a API de métricas direta. Uma única `Observation` pode propagar contexto para múltiplos backends (métricas, rastreamento distribuído, logs) sem alteração no código de negócio.

### Mecanismo de ativação via AOP

A anotação `@Observed` requer um `ObservedAspect` registrado como bean Spring, que interceta chamadas via proxy AspectJ:

```java
@Configuration(proxyBeanMethods = false)
public class ObservationConfig {
    @Bean
    ObservedAspect observedAspect(ObservationRegistry registry) {
        return new ObservedAspect(registry);
    }
}
```

**Restrições arquiteturais:**
- Aplica-se apenas a **Spring Beans** gerenciados pelo contexto de aplicação
- Não funciona em chamadas `static`, chamadas internas à mesma classe, ou objetos instanciados com `new`
- Quando aplicada em nível de classe, instrumenta todos os métodos públicos

### Métricas geradas por `@Observed`

Para um bean anotado com `@Observed(name = "clinic.service")`, o Prometheus recebe:

| Série | Tags | Semântica |
|---|---|---|
| `clinic_service_seconds_bucket` | `le`, `method`, `error`, `class` | Distribuição de latência por método |
| `clinic_service_seconds_count` | `method`, `error`, `class` | Total de invocações |
| `clinic_service_seconds_sum` | `method`, `error`, `class` | Soma acumulada do tempo de execução |
| `clinic_service_active_seconds` | `method`, `class` | Invocações em andamento (concorrência) |

A tag `error` assume `"none"` em execuções bem-sucedidas ou o nome da exceção capturada (ex: `"RuntimeException"`), permitindo calcular taxa de erro por método.

---

## Consultas PromQL de Referência

### Latência por percentil

```promql
# p95 global de todas as requisições HTTP
histogram_quantile(0.95,
  sum(rate(http_server_requests_seconds_bucket{job="<job-name>"}[1m])) by (le)
) * 1000

# p99 de um endpoint específico
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket{
    job="<job-name>", uri="<uri-template>", method="<HTTP-METHOD>"
  }[1m])) by (le)
) * 1000
```

> **Nota:** O `uri` corresponde ao **template da rota** registrado pelo Spring MVC (ex: `/api/owners/{ownerId}`), não à URL real da requisição (ex: `/api/owners/1`).

### Taxa de erro

```promql
# Percentual de requisições com outcome CLIENT_ERROR ou SERVER_ERROR
100 *
  sum(rate(http_server_requests_seconds_count{
    job="<job-name>", outcome=~"CLIENT_ERROR|SERVER_ERROR"
  }[2m]))
/
  sum(rate(http_server_requests_seconds_count{job="<job-name>"}[2m]))
```

> **Distinção crítica:** o label `status` contém o código HTTP numérico (`200`, `400`, `500`); o label `outcome` contém a categorização semântica (`SUCCESS`, `CLIENT_ERROR`, `SERVER_ERROR`). Para taxa de erro abrangente, use `outcome`.

### Throughput

```promql
sum by (uri, method) (
  rate(http_server_requests_seconds_count{job="<job-name>"}[1m])
)
```

### Comparação cross-bean (@Observed)

```promql
histogram_quantile(0.95,
  sum by (le, __name__) (
    rate({job="<job-name>", __name__=~".*_service_seconds_bucket"}[1m])
  )
) * 1000
```

---

## Considerações sobre Cardinalidade

Histogramas têm custo em cardinalidade: cada combinação única de labels gera uma série temporal distinta. Em produção, é necessário limitar os valores de labels dinâmicos (ex: IDs de usuário como label são antipadrão). Para fins de pesquisa controlada com endpoints fixos, este custo é negligenciável.
