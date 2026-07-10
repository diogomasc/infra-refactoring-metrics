#!/bin/bash
# ── run-benchmark.sh ─────────────────────────────────────────────────────────
# Executa um ciclo completo de benchmark isolado para o TCC.
#
# Garante reprodutibilidade entre execuções através de:
#   1. Limpeza total da infra (volumes do Prometheus inclusos)
#   2. Health-checks com retry para Prometheus e Spring Boot
#   3. K6 com --network host (zero NAT overhead nos percentis)
#   4. Exportação automática: CSV granular (--out csv) + JSON summary (handleSummary)
#   5. Trap EXIT para cleanup robusto do processo Spring Boot
#
# Uso:
#   bash infra/scripts/run-benchmark.sh [label]
#   bash infra/scripts/run-benchmark.sh baseline
#   bash infra/scripts/run-benchmark.sh pos-refatoracao
#
# Pré-requisitos:
#   - Docker e Docker Compose v2 instalados
#   - Java 17+ e Maven (via ./mvnw) disponíveis
#   - Portas 9090 (Prometheus), 3000 (Grafana) e 9966 (Spring Boot) livres
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configuração ─────────────────────────────────────────────────────────────
LABEL="${1:-baseline}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPRING_PID=""
INFRA_DIR="$PROJECT_ROOT/infra"
APP_DIR="$PROJECT_ROOT/api"
INFRA_COMPOSE="$INFRA_DIR/docker-compose.yml"
K6_SCRIPT="$INFRA_DIR/k6/load-test.js"
LOG_DIR="$INFRA_DIR/results"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/benchmark-${LABEL}-${TIMESTAMP}.log"

# ── Validação de pré-requisitos ──────────────────────────────────────────────
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

if [[ ! -f "$INFRA_COMPOSE" ]]; then
  echo "ERRO: Arquivo compose não encontrado: $INFRA_COMPOSE" >&2
  exit 1
fi

if [[ ! -f "$K6_SCRIPT" ]]; then
  echo "ERRO: Script K6 não encontrado: $K6_SCRIPT" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

# ── Função de limpeza (trap EXIT) ────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  echo ""
  echo "[$(date +%T)] Executando cleanup..."

  if [[ -n "$SPRING_PID" ]] && kill -0 "$SPRING_PID" 2>/dev/null; then
    echo "[$(date +%T)]   Parando Spring Boot (PID: $SPRING_PID)..."
    kill "$SPRING_PID" 2>/dev/null || true
    wait "$SPRING_PID" 2>/dev/null || true
  fi

  echo "[$(date +%T)] Cleanup concluído."
  exit "$exit_code"
}
trap cleanup EXIT

# ── Banner ───────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  TCC Benchmark Runner                                      ║"
echo "║  Fase: ${LABEL}                                            ║"
echo "║  Timestamp: ${TIMESTAMP}                                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Garantir ambiente limpo ───────────────────────────────────────────────
echo "[$(date +%T)] [1/5] Garantindo ambiente limpo..."
echo "[$(date +%T)]   docker compose down -v (limpando volumes Prometheus)..."
docker compose -f "$INFRA_COMPOSE" down -v --remove-orphans 2>/dev/null || true

# Verificar se a porta 9966 já está em uso
if ss -tlnp 2>/dev/null | grep -q ':9966 '; then
  echo "AVISO: Porta 9966 já em uso. Matando processo..." >&2
  fuser -k 9966/tcp 2>/dev/null || true
  sleep 2
fi

# ── 2. Subir stack de observabilidade ────────────────────────────────────────
echo "[$(date +%T)] [2/5] Subindo Prometheus + Grafana..."
docker compose -f "$INFRA_COMPOSE" up -d

echo -n "[$(date +%T)]   Aguardando Prometheus"
PROM_READY=false
for i in $(seq 1 30); do
  if curl -sf http://localhost:9090/-/healthy > /dev/null 2>&1; then
    echo " OK (${i}s)"
    PROM_READY=true
    break
  fi
  sleep 1
  echo -n "."
