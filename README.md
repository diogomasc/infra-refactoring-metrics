# LEIAME — Infraestrutura de Observabilidade (TCC)

## Contexto no TCC

Este repositório contém a **stack de observabilidade Dockerizada** que compõe a infraestrutura experimental do TCC. O projeto de pesquisa é dividido em **dois sub-projetos independentes**, sob mesma orientação acadêmica, divididos em repositórios separados para manter rastreabilidade:

| Repositório | Escopo | Função no Experimento |
|---|---|---|
| **spring-petclinic-rest** | Aplicação sob teste | Código Java com anomalias estruturais, instrumentação `@Observed`, análise estática |
| **infra** (este) | Stack de observabilidade | Prometheus, Grafana, K6 — coleta e visualização de métricas dinâmicas |

A comunicação entre ambos é via rede: o Prometheus (Docker) faz scrape da aplicação (host, porta 9966), e o K6 (`--network host`) envia requisições HTTP diretamente para os endpoints da API sem overhead de NAT.

---

## Arquitetura

```mermaid
flowchart TD
    subgraph HOST["HOST (JVM)"]
        APP["Spring PetClinic REST\n:9966\nInstrumentado com @Observed"]
        ACT["/petclinic/actuator/prometheus"]
        APP --> ACT
    end

    subgraph DOCKER["Docker Compose (infra)"]
        PROM["Prometheus\n:9090\nTSDB"]
        GRAF["Grafana\n:3000\nDashboards"]
    end

    subgraph BENCHMARK["Benchmark Runner"]
        K6["K6\n--network host\nTeste de carga"]
        SCRIPT["run-benchmark.sh\nOrquestração completa"]
    end

    PROM -- "scrape a cada 5s\n(metodo_execucao_seconds_*\n+ http_server_requests_*)" --> ACT
    K6 -- "HTTP requests direto\n(7 endpoints críticos)" --> APP
    GRAF -- "PromQL queries" --> PROM
    SCRIPT -- "orquestra" --> PROM
    SCRIPT -- "orquestra" --> K6
    SCRIPT -- "inicia/para" --> APP
```

---

## Árvore de Arquivos

```
infra/
├── docker-compose.infra.yml        # Orquestração dos serviços
├── prometheus.yml                   # Configuração de scrape
├── grafana/
│   └── provisioning/
│       ├── datasources/
│       │   └── prometheus.yml       # Datasource pré-configurado
│       └── dashboards/
│           ├── dashboards.yml       # Provider de dashboards
│           ├── tcc-endpoints-k6.json    # Endpoints + @Observed
│           └── tcc-jvm-spring-boot.json # Runtime JVM
├── k6/
│   └── load-test.js                 # Script de carga (metodologia RED + scenarios)
├── scripts/
│   ├── run-benchmark.sh             # Orquestração completa de benchmark
│   └── extrair-metricas.sh          # Extração de métricas Prometheus
├── results/                         # Logs e métricas de execuções (gitignored)
└── docs/
    └── guides/
        ├── grafana.md               # Guia: visualização e interpretação
        ├── k6-load-testing.md       # Guia: metodologia e perfil de carga
        ├── extrair-metricas.md      # Guia: extração de métricas Prometheus
        └── prometheus-micrometer.md # Guia: modelo de dados e PromQL
```

---

## Pré-requisitos

| Requisito | Comando de verificação |
|---|---|
| Docker | `docker --version` |
| Docker Compose v2 | `docker compose version` |
| Java 17+ | `java --version` |
| Maven (via wrapper) | `./mvnw --version` (no diretório spring-petclinic-rest) |
| curl | `curl --version` |

---

## Execução de Benchmark (Modo Primário)

O `run-benchmark.sh` é o **método primário** de execução, garantindo reprodutibilidade total:

```bash
# Executar benchmark baseline
bash infra/scripts/run-benchmark.sh baseline

# Executar benchmark pós-refatoração
bash infra/scripts/run-benchmark.sh pos-refatoracao
```

### O que o script faz (ciclo completo):

| Etapa | Ação | Justificativa |
|---|---|---|
| **1/5** | `docker compose down -v` | Limpa volumes Prometheus (elimina stale data) |
| **2/5** | `docker compose up -d` | Sobe Prometheus + Grafana com health-check |
| **3/5** | `./mvnw spring-boot:run` | Inicia Spring Boot com H2 in-memory (banco fresco) |
| **4/5** | `docker run --network host` K6 | Executa carga sem NAT overhead |
| **5/5** | `extrair-metricas.sh` (se presente) | Coleta snapshot do Prometheus |

### Saída:

```
infra/results/
├── benchmark-baseline-20260616-143000.log
└── metricas-baseline-20260616-143000.json
```

---

## Comandos Manuais

### Subir a stack (sem benchmark)

```bash
docker compose -f infra/docker-compose.infra.yml up -d
```

### Verificar status

```bash
docker compose -f infra/docker-compose.infra.yml ps
```

### Derrubar

```bash
docker compose -f infra/docker-compose.infra.yml down
```

### Reset total (com volumes)

```bash
docker compose -f infra/docker-compose.infra.yml down -v
```

