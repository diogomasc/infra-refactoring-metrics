#!/bin/bash
# ==============================================================================
# SCRIPT: run-benchmark.sh
# DESCRIÇÃO: Orquestra a execução de testes de carga (benchmarks) isolados para
#            coleta de métricas do TCC.
#
# FLUXO DE CADA RODADA (RUN):
#   1. Nuke   : Destrói processos residuais (Spring, Docker, portas ocupadas).
#   2. Infra  : Sobe a stack de observabilidade (Prometheus + Grafana + Loki).
#   3. App    : Inicia a API Spring Boot e aguarda o warm-up da JVM.
#   4. Teste  : Executa o script do K6 e exporta os resultados (CSV/JSON).
#   5. Coleta : Aguarda o último ciclo de scraping (Prometheus) antes de encerrar.
#
# USO:
#   bash run-benchmark.sh [label_da_fase] [numero_de_rodadas]
#
# EXEMPLOS:
#   bash run-benchmark.sh baseline 5
#   bash run-benchmark.sh original-fork 3
#
# PRÉ-REQUISITOS: docker, docker compose (v2), java (17+), curl, mvnw, fuser
# ==============================================================================

# Ativa o modo de segurança do Bash:
# -e: Sai imediatamente se um comando falhar.
# -u: Trata variáveis não definidas como erro.
# -o pipefail: O status de um pipeline é o do último comando que falhar.
set -euo pipefail

# ── 1. Parâmetros e Variáveis de Sessão ───────────────────────────────────────

readonly LABEL="${1:-baseline}"
readonly N_RUNS="${2:-5}"
readonly SESSION_TS="$(date +%Y%m%d-%H%M%S)" # Timestamp único para todo o lote

# ── 2. Caminhos de Diretórios e Arquivos ──────────────────────────────────────

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly INFRA_DIR="$PROJECT_ROOT/infra"
readonly APP_DIR="$PROJECT_ROOT/api"
readonly LOG_DIR="$INFRA_DIR/results"

readonly INFRA_COMPOSE="$INFRA_DIR/docker-compose.yml"
readonly K6_SCRIPT="$INFRA_DIR/k6/load-test.js"

# ── 3. Configurações de Tempo e Timeout (em segundos) ─────────────────────────

readonly PROM_TIMEOUT=30           # Limite de espera para o Prometheus ficar online
readonly SPRING_TIMEOUT=120        # Limite de espera para o Spring Boot iniciar
readonly WARMUP_EXTRA_SECS=15      # Tempo extra pós-inicialização para a JIT compilar hot-paths
readonly PROMETHEUS_SCRAPE_WAIT=20 # Tempo para garantir que as últimas métricas sejam coletadas
readonly COOLDOWN_BETWEEN_RUNS=10  # Pausa entre rodadas para dissipação térmica/recursos

# ── 4. Variáveis de Estado (Mutáveis) ─────────────────────────────────────────

SPRING_PID=""

# ── 5. Validação de Pré-requisitos ────────────────────────────────────────────

for cmd in docker java curl fuser; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERRO: Dependência '$cmd' não encontrada no PATH." >&2
    exit 1
  fi
done

if ! docker compose version &>/dev/null; then
  echo "ERRO: O 'docker compose' (v2) não está disponível." >&2
  exit 1
fi

[[ ! -f "$INFRA_COMPOSE" ]] && { echo "ERRO: Arquivo docker-compose não encontrado: $INFRA_COMPOSE" >&2; exit 1; }
[[ ! -f "$K6_SCRIPT"     ]] && { echo "ERRO: Script do K6 não encontrado: $K6_SCRIPT" >&2; exit 1; }

mkdir -p "$LOG_DIR"

# ==============================================================================
# FUNÇÕES UTILITÁRIAS
# ==============================================================================

log() {
  echo "[$(date +%T)] $*"
}

# Aguarda um endpoint HTTP retornar status de sucesso (2xx)
wait_for_url() {
  local url="$1" timeout="$2" label="$3"
  echo -n "[$(date +%T)]   Aguardando $label"

  for i in $(seq 1 "$timeout"); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo " OK (${i}s)"
      return 0
    fi
    sleep 1
    echo -n "."
  done

  echo " FALHA (timeout ${timeout}s)"
  return 1
}

# ==============================================================================
# FUNÇÕES DE INFRAESTRUTURA E LIFECYCLE
# ==============================================================================

# Encerra o processo do Spring Boot graciosamente
cleanup_spring() {
  if [[ -n "$SPRING_PID" ]] && kill -0 "$SPRING_PID" 2>/dev/null; then
    log "  Encerrando Spring Boot (PID: $SPRING_PID)..."
    kill "$SPRING_PID" 2>/dev/null || true
    wait "$SPRING_PID" 2>/dev/null || true
    SPRING_PID=""
  fi
}

