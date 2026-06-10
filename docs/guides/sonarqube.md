# Análise Estática com SonarQube

## Visão Geral Arquitetural

O SonarQube é uma plataforma de **inspeção contínua de qualidade de código** que realiza análise estática — examina o código-fonte sem executá-lo. Neste projeto, o SonarQube é responsável pela coleta de **métricas estáticas**, complementando a observabilidade dinâmica do Prometheus.

A análise estática detecta estruturas problemáticas (*code smells*) que a instrumentação em runtime não consegue identificar diretamente, como God Class (alta complexidade estrutural), Shotgun Surgery (lógica dispersa) e Data Class (ausência de comportamento).

---

## Configuração do Scanner

### Parâmetros essenciais (`sonar-project.properties`)

```properties
sonar.projectKey=spring-petclinic-rest
sonar.projectName=TCC — Spring PetClinic REST
sonar.projectVersion=baseline-1.0
sonar.host.url=http://localhost:9000
sonar.java.source=21
sonar.java.binaries=target/classes
sonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
```

### Tipos de token

| Tipo | Escopo | Uso recomendado |
|---|---|---|
| **User Token** | Projetos do usuário autenticado | Análise manual em desenvolvimento local |
| **Global Analysis Token** | Todos os projetos | Pipelines CI/CD (GitHub Actions, Jenkins) |
| **Project Analysis Token** | Projeto específico | Isolamento por projeto |

Para análise local e manual, o **User Token** é o mais adequado.

```bash
export SONAR_TOKEN=<user-token-gerado-na-ui>
mvn clean verify sonar:sonar -Dsonar.token=$SONAR_TOKEN
```

---

## Sistema de Ratings e Quality Gate

### Por que o projeto pode mostrar "A" e ainda ter code smells

O SonarQube utiliza um sistema de ratings (A/B/C/D/E) baseado em **Technical Debt Ratio (TDR)**:

| Rating | TDR |
|---|---|
| A | < 5% |
| B | 5% – 10% |
| C | 10% – 20% |
| D | 20% – 50% |
| E | > 50% |

O TDR é calculado como: `(tempo_para_remediar_débito / (LOC × fator_dia)) × 100`.

Um projeto pequeno (~1000 LOC) pode ter **dezenas de code smells** e ainda atingir rating "A" porque o tempo estimado para correção é baixo em valor absoluto. **O rating não indica ausência de problemas — apenas que o custo relativo de remediação é baixo.**

Para o TCC, os code smells são intencionais e relevantes independentemente do rating.

---

## Endurecimento do Quality Gate (Configuração Rigorosa)

### Estratégia: Quality Gate customizado para pesquisa

O Quality Gate padrão do SonarQube ("Sonar way") foi projetado para código de produção. Para fins de pesquisa, é necessário um Quality Gate que **falhe explicitamente** na presença dos code smells do TCC.

### Passo a passo via UI

```
1. Administration → Quality Gates → Create → nome: "TCC - Rigoroso"

2. Adicionar condições (Add Condition):

   Condição                              | Operador | Threshold
   --------------------------------------|----------|----------
   Code Smells                           | > 0      | 0
   Cognitive Complexity (total)          | > 100    | 100
   Cyclomatic Complexity (total)         | > 50     | 50
   Technical Debt                        | > 0min   | 0
   Duplicated Lines (%)                  | > 0%     | 0
   Coverage                             | < 0%     | 0

3. Settings → Default Quality Gate → selecionar "TCC - Rigoroso"

4. Projeto spring-petclinic-rest → Project Settings → Quality Gate → "TCC - Rigoroso"
```

> **Nota:** estas condições são intencionalmente estritas para evidenciar os code smells. Não representam thresholds de qualidade para código de produção.

---

## Mapeamento: Code Smells do TCC → Métricas SonarQube

### Code Smells detectados via Issues

| Code Smell | Regra SonarQube | Severidade |
|---|---|---|
| **Long Method** | `java:S3776` — Cognitive Complexity | Major |
| **Long Method** | `java:S1067` — Method too complex | Major |
| **God Class** | `java:S1200` — Too many dependencies | Major |
| **Shotgun Surgery** | `java:S4144` — Identical implementations | Minor |
| **Data Class** | `java:S1104` — Public fields | Minor |

**Navegação:** `Issues → Filtrar por Type = Code Smell → Filtrar por Component = <arquivo>`

### Métricas estáticas via Measures

**Navegação:** `spring-petclinic-rest → Measures`

| Métrica do TCC | Sigla | Caminho no SonarQube | Interpretação |
|---|---|---|---|
| Complexidade Ciclomática | CC / WMC | Measures → Complexity → Cyclomatic | Caminhos de decisão por método |
| Complexidade Cognitiva | — | Measures → Complexity → Cognitive | Dificuldade de compreensão |
| Acoplamento Eferente | Ce / Fan-Out | Issues → `S1200` | Dependências de saída por classe |
| Technical Debt Ratio | TDR | Measures → Maintainability → Debt Ratio | Percentual de dívida relativa |
| Lines of Code | LOC | Measures → Size → Lines | Tamanho da classe/método |
| Duplicações | — | Measures → Duplications | Proxy para Shotgun Surgery |

> **LCOM e CBO:** estas métricas não são nativas do SonarQube Community. Para calculá-las, é necessário o plugin **JDeodorant** (disponível para Eclipse/IntelliJ) ou ferramentas externas como **ckjm** (Chidamber & Kemerer Java Metrics).

---

## Extração de Métricas via API REST

Para documentação acadêmica formal, os dados devem ser extraídos programaticamente da API do SonarQube para garantir reprodutibilidade:

```bash
BASE="http://localhost:9000"
KEY="spring-petclinic-rest"

# Complexidade por arquivo (CC + CC cognitiva + LOC)
curl -u "$SONAR_TOKEN:" \
  "$BASE/api/measures/component_tree\
?component=$KEY\
&metricKeys=complexity,cognitive_complexity,ncloc,functions,sqale_debt_ratio\
&strategy=leaves&qualifiers=FIL" \
  | python3 -m json.tool > docs/results/baseline/sonar-complexity.json

# Code Smells com localização exata (arquivo + linha)
curl -u "$SONAR_TOKEN:" \
  "$BASE/api/issues/search\
?componentKeys=$KEY&types=CODE_SMELL&ps=500&statuses=OPEN" \
  | python3 -m json.tool > docs/results/baseline/sonar-issues.json

# Duplicações por arquivo (proxy para Shotgun Surgery)
curl -u "$SONAR_TOKEN:" \
  "$BASE/api/measures/component_tree\
?component=$KEY\
&metricKeys=duplicated_lines_density,duplicated_blocks\
&strategy=leaves&qualifiers=FIL" \
  | python3 -m json.tool > docs/results/baseline/sonar-duplications.json
```

---

## Protocolo de Análise Comparativa

```
FASE 1 — BASELINE
1. mvn clean verify sonar:sonar -Dsonar.token=$SONAR_TOKEN
2. Exportar métricas via API (comandos acima)
3. Registrar: CC total, LOC, TDR, nº de issues por tipo
4. Salvar em docs/results/baseline/

FASE 2 — REFATORAÇÃO
(aplicar Extract Class, Move Method, etc.)

FASE 3 — PÓS-REFATORAÇÃO
1. Repetir análise SonarQube
2. Exportar métricas
3. Calcular delta: ΔCC, ΔLOC, ΔTDR, Δissues
4. Apresentar redução como evidência da hipótese do TCC
```
