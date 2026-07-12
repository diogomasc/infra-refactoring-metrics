#!/bin/bash
# ── run-benchmark.sh ──────────────────────────────────────────────────────────
# Executa N rodadas consecutivas de benchmark isolado para o TCC.
#
# Cada rodada:
#   1. Limpa TUDO: Spring Boot, containers Docker (K6, infra), volumes, portas
#   2. Sobe stack de observabilidade (Prometheus + Grafana + Loki)
#   3. Sobe Spring Boot com warm-up JVM configurável
#   4. Roda K6 e salva CSV + JSON com sufixo _run_N
#   5. Aguarda último scrape antes de encerrar
#
# Uso:
#   bash infra/scripts/run-benchmark.sh [label] [n_runs]
#   bash infra/scripts/run-benchmark.sh baseline 5
#   bash infra/scripts/run-benchmark.sh pos-refatoracao 5
#
# Pré-requisitos: docker, docker compose v2, java 17+, curl, mvnw
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Parâmetros ────────────────────────────────────────────────────────────────
LABEL="${1:-baseline}"
N_RUNS="${2:-5}"

# ── Caminhos ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA_DIR="$PROJECT_ROOT/infra"
APP_DIR="$PROJECT_ROOT/api"
INFRA_COMPOSE="$INFRA_DIR/docker-compose.yml"
K6_SCRIPT="$INFRA_DIR/k6/load-test.js"
LOG_DIR="$INFRA_DIR/results"
SESSION_TS="$(date +%Y%m%d-%H%M%S)"   # timestamp da sessão (igual para todas as runs)

# ── Configurações de tempo (ajuste conforme o hardware) ───────────────────────
WARMUP_EXTRA_SECS=15     # aguarda após /actuator/health estar OK (JIT + pool)
PROMETHEUS_SCRAPE_WAIT=20 # aguarda ultimo scrape antes de derrubar stack
SPRING_TIMEOUT=120        # timeout para Spring Boot subir
PROM_TIMEOUT=30           # timeout para Prometheus ficar healthy
COOLDOWN_BETWEEN_RUNS=10  # pausa entre rodadas para evitar estado residual

# ── Variáveis de estado ───────────────────────────────────────────────────────
SPRING_PID=""
CURRENT_RUN=0

# ── Validação de pré-requisitos ───────────────────────────────────────────────
for cmd in docker java curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERRO: '$cmd' não encontrado no PATH." >&2
    exit 1
  fi
done

if ! docker compose version &>/dev/null; then
  echo "ERRO: 'docker compose' (v2) não disponível." >&2
  exit 1
fi

[[ ! -f "$INFRA_COMPOSE" ]] && { echo "ERRO: compose não encontrado: $INFRA_COMPOSE" >&2; exit 1; }
[[ ! -f "$K6_SCRIPT"     ]] && { echo "ERRO: K6 script não encontrado: $K6_SCRIPT"  >&2; exit 1; }

mkdir -p "$LOG_DIR"

# ── Funções utilitárias ───────────────────────────────────────────────────────
log() { echo "[$(date +%T)] $*"; }

cleanup_spring() {
  if [[ -n "$SPRING_PID" ]] && kill -0 "$SPRING_PID" 2>/dev/null; then
    log "  Parando Spring Boot (PID: $SPRING_PID)..."
    kill "$SPRING_PID" 2>/dev/null || true
    wait "$SPRING_PID" 2>/dev/null || true
    SPRING_PID=""
  fi
}