# Restaura o ambiente para um estado limpo, matando processos e liberando portas
nuke_environment() {
  log "  Verificando processos ativos do Spring Boot..."
  cleanup_spring

  log "  Desmontando stack Docker e limpando volumes associados..."
  docker compose -f "$INFRA_COMPOSE" down -v --remove-orphans 2>/dev/null || true

  # Remove containers K6 que possam ter travado em execuções anteriores
  local k6_orphans
  k6_orphans=$(docker ps -q --filter "ancestor=grafana/k6:latest" 2>/dev/null || true)
  if [[ -n "$k6_orphans" ]]; then
    log "  Limpando containers K6 órfãos: $k6_orphans"
    docker rm -f $k6_orphans 2>/dev/null || true
  fi

  # Garante que a porta da API está livre para a próxima rodada
  if ss -tlnp 2>/dev/null | grep -q ':9966 '; then
    log "  AVISO: Porta 9966 em uso. Forçando liberação..."
    fuser -k 9966/tcp 2>/dev/null || true
    sleep 2
  fi

  # Garante que a porta do Prometheus está livre
  if ss -tlnp 2>/dev/null | grep -q ':9090 '; then
    log "  AVISO: Porta 9090 em uso. Forçando liberação..."
    fuser -k 9090/tcp 2>/dev/null || true
    sleep 1
  fi

  log "  Ambiente higienizado com sucesso."
}

# Trap executado no encerramento do script (sucesso ou falha)
cleanup_all() {
  local exit_code=$?
  echo ""
  log "Executando limpeza final de segurança..."
  cleanup_spring
  docker compose -f "$INFRA_COMPOSE" down -v --remove-orphans 2>/dev/null || true
  docker rm -f $(docker ps -q --filter "ancestor=grafana/k6:latest" 2>/dev/null) 2>/dev/null || true
  log "Script finalizado com código de saída: $exit_code"
  exit "$exit_code"
}
trap cleanup_all EXIT

# ==============================================================================
# ORQUESTRAÇÃO DOS SERVIÇOS
# ==============================================================================

start_observability_stack() {
  log "Iniciando infraestrutura de observabilidade (Prometheus + Grafana)..."
  docker compose -f "$INFRA_COMPOSE" up -d
  wait_for_url "http://localhost:9090/-/healthy" "$PROM_TIMEOUT" "Prometheus" \
    || { log "ERRO: Prometheus não respondeu a tempo."; exit 1; }
}

start_spring() {
  local run_log="$1"
  log "Iniciando API Spring Boot (Profile: h2, spring-data-jpa)..."

  cd "$APP_DIR"

  # Força a configuração via variáveis de ambiente para garantir consistência
  # independente das configurações salvas no código-fonte atual (application.properties).
  export SERVER_PORT=9966
  export SERVER_SERVLET_CONTEXT_PATH=/petclinic/

  ./mvnw spring-boot:run \
    -Dspring-boot.run.profiles=h2,spring-data-jpa \
    -Dspring-boot.run.jvmArguments="-Xms512m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200" \
    > "$run_log" 2>&1 &

  SPRING_PID=$!
  cd "$PROJECT_ROOT"

  # Polling do endpoint de health check do Spring
  echo -n "[$(date +%T)]   Aguardando inicialização da API (PID: $SPRING_PID)"
  for i in $(seq 1 "$SPRING_TIMEOUT"); do
    if curl -sf http://localhost:9966/petclinic/actuator/health >/dev/null 2>&1; then
      echo " OK (${i}s)"
      break
    fi

    # Se o processo morrer antes do timeout, interrompe imediatamente
    if ! kill -0 "$SPRING_PID" 2>/dev/null; then
      echo " FALHA (Processo interrompido de forma inesperada)"
      log "ERRO: O processo Spring Boot morreu durante a inicialização. Verifique os logs: $run_log"
      exit 1
    fi

    if [[ $i -eq "$SPRING_TIMEOUT" ]]; then
      echo " FALHA (Timeout atingido: ${SPRING_TIMEOUT}s)"
      log "ERRO: Spring Boot não ficou 'healthy' a tempo. Verifique os logs: $run_log"
      exit 1
    fi

    sleep 1
    echo -n "."
  done

  # Aguarda a JIT compilar as rotas mais usadas e estabilizar o pool de conexões
  log "  Iniciando Warm-up da JVM: Aguardando ${WARMUP_EXTRA_SECS}s adicionais..."
  sleep "$WARMUP_EXTRA_SECS"
}