### Rodar K6 manualmente (--network host)

```bash
docker run --rm --network host \
  -v $(pwd)/infra/k6:/scripts:ro \
  grafana/k6:latest run /scripts/load-test.js
```

### Rodar K6 via compose (alternativa)

```bash
docker compose -f infra/docker-compose.infra.yml \
  --profile testing run --rm k6 run /scripts/load-test.js
```

---

## Serviços e Portas

| Serviço | Porta | Credenciais | URL |
|---|---|---|---|
| Prometheus | 9090 | — | http://localhost:9090 |
| Grafana | 3000 | admin / admin | http://localhost:3000 |
| K6 | — (sob demanda) | — | — |

---

## Configuração do Prometheus

```yaml
- job_name: "spring-petclinic-rest"
  metrics_path: "/petclinic/actuator/prometheus"
  scrape_interval: 5s
  static_configs:
    - targets: ["host.docker.internal:9966"]
      labels:
        app: "spring-petclinic-rest"
        fase: "baseline"   # Alterar para "pos-refatoracao" na Fase 2
```

O label `fase` segmenta os dados no Grafana entre coleta baseline e pós-refatoração.

### Métricas Coletadas

| Métrica | Origem | Finalidade |
|---|---|---|
| `http_server_requests_seconds_*` | Spring Boot Actuator | Latência HTTP por endpoint |
| `metodo_execucao_seconds_*` | `@Observed` (Micrometer) | Latência por camada (Controller/Service) |
| `jvm_*`, `process_*` | JVM MBeans | Heap, GC, threads, CPU |

---

## Script K6 — Perfil de Carga (Scenarios)

O K6 usa dois **cenários separados** com tags para isolamento de métricas:

| Cenário | Fase | Duração | VUs | Tag | Incluído nos Thresholds |
|---|---|---|---|---|---|
| `warmup` | Ramp-up | 30s | 0 → 30 | `phase:warmup` | ❌ Excluído |
| `steady_state` | Sustentada | 1min | 30 → 50 | `phase:test` | ✅ Incluído |
| `steady_state` | Spike | 30s | 50 → 100 | `phase:test` | ✅ Incluído |
| `steady_state` | Estresse | 1min | 100 | `phase:test` | ✅ Incluído |
| `steady_state` | Ramp-down | 30s | 100 → 0 | `phase:test` | ✅ Incluído |

> **Justificativa:** A separação em cenários com tags permite exclusão matemática dos dados de warm-up JIT dos thresholds via filtro `{phase:test}`. Com stages simples, o K6 não possui mecanismo para excluir dados de fases específicas do relatório final.

### Endpoints Exercitados

| Endpoint | Método | Anomalia Correlacionada |
|---|---|---|
| `/petclinic/api/owners` | GET | N+1 EAGER cascata |
| `/petclinic/api/owners` | POST | Write-path completo |
| `/petclinic/api/owners/{id}` | GET | Grafo denso |
| `/petclinic/api/owners/{id}/pets` | POST | CascadeType.ALL |
| `/petclinic/api/owners/{ownerId}/pets/{petId}/visits` | POST | FK em tabela filha |
| `/petclinic/api/vets` | GET | N:M EAGER |
| `/petclinic/actuator/health` | GET | Baseline framework |

---

## Dashboards Grafana

Dois dashboards são provisionados automaticamente:

### 1. TCC — Endpoints & @Observed (PetClinic)

Três seções:
- **Visão Geral:** taxa de erro, p95 global, throughput por endpoint
- **Latência por Endpoint:** p50/p95/p99 para cada endpoint crítico
- **@Observed:** p95 por `contextualName`, throughput por método, taxa de erro por bean

### 2. TCC — JVM & Spring Boot

Métricas de runtime: heap, GC pause, threads ativas, CPU. Útil para correlacionar degradação de latência com pressão de memória (EAGER carregando grafos grandes).

---

## Guias Detalhados

| Guia | Conteúdo |
|---|---|
| [Grafana](docs/guides/grafana.md) | Dashboard @Observed, interpretação de painéis, exportação de dados |
| [K6 Load Testing](docs/guides/k6-load-testing.md) | Metodologia RED, perfil de carga, thresholds como fitness functions |
| [Prometheus + Micrometer](docs/guides/prometheus-micrometer.md) | Modelo de dados, @Observed, queries PromQL |
| [Extração de Métricas](docs/guides/extrair-metricas.md) | Script de extração de métricas Prometheus |

---

## Troubleshooting

| Problema | Solução |
|---|---|
| Prometheus não coleta | Verificar se a app roda na porta 9966 e `/petclinic/actuator/prometheus` responde |
| Grafana sem dados | Verificar Prometheus UP em http://localhost:9090/targets |
| K6 "connection refused" | Verificar se a aplicação está rodando antes do load test |
| @Observed sem dados | Fazer ao menos 1 requisição ao endpoint instrumentado (lazy registration) |
| Porta 9966 em uso | `fuser -k 9966/tcp` para liberar a porta |
| Benchmark inconsistente | Usar `run-benchmark.sh` para garantir ciclo completo de limpeza |