# Limpa TUDO: Spring Boot, Docker containers (k6, infra), volumes, portas
nuke_environment() {
  log "  Parando Spring Boot (se ativo)..."
  cleanup_spring

  log "  Derrubando stack Docker + volumes..."
  docker compose -f "$INFRA_COMPOSE" down -v --remove-orphans 2>/dev/null || true

  # Mata containers K6 órfãos (de runs anteriores que podem ter ficado pendurados)
  local k6_orphans
  k6_orphans=$(docker ps -q --filter "ancestor=grafana/k6:latest" 2>/dev/null || true)
  if [[ -n "$k6_orphans" ]]; then
    log "  Matando containers K6 órfãos: $k6_orphans"
    docker rm -f $k6_orphans 2>/dev/null || true
  fi

  # Garante porta 9966 livre (Spring Boot anterior ou outro processo)
  if ss -tlnp 2>/dev/null | grep -q ':9966 '; then
    log "  AVISO: Porta 9966 ocupada — liberando..."
    fuser -k 9966/tcp 2>/dev/null || true
    sleep 2
  fi

  # Garante porta 9090 livre (Prometheus anterior)
  if ss -tlnp 2>/dev/null | grep -q ':9090 '; then
    log "  AVISO: Porta 9090 ocupada — liberando..."
    fuser -k 9090/tcp 2>/dev/null || true
    sleep 1
  fi

  log "  Ambiente limpo."
}

cleanup_all() {
  local exit_code=$?
  echo ""
  log "Executando cleanup final..."
  cleanup_spring
  docker compose -f "$INFRA_COMPOSE" down -v --remove-orphans 2>/dev/null || true
  # Remove containers K6 pendurados
  docker rm -f $(docker ps -q --filter "ancestor=grafana/k6:latest" 2>/dev/null) 2>/dev/null || true
  log "Cleanup concluído (exit=$exit_code)."
  exit "$exit_code"
}
trap cleanup_all EXIT

wait_for_url() {
  local url="$1" timeout="$2" label="$3"
  echo -n "[$(date +%T)]   Aguardando $label"
  for i in $(seq 1 "$timeout"); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo " OK (${i}s)"; return 0
    fi
    sleep 1; echo -n "."
  done
  echo " FALHA (timeout ${timeout}s)"; return 1
}

start_observability_stack() {
  log "Subindo Prometheus + Grafana..."
  docker compose -f "$INFRA_COMPOSE" up -d
  wait_for_url "http://localhost:9090/-/healthy" "$PROM_TIMEOUT" "Prometheus" \
    || { log "ERRO: Prometheus não respondeu."; exit 1; }
}

start_spring() {
  local run_log="$1"
  log "Iniciando Spring Boot (profile: h2,spring-data-jpa)..."
  cd "$APP_DIR"
  ./mvnw spring-boot:run \
    -Dspring-boot.run.profiles=h2,spring-data-jpa \
    -Dspring-boot.run.jvmArguments="-Xms512m -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200" \
    > "$run_log" 2>&1 &
  SPRING_PID=$!
  cd "$PROJECT_ROOT"

  # Aguarda /actuator/health
  echo -n "[$(date +%T)]   Aguardando Spring Boot (PID: $SPRING_PID)"
  for i in $(seq 1 "$SPRING_TIMEOUT"); do
    if curl -sf http://localhost:9966/petclinic/actuator/health >/dev/null 2>&1; then
      echo " OK (${i}s)"; break
    fi
    if ! kill -0 "$SPRING_PID" 2>/dev/null; then
      echo " FALHA (processo morreu)"
      log "ERRO: Spring Boot terminou. Log: $run_log"; exit 1
    fi
    if [[ $i -eq "$SPRING_TIMEOUT" ]]; then
      echo " FALHA (timeout ${SPRING_TIMEOUT}s)"
      log "ERRO: Spring Boot não respondeu. Log: $run_log"; exit 1
    fi
    sleep 1; echo -n "."
  done

  # Warm-up extra: aguarda JIT compilar os hot paths
  log "  Warm-up JVM: aguardando ${WARMUP_EXTRA_SECS}s adicionais (JIT + pool de conexões)..."
  sleep "$WARMUP_EXTRA_SECS"
}

