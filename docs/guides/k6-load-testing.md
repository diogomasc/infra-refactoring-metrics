# Testes de Carga com K6

## Visão Geral Metodológica

O K6 é uma ferramenta de teste de carga baseada em scripts JavaScript (ES6+) desenvolvida pela Grafana Labs. Neste projeto, o K6 é responsável pela coleta de **métricas dinâmicas de carga**, complementando a observabilidade passiva do Prometheus/Micrometer.

A distinção fundamental entre as duas abordagens é:
- **Micrometer (servidor):** mede o tempo de processamento *interno* — da chegada da requisição ao retorno da resposta pelo framework
- **K6 (cliente):** mede o tempo de resposta *ponta a ponta* — inclui latência de rede e serialização HTTP

Em ambientes controlados como este (loopback ou rede local Docker), a diferença entre as duas medições é negligenciável, mas a comparação entre elas pode evidenciar overhead de serialização.

---

## Modelo de Carga: Metodologia RED

O script implementa a **metodologia RED** (Rate, Errors, Duration) proposta por Tom Wilkie (Grafana Labs):

| Dimensão | O que mede | Métrica no K6 |
|---|---|---|
| **Rate** | Taxa de requisições por segundo | `http_reqs` |
| **Errors** | Proporção de requisições com falha | `taxa_erro` (Rate customizado) |
| **Duration** | Latência das requisições | `http_req_duration` + Trends por endpoint |

### Perfil de carga escalonado

```
VUs
50 │              ████████████████████
10 │  ████████████                    ████████████
 0 ├──┤────────────┤──────────────────┤────────────┤──
   0s  30s         2m30s             3m          4m30s
```

Este perfil escalonado — com fase de rampa, estabilização, pico e descida — é fundamental para:
1. **Aquecimento da JVM:** o compilador JIT otimiza os caminhos críticos durante a rampa
2. **Identificação de degradação sob carga:** o comportamento estável a 10 VUs vs 50 VUs revela o impacto dos code smells sob contenção
3. **Verificação de recuperação:** a descida confirma que o sistema libera recursos adequadamente

---

## Parametrização e Reprodutibilidade

O script utiliza payloads parametrizados por VU, garantindo que:
- Cada VU crie owners/pets únicos (realismo)
- O comportamento do servidor seja consistente entre fases baseline e pós-refatoração
- Os mesmos endpoints e perfil de carga sejam exercitados em todas as execuções (determinismo)

> **Princípio de comparabilidade:** para que a comparação experimental seja válida, **nenhum parâmetro do script** (stages, thresholds, payloads, distribuição de endpoints) pode ser alterado entre as fases. Apenas o código da aplicação muda.

---

## Thresholds como Hipóteses Experimentais

Os thresholds do K6 funcionam como **critérios de aceitação formalizados**:

```javascript
thresholds: {
    'http_req_duration': ['p(95)<2000'],   // SLO: 95% das req < 2s
    'taxa_erro': ['rate<0.05'],            // SLO: menos de 5% de erros
}
```

No contexto desta pesquisa, é importante observar se o baseline viola esses thresholds sob estresse (o K6 retorna exit code 99 nesse caso). A comparação pós-refatoração revela se a melhoria do código interno impacta a performance dinâmica.

---

## Interpretação dos Resultados

### Saída do terminal (exemplo anotado)

```
http_req_duration........: avg=1.2s  min=42ms  med=890ms  max=4.1s  p(90)=2.8s  p(95)=3.4s
                          ↑ média    ↑ mínimo  ↑ mediana             ↑ p90       ↑ p95
```

- **`avg` (média):** útil como referência mas sensível a outliers — não use como métrica primária de SLO
- **`med` (mediana = p50):** tempo "típico" de resposta — insensível a outliers
- **`p(95)`:** critério padrão para SLOs; garante experiência aceitável para 95% dos usuários
- **`max`:** valor de cauda extrema — pode revelar comportamentos degenerativos (ex: N+1 acumulado)

### Métricas customizadas registradas

| Métrica | Tipo K6 | Semântica experimental |
|---|---|---|
| `latencia_listar_owners` | Trend | Custo de `findAllOwners()` — FetchType.EAGER cascata N+1 |
| `latencia_criar_owner` | Trend | Custo do write-path completo (validação → JPA persist) |
| `latencia_consultar_owner` | Trend | Custo de acesso com grafo owner→pets→visits |
| `latencia_criar_pet` | Trend | Custo de `savePet()` com CascadeType.ALL |
| `latencia_criar_visit` | Trend | Custo de inserção em tabela filha com FK |
| `latencia_listar_vets` | Trend | Custo de relação N:M (Vet→Specialty) EAGER |
| `latencia_health` | Trend | Baseline de latência do framework (sem lógica de negócio) |
| `taxa_erro` | Rate | Estabilidade global do sistema sob carga |
| `owners_criados_com_sucesso` | Counter | Throughput efetivo de owners criados |

---

## Protocolo de Coleta de Dados Experimentais

Para garantir validade metodológica, seguir o protocolo:

```
1. Verificar que a aplicação está estabilizada (uptime > 60s, JVM aquecida)
2. Executar o teste com saída redirecionada para arquivo
3. Capturar screenshot do dashboard Grafana ao final
4. Exportar CSV dos painéis de latência via API do Grafana
5. Registrar timestamp de início e fim do teste
6. Salvar todos os artefatos em docs/results/baseline/ ou docs/results/pos-refatoracao/
```

```bash
# Execução com saída persistida
docker compose -f infra/docker-compose.infra.yml \
  --profile testing run --rm k6 run /scripts/load-test.js \
  2>&1 | tee docs/results/baseline/k6-summary-$(date +%Y%m%dT%H%M).txt
```