done

if [[ "$PROM_READY" != "true" ]]; then
  echo " FALHA (timeout 30s)"
  echo "ERRO: Prometheus não ficou healthy em 30s." >&2
  exit 1
fi

# ── 3. Iniciar Spring Boot ──────────────────────────────────────────────────
echo "[$(date +%T)] [3/5] Iniciando Spring Boot (profile: h2,spring-data-jpa)..."
cd "$APP_DIR"
./mvnw spring-boot:run \
  -Dspring-boot.run.profiles=h2,spring-data-jpa \
  -Dspring-boot.run.jvmArguments="-Xms256m -Xmx512m" \
  > "$LOG_FILE" 2>&1 &
SPRING_PID=$!
cd "$PROJECT_ROOT"

echo -n "[$(date +%T)]   Aguardando Spring Boot (PID: $SPRING_PID)"
SPRING_READY=false
for i in $(seq 1 120); do
  if curl -sf http://localhost:9966/petclinic/actuator/health > /dev/null 2>&1; then
    echo " OK (${i}s)"
    SPRING_READY=true
    break
  fi
  if ! kill -0 "$SPRING_PID" 2>/dev/null; then
    echo " FALHA (processo morreu)"
    echo "ERRO: Spring Boot terminou inesperadamente. Verifique: $LOG_FILE" >&2
    exit 1
  fi
  sleep 1
  echo -n "."
done

if [[ "$SPRING_READY" != "true" ]]; then
  echo " FALHA (timeout 120s)"
  echo "ERRO: Spring Boot não respondeu em 120s. Log: $LOG_FILE" >&2
  exit 1
fi

# Aguardar estabilização JVM (pool de conexões, class loading)
echo "[$(date +%T)]   Aguardando estabilização da JVM (5s)..."
sleep 5

# ── 4. Executar K6 com --network host ───────────────────────────────────────
CSV_FILE="$LOG_DIR/k6-metrics-${LABEL}-${TIMESTAMP}.csv"
SUMMARY_FILE="$LOG_DIR/k6-summary-${LABEL}-${TIMESTAMP}.json"

echo "[$(date +%T)] [4/5] Executando K6 (--network host, zero NAT overhead)..."
echo "[$(date +%T)]   Script: $K6_SCRIPT"
echo "[$(date +%T)]   CSV granular: $CSV_FILE"
echo "[$(date +%T)]   JSON summary: $SUMMARY_FILE"
echo ""

docker run --rm --network host \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$INFRA_DIR/k6:/scripts:ro" \
  -v "$LOG_DIR:/results" \
  grafana/k6:latest run \
    --out "csv=/results/k6-metrics-${LABEL}-${TIMESTAMP}.csv" \
    /scripts/load-test.js \
  2>&1 | tee -a "$LOG_FILE"

K6_EXIT=${PIPESTATUS[0]}

# handleSummary() grava /results/summary.json — renomear com label e timestamp
if [[ -f "$LOG_DIR/summary.json" ]]; then
  mv "$LOG_DIR/summary.json" "$SUMMARY_FILE"
  echo "[$(date +%T)]   Summary JSON salvo: $SUMMARY_FILE"
fi

echo ""
echo "[$(date +%T)]   K6 exit code: ${K6_EXIT}"

# ── 5. Aguardar último scrape do Prometheus ──────────────────────────────────
echo "[$(date +%T)] [5/5] Aguardando último scrape do Prometheus (20s)..."
sleep 20

# ── Resultado ────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Benchmark '${LABEL}' finalizado."
echo "  K6 exit code: ${K6_EXIT}"
echo "    (0 = thresholds OK | 99 = thresholds violados)"
echo ""
echo "  Artefatos gerados:"
echo "    Log:          ${LOG_FILE}"
echo "    CSV granular: ${CSV_FILE}"
echo "    JSON summary: ${SUMMARY_FILE}"
echo "    Resultados:   ${LOG_DIR}/"
echo "═══════════════════════════════════════════════════════════════"

exit "$K6_EXIT"