run_k6() {
  local run_num="$1"
  local csv_file="$LOG_DIR/k6-metrics-${LABEL}_run_${run_num}-${SESSION_TS}.csv"
  local summary_file="$LOG_DIR/k6-summary-${LABEL}_run_${run_num}-${SESSION_TS}.json"
  local run_log="$LOG_DIR/benchmark-${LABEL}_run_${run_num}-${SESSION_TS}.log"

  log "  CSV     : $(basename "$csv_file")"
  log "  Summary : $(basename "$summary_file")"
  log "  ⏱  O teste de carga leva ~15min. Progresso abaixo:"

  # 'script -qfc' preserva o pseudo-TTY para o K6 mostrar a barra de
  # progresso em tempo real (cores, percentuais, ETA), enquanto captura
  # toda a saída no log file. Sem TTY, o K6 suprime o output interativo.
  #   -q  = silencia mensagens "Script started/done"
  #   -f  = flush a cada write (output em tempo real)
  #   -c  = executa o comando fornecido
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

  # handleSummary() grava /results/summary.json — renomear para sufixo dinâmico
  if [[ -f "$LOG_DIR/summary.json" ]]; then
    mv "$LOG_DIR/summary.json" "$summary_file"
    log "  ✅ Summary JSON salvo: $(basename "$summary_file")"
  else
    log "  ⚠  summary.json não encontrado (K6 pode ter falhado antes do handleSummary)"
  fi

  log "  K6 exit code: ${k6_exit} (0=OK | 99=thresholds violados)"
  echo "$k6_exit"
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
printf  "║  TCC Benchmark Runner  %-40s║\n" ""
printf  "║  Fase    : %-51s║\n" "$LABEL"
printf  "║  Runs    : %-51s║\n" "$N_RUNS"
printf  "║  Sessão  : %-51s║\n" "$SESSION_TS"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Loop de N rodadas ─────────────────────────────────────────────────────────
K6_EXIT_LAST=0

for RUN in $(seq 1 "$N_RUNS"); do
  CURRENT_RUN=$RUN
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "RODADA ${RUN}/${N_RUNS} — fase: ${LABEL}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  RUN_LOG="$LOG_DIR/benchmark-${LABEL}_run_${RUN}-${SESSION_TS}.log"

  # 1. NUKE: limpa TUDO — Spring, Docker, volumes, portas
  log "[step 1/4] Clean state (nuke completo)..."
  nuke_environment

  # 2. Sobe observabilidade
  log "[step 2/4] Stack de observabilidade..."
  start_observability_stack

  # 3. Sobe Spring Boot com warm-up
  log "[step 3/4] Spring Boot + warm-up JVM..."
  start_spring "$RUN_LOG"

  # 4. Executa K6
  log "[step 4/4] Executando K6..."
  K6_EXIT_LAST=$(run_k6 "$RUN")

  # Aguarda último scrape do Prometheus antes de derrubar
  log "  Aguardando último scrape Prometheus (${PROMETHEUS_SCRAPE_WAIT}s)..."
  sleep "$PROMETHEUS_SCRAPE_WAIT"

  # Para Spring (banco H2 zerado no próximo restart)
  cleanup_spring

  if [[ $RUN -lt $N_RUNS ]]; then
    log "  Cooldown entre rodadas (${COOLDOWN_BETWEEN_RUNS}s)..."
    sleep "$COOLDOWN_BETWEEN_RUNS"
  fi
done

# ── Relatório final ───────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Sessão '${LABEL}' concluída — ${N_RUNS} rodada(s)."
echo "  Último K6 exit: ${K6_EXIT_LAST} (0=OK | 99=thresholds violados)"
echo ""
echo "  Artefatos em: ${LOG_DIR}/"
echo ""
ls -1 "$LOG_DIR"/k6-summary-${LABEL}_run_*-${SESSION_TS}.json 2>/dev/null \
  | while read -r f; do echo "    JSON: $(basename "$f")"; done
ls -1 "$LOG_DIR"/k6-metrics-${LABEL}_run_*-${SESSION_TS}.csv 2>/dev/null \
  | while read -r f; do echo "    CSV : $(basename "$f")"; done
echo ""
echo "  Próximo passo:"
echo "    uv run --with pandas --with scipy python3 \\"
echo "      infra/scripts/post-process.py ${LABEL} ${SESSION_TS}"
echo "═══════════════════════════════════════════════════════════════════"

exit "$K6_EXIT_LAST"
