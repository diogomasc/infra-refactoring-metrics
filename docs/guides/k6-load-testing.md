# Testes de Carga com K6

## Visão Geral Metodológica

O K6 é uma ferramenta de teste de carga baseada em scripts JavaScript (ES6+) desenvolvida pela Grafana Labs. Neste projeto, o K6 é responsável pela coleta de **métricas dinâmicas de carga**, complementando a observabilidade passiva do Prometheus/Micrometer.

A distinção entre as duas abordagens é fundamental para o TCC:

| Perspectiva | Ferramenta | O que mede | Onde reside |
|---|---|---|---|
| **Cliente** | K6 | Tempo ponta a ponta (inclui rede + serialização HTTP) | `--network host` (direto no host) |
| **Servidor** | Micrometer (`@Observed`) | Tempo de processamento por camada (Controller, Service) | Dentro da JVM |

Em execução com `--network host`, a latência de rede entre K6 e a aplicação é eliminada — o tráfego ocorre via loopback (`localhost`), sem traversar a camada NAT do Docker bridge. Isso garante que os percentis P95/P99 meçam exclusivamente o tempo de processamento da aplicação.

---

## Relação K6 ↔ @Observed

```mermaid
sequenceDiagram
    participant K6 as K6 (Cliente)
    participant CTRL as Controller (@Observed)
    participant SVC as Service (@Observed)
    participant DB as H2 Database

    K6->>+CTRL: GET /api/owners
    Note over K6,CTRL: ⏱️ K6 mede: http_req_duration

    CTRL->>+SVC: findAllOwners()
    Note over CTRL,SVC: ⏱️ @Observed: Controller_Owner_ListAll

    SVC->>+DB: ownerRepository.findAll()
    Note over SVC,DB: ⏱️ @Observed: Service_Owner_FindAll
    DB-->>-SVC: List<Owner> (+ EAGER: Pet, Visit)
    SVC-->>-CTRL: Collection<Owner>

    Note over CTRL: MapStruct → JSON
    CTRL-->>-K6: 200 OK [JSON]

    Note over K6: Δ(K6 - Controller) = overhead HTTP
    Note over CTRL: Δ(Controller - Service) = MapStruct + JSON
    Note over SVC: Service ≈ custo JPA + @Transactional
```

---

## Modelo de Carga: Metodologia RED

O script implementa a **metodologia RED** (Rate, Errors, Duration) proposta por Tom Wilkie (Grafana Labs), que Richards e Ford (2020) recomendam como padrão de observabilidade para microsserviços — igualmente aplicável a monolitos modulares.

| Dimensão | O que mede | Métrica K6 |
|---|---|---|
| **Rate** | Requisições por segundo | `http_reqs` |
| **Errors** | Proporção de falhas | `taxa_erro` (Rate customizado) |
| **Duration** | Latência das requisições | `http_req_duration` + Trends por endpoint |

---

## Perfil de Carga (Scenarios)

O K6 utiliza dois **cenários separados** (`warmup` e `steady_state`) com tags de fase para isolamento de métricas. Isso permite exclusão matemática dos dados de warm-up JIT do relatório final — impossível com `stages` simples.

```mermaid
gantt
    title Perfil de Carga K6 — 3min30s total (2 cenários)
    dateFormat ss
    axisFormat %S

    section warmup (phase=warmup)
    Ramp-up 0→30 VUs       :a1, 00, 30s

    section steady_state (phase=test)
    Sustentada 50 VUs       :a2, 30, 60s
    Spike 50→100 VUs        :a3, after a2, 30s
    Estresse 100 VUs        :a4, after a3, 60s
    Ramp-down 100→0         :a5, after a4, 30s
```

| Cenário | Fase | Duração | VUs | Tag | Nos Thresholds |
|---|---|---|---|---|---|
| `warmup` | Ramp-up | 30s | 0 → 30 | `phase:warmup` | ❌ Excluído |
| `steady_state` | Sustentada | 1min | 30 → 50 | `phase:test` | ✅ Incluído |
| `steady_state` | Spike | 30s | 50 → 100 | `phase:test` | ✅ Incluído |
| `steady_state` | Estresse | 1min | 100 | `phase:test` | ✅ Incluído |
| `steady_state` | Ramp-down | 30s | 100 → 0 | `phase:test` | ✅ Incluído |

> **Justificativa do isolamento:** O K6 não possui funcionalidade nativa para excluir dados de stages específicos do relatório final. A abordagem com `scenarios` e `tags` permite filtrar métricas por `{phase:test}` nos thresholds, garantindo que apenas os dados da fase de teste efetiva sejam avaliados.

> **Justificativa do spike:** Fowler (2018) observa que code smells frequentemente são "invisíveis sob carga baixa e catastróficos sob carga alta". O spike de 50→100 VUs é desenhado para provocar essa transição — se `GET /owners` com EAGER N+1 escala linearmente até 50 VUs mas quadraticamente além, o spike torna isso visível.

