# Visualização de Métricas com Grafana

## Visão Geral Arquitetural

O Grafana atua como camada de **apresentação e análise** no pipeline de observabilidade. Diferentemente do Prometheus (banco de séries temporais), o Grafana é *stateless*: não armazena dados, apenas os consulta e exibe. Esta separação de responsabilidades — coleta, armazenamento, visualização — é um princípio fundamental da observabilidade moderna (Richards e Ford, 2020).

No contexto do TCC, o Grafana funciona como um **radiador de informação** (Ford, Parsons e Kua, 2017): torna visível, em tempo real, se as fitness functions operacionais estão sendo atendidas durante o teste de carga.

### Provisionamento Declarativo

Este projeto utiliza **Infrastructure as Code** para dashboards e datasources — eliminando configuração manual:

```
infra/grafana/provisioning/
├── datasources/
│   └── prometheus.yml           # Datasource Prometheus pré-configurado
└── dashboards/
    ├── dashboards.yml           # Provider: define diretório de dashboards
    ├── tcc-endpoints-k6.json    # Métricas HTTP + @Observed por camada
    └── tcc-jvm-spring-boot.json # Runtime JVM (heap, GC, threads, CPU)
```

---

## Dashboard: TCC — Endpoints & @Observed (PetClinic)

O dashboard principal está organizado em **3 seções**, cada uma com um nível diferente de granularidade:

### Seção 1: Visão Geral — Erros e Throughput

| Painel | Query PromQL | O que Revela |
|---|---|---|
| Taxa de Erro HTTP (%) | `100 * sum(rate(...{outcome=~"CLIENT_ERROR\|SERVER_ERROR"}[2m])) / sum(rate(...[2m]))` | Estabilidade global sob carga |
| Latência p95 Global | `histogram_quantile(0.95, sum(rate(..._bucket[2m])) by (le)) * 1000` | SLO operacional |
| Throughput por Endpoint | `sum by (uri, method) (rate(..._count[1m]))` | Distribuição de carga entre endpoints |
| Erros por Endpoint/Status | `sum by (uri, status) (rate(...{outcome=~"..."}[1m]))` | Qual endpoint gera mais erros |

### Seção 2: Latência por Endpoint (p50/p95/p99)

Um painel para cada endpoint crítico:

| Painel | URI Template | Anomalia Monitorada |
|---|---|---|
| GET /owners | `/api/owners` (method=GET) | N+1 EAGER cascata |
| POST /owners | `/api/owners` (method=POST) | Write-path completo |
| GET /owners/{ownerId} | `/api/owners/{ownerId}` | Grafo denso |
| GET /vets | `/api/vets` | N:M EAGER |
| POST /owners/{id}/pets | `/api/owners/{ownerId}/pets` | Cascata JPA |
| POST /visits | `/api/visits` | Inserção em tabela filha |
| GET /actuator/health | `/actuator/health` | Baseline (sem negócio) |

> O painel de health check serve como **controle experimental**: a latência deve permanecer < 10ms independente da carga, confirmando que a degradação nos outros endpoints é causada pela lógica de negócio, não pelo framework.

### Seção 3: @Observed — Tempo de Execução por Camada

Esta seção é a **mais importante para o TCC** — fornece a evidência de onde o tempo é gasto dentro da aplicação.

| Painel | Métrica | Visualização |
|---|---|---|
| **p95 por @Observed** | `metodo_execucao_seconds_bucket` agrupado por `spring_observation_contextual_name` | Time series comparativo |
| **Taxa de Erro por @Observed** | `metodo_execucao_seconds_count{error!="none"}` | Gauge com threshold |
| **Throughput por @Observed** | `metodo_execucao_seconds_count` por `contextualName` | Time series |

#### Query Principal: p95 por contextualName

```promql
histogram_quantile(0.95,
  sum(rate(metodo_execucao_seconds_bucket{job="spring-petclinic-rest"}[1m]))
  by (le, spring_observation_contextual_name)
) * 1000
```

Esta query retorna uma série temporal para cada método instrumentado. A comparação visual entre `Controller_Owner_ListAll` e `Service_Owner_FindAll` isola o overhead de serialização (MapStruct + JSON).

#### Query: Throughput por método

```promql
sum by (spring_observation_contextual_name) (
  rate(metodo_execucao_seconds_count{job="spring-petclinic-rest"}[1m])
)
```

---

## Interpretação dos Painéis

### Ausência de Dados ("No data")

| Causa | Diagnóstico | Resolução |
|---|---|---|
| Nenhuma requisição ao endpoint | Throughput = 0 | Gerar tráfego (K6 ou curl manual) |
| Lazy registration do Micrometer | Série ausente no Prometheus | Fazer ao menos 1 chamada ao endpoint |
| Summary em vez de Histogram | `_bucket` ausente no `/actuator/prometheus` | Habilitar `percentiles-histogram=true` |
| Label incorreto | Série existe mas filtro falha | Validar `uri`, `method`, `job` no Prometheus UI |
| Janela de tempo inadequada | Teste ocorreu fora do intervalo | Ajustar range no seletor do Grafana |

### Leitura de Histogramas de Latência

- **p50 (mediana):** tempo "típico" — insensível a outliers
- **p95:** critério padrão de SLO — 95% das requisições completaram em ≤ X ms
- **p99:** captura *tail latency* — os casos extremos

> A diferença p95 - p99 revela a presença de *outliers*: diferença grande (ex: p95=200ms, p99=2000ms) indica comportamento não-determinístico — frequentemente N+1 com volume variável ou GC pause.

---

## Correlação entre Painéis para Análise Experimental

A análise comparativa (baseline × pós-refatoração) deve considerar os painéis em conjunto:

| Padrão Observado | Hipótese | Investigação |
|---|---|---|
| p99 alto + CPU alta | Gargalo computacional (Long Method) | Verificar `@Observed` p99 por método |
| p99 alto + CPU baixa | Gargalo de I/O (N+1 queries) | Verificar logs SQL do Hibernate |
| Taxa erro > 0% + p95 baixo | Falhas rápidas (validação rejeitando payload) | Verificar distribuição por status |
| Heap crescente durante carga | Memory pressure (EAGER carregando grafos) | Correlacionar com GC pause no dashboard JVM |
| p95 Service ≈ p95 Controller | Overhead de serialização desprezível | O gargalo está no JPA, não no MapStruct |
| **p95 Service ≪ p95 Controller** | **MapStruct/JSON domina a latência** | Investigar tamanho do payload JSON |

---

## Exportação de Dados para Documentação Acadêmica

### Via API REST do Grafana

```bash
curl -u admin:admin \
  "http://localhost:3000/api/datasources/proxy/1/api/v1/query_range" \
  --data-urlencode 'query=histogram_quantile(0.95, ...)' \
  --data-urlencode 'start=<unix-timestamp>' \
  --data-urlencode 'end=<unix-timestamp>' \
  --data-urlencode 'step=15s'
```

### Via Interface

**Painel → ⋮ → Inspect → Data → Download CSV** — exporta os pontos da série temporal para o intervalo selecionado.

> **Recomendação:** exporte os dados como CSV e calcule estatísticas (média, p95, máximo) em planilha ou script Python. Isso garante **reprodutibilidade** dos resultados apresentados no TCC e permite testes estatísticos formais (Mann-Whitney U, Wilcoxon) entre baseline e pós-refatoração.

---

## Referências

- Richards, M.; Ford, N. (2020). *Fundamentals of Software Architecture*. O'Reilly.
- Ford, N.; Parsons, R.; Kua, P. (2017). *Building Evolutionary Architectures*. O'Reilly.
