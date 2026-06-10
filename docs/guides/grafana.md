# Visualização de Métricas com Grafana

## Visão Geral Arquitetural

O Grafana atua como camada de **apresentação e análise** no pipeline de observabilidade. Diferentemente do Prometheus, que é um banco de dados de séries temporais, o Grafana é stateless: ele não armazena dados, apenas os consulta e exibe. Esta separação de responsabilidades (coleta, armazenamento, visualização) é um princípio fundamental da arquitetura de observabilidade moderna.

### Provisionamento declarativo

Este projeto utiliza o mecanismo de **Infrastructure as Code** do Grafana: dashboards e datasources são definidos em arquivos YAML/JSON versionados, eliminando configuração manual via interface. O Grafana carrega esses arquivos na inicialização e os trata como fontes de verdade.

```
infra/grafana/provisioning/
├── datasources/
│   └── prometheus.yml    # Datasource Prometheus pré-configurado
└── dashboards/
    ├── dashboards.yml     # Provider: define o diretório de dashboards
    ├── tcc-endpoints-k6.json    # Dashboard: métricas de endpoint e carga
    └── tcc-jvm-spring-boot.json # Dashboard: métricas de runtime JVM
```

---

## Interpretação dos Painéis

### Ausência de dados ("No data")

A ausência de dados em um painel pode ter múltiplas causas, com diagnósticos distintos:

| Causa | Diagnóstico | Resolução |
|---|---|---|
| Nenhuma requisição ao endpoint | Throughput = 0 no mesmo período | Gerar tráfego (testes de carga ou chamadas manuais) |
| Métrica com lazy registration | Ausência de série no Prometheus Explorer | Realizar ao menos uma chamada ao endpoint instrumentado |
| Tipo de métrica errado (summary vs histogram) | `_bucket` ausente no `/actuator/prometheus` | Habilitar `percentiles-histogram=true` |
| Label incorreto na query | Série existe mas filtro não corresponde | Validar `uri`, `method`, `outcome`, `job` no Prometheus UI |
| Janela de tempo inadequada | Teste ocorreu fora do intervalo selecionado | Ajustar range de tempo no painel |

### Interpretação de histogramas de latência

Os painéis de latência usam `histogram_quantile()` para calcular percentis a partir dos buckets do Prometheus:

- **p50 (mediana):** metade das requisições completou em ≤ X ms
- **p95:** 95% das requisições completaram em ≤ X ms — métrica padrão de SLO
- **p99:** 99% completaram em ≤ X ms — captura os casos extremos (*tail latency*)

> A diferença entre p95 e p99 revela a presença de *outliers*: uma diferença grande (ex: p95=200ms, p99=2000ms) indica comportamento não-determinístico, frequentemente causado por contenção de recursos, garbage collection ou N+1 queries.

### Taxa de erro

O painel "Taxa de Erro HTTP (4xx + 5xx)" usa o label `outcome` (não `status`):

```promql
outcome=~"CLIENT_ERROR|SERVER_ERROR"
```

Esta distinção é relevante porque:
- **4xx (CLIENT_ERROR):** erros de validação, payload inválido — indicam problemas no contrato da API
- **5xx (SERVER_ERROR):** exceções não tratadas, falhas de infraestrutura — indicam instabilidade do serviço

Para fins do experimento, ambas as categorias são relevantes: taxa de erro 4xx elevada durante testes de carga pode indicar problemas na validação de dados nos controllers do PetClinic, enquanto 5xx pode revelar falhas na camada `ClinicServiceImpl` ou cascatas JPA sob contenção.

---

## Correlação entre Painéis para Análise Experimental

A análise comparativa (baseline × pós-refatoração) deve considerar os painéis em conjunto, não isoladamente:

| Padrão observado | Hipótese | Investigação |
|---|---|---|
| p99 alto + CPU alta | Gargalo computacional (Long Method) | Verificar `@Observed` p99 por método |
| p99 alto + CPU baixa | Gargalo de I/O (N+1 queries) | Verificar logs SQL do Hibernate |
| Taxa de erro > 0% + p95 baixo | Falhas rápidas (validação rejeitando payload) | Verificar distribuição por status no painel de erros |
| Heap crescente durante carga | Possível memory pressure | Correlacionar com GC pause time no dashboard JVM |
| Threads ativas ≫ VUs do K6 | Contenção de threads Tomcat | Revisar pool de conexões HikariCP |

---

## Exportação de Dados para Documentação Acadêmica

### Via API REST do Grafana

```bash
# Exportar dados de um painel como CSV (requer autenticação)
curl -u admin:admin \
  "http://localhost:3000/api/datasources/proxy/1/api/v1/query_range" \
  --data-urlencode 'query=histogram_quantile(0.95, ...)' \
  --data-urlencode 'start=<unix-timestamp>' \
  --data-urlencode 'end=<unix-timestamp>' \
  --data-urlencode 'step=15s'
```

### Via interface

**Painel → ⋮ → Inspect → Data → Download CSV** — exporta os pontos da série temporal exibida no painel para o intervalo selecionado.

> **Recomendação:** para documentar o baseline e o pós-refatoração, exporte os dados como CSV e calcule as estatísticas (média, p95, máximo) em uma planilha ou script Python. Isso garante reprodutibilidade dos resultados apresentados no TCC.