> **Princípio de comparabilidade:** para que a comparação baseline × pós-refatoração seja metodologicamente válida, **nenhum parâmetro** do script (scenarios, thresholds, payloads) pode ser alterado entre as fases. Apenas o código Java muda. Isso isola a variável independente (refatoração) da variável dependente (latência).

---

## Thresholds como Fitness Functions

Os thresholds do K6 funcionam como *fitness functions automatizadas* (Ford, Parsons e Kua, 2017): critérios de aceitação formalizados que protegem características operacionais.

```javascript
thresholds: {
    'http_req_duration{phase:test}':        ['p(95)<5000'],    // SLO global
    'taxa_erro{phase:test}':                ['rate<0.10'],      // < 10% de erros
    'latencia_listar_owners{phase:test}':   ['p(95)<4000'],    // N+1 EAGER
    'latencia_criar_owner{phase:test}':     ['p(95)<3000'],    // write-path
    'latencia_consultar_owner{phase:test}': ['p(95)<3000'],    // grafo denso
    'latencia_criar_pet{phase:test}':       ['p(95)<3000'],    // cascata JPA
    'latencia_criar_visit{phase:test}':     ['p(95)<3000'],    // inserção filha
    'latencia_listar_vets{phase:test}':     ['p(95)<2000'],    // N:M EAGER
}
```

> **Filtro `{phase:test}`:** Garante que apenas dados do cenário `steady_state` (tag `phase:test`) são avaliados. Os dados do cenário `warmup` (tag `phase:warmup`) são coletados mas matematicamente excluídos dos thresholds.

O K6 retorna exit code 99 quando um threshold é violado. No contexto do TCC:
- **Violação no baseline:** confirma que o débito técnico causa degradação mensurável
- **Aprovação no pós-refatoração:** confirma que a refatoração melhorou a fitness function

---

## Métricas Customizadas

| Métrica K6 | Tipo | Endpoint | Anomalia Correlacionada |
|---|---|---|---|
| `latencia_listar_owners` | Trend | `GET /owners` | N+1 via EAGER cascata |
| `latencia_criar_owner` | Trend | `POST /owners` | Write-path completo |
| `latencia_consultar_owner` | Trend | `GET /owners/{id}` | Grafo denso |
| `latencia_criar_pet` | Trend | `POST /owners/{id}/pets` | CascadeType.ALL |
| `latencia_criar_visit` | Trend | `POST .../visits` | FK em tabela filha |
| `latencia_listar_vets` | Trend | `GET /vets` | N:M EAGER |
| `latencia_health` | Trend | `GET /actuator/health` | Baseline (sem negócio) |
| `taxa_erro` | Rate | Todos | Estabilidade global |
| `owners_criados_com_sucesso` | Counter | `POST /owners` | Throughput efetivo |

---

## Execução

### Método Primário: `run-benchmark.sh`

O script orquestra o ciclo completo (limpeza → infra → app → K6 → coleta):

```bash
# Benchmark baseline (pré-refatoração)
bash infra/scripts/run-benchmark.sh baseline

# Benchmark pós-refatoração
bash infra/scripts/run-benchmark.sh pos-refatoracao
```

### Método Manual: Docker `--network host`

```bash
# Garantir que Spring Boot está rodando em localhost:9966
docker run --rm --network host \
  -v $(pwd)/infra/k6:/scripts:ro \
  grafana/k6:latest run /scripts/load-test.js
```

### Método Alternativo: Via Compose

```bash
docker compose -f infra/docker-compose.infra.yml \
  --profile testing run --rm k6 run /scripts/load-test.js
```

---

## Interpretação dos Resultados

### Saída do Terminal

O K6 exibe métricas separadas por cenário:

```
█ SCENARIO: warmup        ← Dados de aquecimento (ignorar)
█ SCENARIO: steady_state  ← Dados válidos para análise
```

```
http_req_duration........: avg=1.2s  min=42ms  med=890ms  max=4.1s  p(90)=2.8s  p(95)=3.4s
```

- **`avg`:** sensível a outliers — usar com cautela como métrica primária
- **`med` (p50):** tempo "típico" — insensível a outliers
- **`p(95)`:** critério padrão para SLOs (Ford, Parsons e Kua, 2017)
- **`max`:** cauda extrema — pode revelar N+1 acumulado ou GC pause

> A diferença `p95 - p50` é um indicador de variabilidade: se alta, sugere comportamento não-determinístico (EAGER com volume variável, GC pause, contenção).

---

## Protocolo de Coleta de Dados

Para garantir validade metodológica:

1. Executar `run-benchmark.sh` (garante ciclo completo automaticamente)
2. Capturar screenshot do dashboard Grafana ao final
3. Exportar CSV dos painéis de latência
4. Registrar timestamps de início e fim (incluídos no log automaticamente)
5. Salvar artefatos em `infra/results/`

---

## Referências

- Richards, M.; Ford, N. (2020). *Fundamentals of Software Architecture*. O'Reilly.
- Ford, N.; Parsons, R.; Kua, P. (2017). *Building Evolutionary Architectures*. O'Reilly.
- Fowler, M. (2018). *Refactoring*, 2nd ed. Addison-Wesley.