run_k6() {
  local run_num="$1"
  local csv_file="$LOG_DIR/k6-metrics-${LABEL}_run_${run_num}-${SESSION_TS}.csv"
  local summary_file="$LOG_DIR/k6-summary-${LABEL}_run_${run_num}-${SESSION_TS}.json"
  local run_log="$LOG_DIR/benchmark-${LABEL}_run_${run_num}-${SESSION_TS}.log"

  log "  Exportando CSV     : $(basename "$csv_file")"
  log "  Exportando Summary : $(basename "$summary_file")"
  log "  ⏱ O teste de carga está em execução. Acompanhe o progresso abaixo:"

  # O uso do 'script -qfc' engana o K6 fazendo-o achar que está rodando em um TTY interativo.
  # Isso permite que a barra de progresso visual seja exibida no terminal, enquanto
  # garante que o log real seja salvo no arquivo "$run_log".
  script -qfc "docker run --rm --network host \
    --user $(id -u):$(id -g) \
    -e HOME=/tmp \
    -v $INFRA_DIR/k6:/scripts:ro \
    -v $LOG_DIR:/results \
    grafana/k6:latest run \
      --no-usage-report \
      --out csv=/results/$(basename "$csv_file") \
      /scripts/load-test.js" "$run_log"

  local k6_exit=$?

  # O K6 salva o resultado padrão como summary.json. Precisamos renomeá-lo
  # para incluir o label e o run_number atual e evitar sobrescritas.
  if [[ -f "$LOG_DIR/summary.json" ]]; then
    mv "$LOG_DIR/summary.json" "$summary_file"
    log "  ✅ Relatório Summary JSON salvo com sucesso: $(basename "$summary_file")"
  else
    log "  ⚠ AVISO: summary.json não encontrado. O K6 pode ter abortado precocemente."
  fi

  log "  K6 finalizado com código: ${k6_exit} (0 = Sucesso | 99 = Thresholds violados)"
  echo "$k6_exit"
}

# ==============================================================================
# EXECUÇÃO PRINCIPAL
# ==============================================================================

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
printf  "║  TCC Benchmark Runner  %-40s║\n" ""
printf  "║  Fase Analisada : %-43s║\n" "$LABEL"
printf  "║  Total de Runs  : %-43s║\n" "$N_RUNS"
printf  "║  ID da Sessão   : %-43s║\n" "$SESSION_TS"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

K6_EXIT_LAST=0

for RUN in $(seq 1 "$N_RUNS"); do
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "RODADA ${RUN}/${N_RUNS} — Fase: ${LABEL}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  RUN_LOG="$LOG_DIR/benchmark-${LABEL}_run_${RUN}-${SESSION_TS}.log"

  log "[1/4] Preparando ambiente isolado (Nuke)..."
  nuke_environment

  log "[2/4] Configurando stack de observabilidade..."
  start_observability_stack

  log "[3/4] Inicializando aplicação alvo (Spring Boot)..."
  start_spring "$RUN_LOG"

  log "[4/4] Disparando teste de carga (K6)..."
  K6_EXIT_LAST=$(run_k6 "$RUN")

  # É essencial aguardar o último ciclo para não perder métricas do fim do teste
  log "  Aguardando o último ciclo de coleta do Prometheus (${PROMETHEUS_SCRAPE_WAIT}s)..."
  sleep "$PROMETHEUS_SCRAPE_WAIT"

  # Derruba o Spring prematuramente para garantir que o banco H2 (em memória) seja resetado
  cleanup_spring

  if [[ $RUN -lt $N_RUNS ]]; then
    log "  Resfriamento do ambiente para a próxima rodada (${COOLDOWN_BETWEEN_RUNS}s)..."
    sleep "$COOLDOWN_BETWEEN_RUNS"
  fi
done

# ==============================================================================
# RELATÓRIO FINAL E PRÓXIMOS PASSOS
# ==============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Sessão '${LABEL}' concluída com sucesso (${N_RUNS} rodada(s) executada(s))."
echo "  Código de saída da última execução do K6: ${K6_EXIT_LAST}"
echo ""
echo "  Artefatos gerados em: ${LOG_DIR}/"
echo ""

# Lista os arquivos gerados formatados para fácil visualização
ls -1 "$LOG_DIR"/k6-summary-${LABEL}_run_*-${SESSION_TS}.json 2>/dev/null \
  | while read -r f; do echo "    [JSON] $(basename "$f")"; done
ls -1 "$LOG_DIR"/k6-metrics-${LABEL}_run_*-${SESSION_TS}.csv 2>/dev/null \
  | while read -r f; do echo "    [CSV]  $(basename "$f")"; done

echo ""
echo "  Próximo passo sugerido para análise:"
echo "    uv run --with pandas --with scipy python3 \\"
echo "      infra/scripts/post-process.py ${LABEL} ${SESSION_TS}"
echo "═══════════════════════════════════════════════════════════════════"

exit "$K6_EXIT_LAST"
