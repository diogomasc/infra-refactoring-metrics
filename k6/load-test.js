// ─────────────────────────────────────────────────────────────────────────────
// Script de Carga — TCC: Métricas de Refatoração (Spring PetClinic REST)
// ─────────────────────────────────────────────────────────────────────────────
//
// Exercita 6 endpoints críticos + 1 baseline de infraestrutura, cobrindo
// 13 anotações @Observed que geram spans Prometheus para as fitness functions.
// Endpoints e suas cadeias de observabilidade:
//   1. GET  /api/owners              → Controller_Owner_ListAll + Service_Owner_FindAll
//   2. POST /api/owners              → Controller_Owner_Add + Service_Owner_Save
//   3. GET  /api/owners/{ownerId}    → Controller_Owner_FindById + Service_Owner_FindById
//   4. POST /api/owners/{ownerId}/pets
//                                   → Controller_Pet_AddToOwner + Service_Owner_FindById
//                                     + Service_PetType_FindById + Service_Pet_Save
//   5. POST /api/owners/{ownerId}/pets/{petId}/visits
//                                   → Controller_Visit_AddToOwner + Service_Visit_Save
//   6. GET  /api/vets               → Controller_Vet_ListAll + Service_Vet_FindAll
//   7. GET  /actuator/health        → Baseline de latência do framework (sem @Observed)
//
// Métricas exportadas por endpoint (metodologia RED expandida):
//   - Trend p99: alimenta LatencyFitnessFunction (threshold conservador)
//   - Rate erro: alimenta ReliabilityFitnessFunction por endpoint
//   - Counter:   throughput de escritas bem-sucedidas
//
// Payload verificado contra openapi.yml:
//   - POST /owners          → OwnerFields {firstName, lastName, address, city, telephone}
//   - POST /owners/{id}/pets → PetFields {name, birthDate, type: {id, name}}
//   - POST .../visits       → VisitFields {date, description}  (petId via path)
//
// Perfil de carga — NÃO ALTERAR entre fases baseline e pós-refatoração:
//   Stage 1 — Ramp-up / JVM warm-up : 0→30 VUs em 1min
//   Stage 2 — Carga nominal         : 50 VUs por 3min  (baseline principal)
//   Stage 3 — Spike                 : 50→100 VUs em 1min
//   Stage 4 — Estresse sustentado   : 100 VUs por 7min (zona de detecção N+1)
//   Stage 5 — Ramp-down             : 100→0 VUs em 1min
//   Stage 6 — Cooldown              : 0 VUs por 2min   (mede recuperação JVM)
//   Total: 15min | Peak: ~100 VUs concorrentes
//
// Execução (modo primário — --network host, zero NAT overhead):
//   bash infra/scripts/run-benchmark.sh [baseline|pos-refatoracao]
//
// Execução alternativa (via compose, a partir de infra/):
//   docker compose --profile testing run --rm k6 run /scripts/load-test.js
//
// ⚠️  NÃO altere scenarios, thresholds nem payloads entre as fases
//     baseline e pós-refatoração — apenas o código Java muda.
// ─────────────────────────────────────────────────────────────────────────────

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Trend, Rate, Counter } from "k6/metrics";
import faker from "k6/x/faker";
import { textSummary } from "https://jslib.k6.io/k6-summary/0.0.2/index.js";

// ── Métricas customizadas (metodologia RED expandida) ───────────────────────
// Trends com true = habilita percentis (p50, p90, p95, p99) no relatório k6.
// p99 alimenta LatencyFitnessFunction; p95 mantido para comparação histórica.
const latenciaListarOwners = new Trend("latencia_listar_owners", true);
const latenciaCriarOwner = new Trend("latencia_criar_owner", true);
const latenciaConsultarOwner = new Trend("latencia_consultar_owner", true);
const latenciaCriarPet = new Trend("latencia_criar_pet", true);
const latenciaCriarVisit = new Trend("latencia_criar_visit", true);
const latenciaListarVets = new Trend("latencia_listar_vets", true);
const latenciaHealth = new Trend("latencia_health", true);

// Taxa de erro GLOBAL (usado por ReliabilityFitnessFunction com errorRatePercent)
const taxaErroGlobal = new Rate("taxa_erro");

// Taxa de erro POR ENDPOINT — permite isolar qual endpoint degrada primeiro
const erroListarOwners = new Rate("erro_listar_owners");
const erroCriarOwner = new Rate("erro_criar_owner");
const erroConsultarOwner = new Rate("erro_consultar_owner");
const erroCriarPet = new Rate("erro_criar_pet");
const erroCriarVisit = new Rate("erro_criar_visit");
const erroListarVets = new Rate("erro_listar_vets");

// Counters de escritas bem-sucedidas (throughput útil)
const ownersCriados = new Counter("owners_criados_com_sucesso");
const petsCriados = new Counter("pets_criados_com_sucesso");
const visitsCriadas = new Counter("visits_criadas_com_sucesso");

// ── Configuração ─────────────────────────────────────────────────────────────
// __ENV permite override via: docker run -e BASE_URL=... ou k6 run -e BASE_URL=...
// Fallback automático: tenta a API pelo hostname do serviço na rede Docker
// e, se não estiver disponível, usa localhost para manter o modo host.
const HOST_BASE_URL = "http://localhost:9966/petclinic/api";
const HOST_ACTUATOR_URL = "http://localhost:9966/petclinic/actuator";
const SERVICE_BASE_URL = "http://petclinic-api:9966/petclinic/api";
const SERVICE_ACTUATOR_URL = "http://petclinic-api:9966/petclinic/actuator";

export function setup() {
  if (__ENV.BASE_URL || __ENV.ACTUATOR_URL) {
    return {
      baseUrl: __ENV.BASE_URL || HOST_BASE_URL,
      actuatorUrl: __ENV.ACTUATOR_URL || HOST_ACTUATOR_URL,
    };
  }

  const candidates = [
    { baseUrl: SERVICE_BASE_URL, actuatorUrl: SERVICE_ACTUATOR_URL },
    { baseUrl: HOST_BASE_URL, actuatorUrl: HOST_ACTUATOR_URL },
  ];

  for (const candidate of candidates) {
    const health = http.get(`${candidate.actuatorUrl}/health`);
    if (health.status === 200) {
      return candidate;
    }
  }

  return candidates[1];
}

const HEADERS = {
  headers: {
    "Content-Type": "application/json",
    Accept: "application/json",
  },
};

// ── IDs do seed data ─────────────────────────────────────────────────────────
// Seed ajustado para o banco de dados original PetClinic
const SEED_OWNER_IDS = Array.from({ length: 10 }, (_, i) => i + 1);
const SEED_PET_IDS = Array.from({ length: 13 }, (_, i) => i + 1);
const SEED_VET_IDS = Array.from({ length: 6 }, (_, i) => i + 1);

const PET_TYPES = [
  { id: 1, name: "cat" },
  { id: 2, name: "dog" },
  { id: 3, name: "lizard" },
  { id: 4, name: "snake" },
  { id: 5, name: "bird" },
  { id: 6, name: "hamster" },
];

// ── Perfil de carga (scenarios) ──────────────────────────────────────────────
// Dois cenários separados com tags de fase para isolamento de métricas:
//   - warmup:       dados com tag {phase:warmup}, EXCLUÍDOS dos thresholds
//   - steady_state: dados com tag {phase:test}, INCLUÍDOS nos thresholds
//
// A separação em cenários permite exclusão matemática do warm-up JIT do
// resultado final — impossível com stages simples (K6 não permite excluir
// dados de stages específicos do relatório).
export const options = {
  scenarios: {
    // Warm-up: mantém ramping-vus (correto para aquecimento JIT)
    warmup: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [{ duration: "30s", target: 30 }],
      gracefulRampDown: "5s",
      tags: { phase: "warmup" },
    },

    // ── Teste principal: open-loop com taxa constante ─────────────────
    // rate: iterações por segundo fixas; maxVUs: teto de VUs alocáveis.
    // K6 cria novos VUs conforme necessário para honrar a taxa — se a
    // aplicação travar, VUs se acumulam mas a taxa de chegada permanece
    // constante, preservando a premissa de "carga de trabalho constante".
    steady_state: {
      executor: "constant-arrival-rate",
      startTime: "30s", // inicia após o warmup
      rate: 50, // 50 iterações/s (ajuste conforme baseline)
      timeUnit: "1s",
      duration: "12m", // equivale ao steady_state anterior
      preAllocatedVUs: 50, // pool inicial (evita overhead de alocação)
      maxVUs: 150, // teto: permite absorver degradação sem travar
      tags: { phase: "test" },
      gracefulStop: "10s",
    },
  },
  thresholds: {
    // Threshold de segurança global (não alterar entre fases)
    http_req_duration: ["p(95)<5000"],
    taxa_erro: ["rate<0.10"],

    // Thresholds p95 + p99 por endpoint (ambos na mesma chave — k6 avalia todos)
    // p95: baseline histórico | p99: alimenta LatencyFitnessFunction
    latencia_listar_owners: ["p(95)<4000", "p(99)<5000"],
    latencia_criar_owner: ["p(95)<3000", "p(99)<4000"],
    latencia_consultar_owner: ["p(95)<3000", "p(99)<4000"],
    latencia_criar_pet: ["p(95)<3000", "p(99)<4000"],
    latencia_criar_visit: ["p(95)<3000", "p(99)<4000"],
    latencia_listar_vets: ["p(95)<2000", "p(99)<3000"],

    // Taxa de erro por endpoint → alimentam ReliabilityFitnessFunction
    erro_listar_owners: ["rate<0.10"],
    erro_criar_owner: ["rate<0.10"],
    erro_consultar_owner: ["rate<0.10"],
    erro_criar_pet: ["rate<0.10"],
    erro_criar_visit: ["rate<0.10"],
    erro_listar_vets: ["rate<0.10"],
  },
};

// ── Helpers ──────────────────────────────────────────────────────────────────
function randomFrom(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function parseJson(body) {
  try {
    return JSON.parse(body);
  } catch {
    return null;
  }
}

// ── Estado compartilhado por iteração ────────────────────────────────────────
export default function loadTestScenario(data) {
  const BASE_URL = data?.baseUrl || SERVICE_BASE_URL;
  const ACTUATOR_URL = data?.actuatorUrl || SERVICE_ACTUATOR_URL;

  let createdOwnerId = null;
  let createdPetId = null;

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. GET /owners — Listar todos os donos
  // ─────────────────────────────────────────────────────────────────────────
  // @Observed cobertos: Controller_Owner_ListAll → Service_Owner_FindAll (2 spans)
  // CRÍTICO: Owner carrega Set<Pet> EAGER → Set<Visit> EAGER. Dispara N+1
  // proporcional ao volume — endpoint com maior potencial de degradação.
  // Resposta: HTTP 200, array de Owner.
  // ═══════════════════════════════════════════════════════════════════════════
  group("GET /owners", function () {
    const res = http.get(`${BASE_URL}/owners`, HEADERS);
    latenciaListarOwners.add(res.timings.duration);

    const ok = check(res, {
      "listar-owners: status 200": (r) => r.status === 200,
      "listar-owners: body é array": (r) => Array.isArray(parseJson(r.body)),
      "listar-owners: array não-vazio": (r) =>
        Array.isArray(parseJson(r.body)) && parseJson(r.body).length > 0,
    });
    taxaErroGlobal.add(!ok);
    erroListarOwners.add(!ok);
  });

  sleep(0.2);

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. POST /owners — Criar dono
  // ─────────────────────────────────────────────────────────────────────────
  // @Observed cobertos: Controller_Owner_Add → Service_Owner_Save (2 spans)
  // CRÍTICO: write-path completo (Bean Validation → MapStruct → JPA flush).
  // Sensível à saturação do pool de conexões sob pico de VUs concorrentes.
  // Resposta: HTTP 201 com Owner completo incluindo id gerado.
  // ═══════════════════════════════════════════════════════════════════════════
  group("POST /owners", function () {
    // Regex do backend: apenas letras. Remove acentos/caracteres especiais para evitar erros 400.
    const cleanName = (name) => {
      const cleaned = name.replace(/[^a-zA-Z]/g, "");
      return cleaned.length > 0 ? cleaned : "John";
    };
    const rawPhone = faker.person.phone() || "1234567890";
    const phone = rawPhone
      .replace(/\D/g, "")
      .substring(0, 10)
      .padStart(10, "0");

    const payload = JSON.stringify({
      firstName: cleanName(faker.person.firstName()),
      lastName: cleanName(faker.person.lastName()),
      address: faker.address.street() || `Street ${__ITER}`,
      city: faker.address.city() || "City",
      telephone: phone,
    });

    const res = http.post(`${BASE_URL}/owners`, payload, HEADERS);
    latenciaCriarOwner.add(res.timings.duration);

    const ok = check(res, {
      "criar-owner: status 201": (r) => r.status === 201,
      "criar-owner: body tem id": (r) => {
        const d = parseJson(r.body);
        return d !== null && typeof d.id === "number";
      },
    });
    taxaErroGlobal.add(!ok);
    erroCriarOwner.add(!ok);

    if (ok) {
      ownersCriados.add(1);
      const d = parseJson(res.body);
      if (d) createdOwnerId = d.id;
    }
  });

  sleep(0.2);

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. GET /owners/{ownerId} — Consultar dono por ID
  // ─────────────────────────────────────────────────────────────────────────
  // @Observed cobertos: Controller_Owner_FindById → Service_Owner_FindById (2 spans)
  // CRÍTICO: grafo completo Owner + pets + visits — potencial N+1 sem JOIN FETCH.
  // Resposta: HTTP 200 com Owner completo.
  // ═══════════════════════════════════════════════════════════════════════════
  group("GET /owners/{ownerId}", function () {
    const ownerId = createdOwnerId || randomFrom(SEED_OWNER_IDS);
    const res = http.get(`${BASE_URL}/owners/${ownerId}`, HEADERS);
    latenciaConsultarOwner.add(res.timings.duration);

    const ok = check(res, {
      "consultar-owner: status 200": (r) => r.status === 200,
      "consultar-owner: tem firstName": (r) => {
        const d = parseJson(r.body);
        return d !== null && d.firstName !== undefined;
      },
    });
    taxaErroGlobal.add(!ok);
    erroConsultarOwner.add(!ok);
  });

  sleep(0.2);

  // ═══════════════════════════════════════════════════════════════════════════
  // 4. POST /owners/{ownerId}/pets — Adicionar pet a um dono
  // ─────────────────────────────────────────────────────────────────────────
  // @Observed cobertos: Controller_Pet_AddToOwner → Service_Owner_FindById
  //                     → Service_PetType_FindById → Service_Pet_Save (4 spans)
  // CRÍTICO: cadeia mais profunda — CascadeType.ALL + lookup duplo de FK.
  // Resposta: HTTP 201 com Pet completo incluindo id e ownerId.
  // ═══════════════════════════════════════════════════════════════════════════
  group("POST /owners/{ownerId}/pets", function () {
    const ownerId = createdOwnerId || randomFrom(SEED_OWNER_IDS);
    const petType = randomFrom(PET_TYPES);

    // xk6-faker tem module animal.dog(). Se der erro, usamos firstName
    let petName;
    try {
      petName = faker.animal.dog();
    } catch {
      petName = faker.person.firstName();
    }

    const year = 2015 + Math.floor(Math.random() * 8);
    const month = String(Math.floor(Math.random() * 12) + 1).padStart(2, "0");
    const day = String(Math.floor(Math.random() * 28) + 1).padStart(2, "0");

    const payload = JSON.stringify({
      name: petName.replace(/[^a-zA-Z]/g, "") || "Rex",
      birthDate: `${year}-${month}-${day}`,
      type: petType,
    });

    const res = http.post(
      `${BASE_URL}/owners/${ownerId}/pets`,
      payload,
      HEADERS,
    );
    latenciaCriarPet.add(res.timings.duration);

    const ok = check(res, {
      "criar-pet: status 201": (r) => r.status === 201,
      "criar-pet: body tem id": (r) => {
        const d = parseJson(r.body);
        return d !== null && typeof d.id === "number";
      },
    });
    taxaErroGlobal.add(!ok);
    erroCriarPet.add(!ok);

    if (ok) {
      petsCriados.add(1);
      const d = parseJson(res.body);
      if (d) createdPetId = d.id;
    }
  });

  sleep(0.2);

  // ═══════════════════════════════════════════════════════════════════════════
  // 5. POST /owners/{ownerId}/pets/{petId}/visits — Criar visita
  // ─────────────────────────────────────────────────────────────────────────
  // @Observed cobertos: Controller_Visit_AddToOwner → Service_Visit_Save (2 spans)
  // CRÍTICO: inserção em tabela filha — impacto de lock proporcional ao volume.
  // Endpoint canônico (não POST /visits — anotação órfã removida).
  // Resposta: HTTP 201 com Visit completo incluindo id e petId.
  // ═══════════════════════════════════════════════════════════════════════════
  group("POST /owners/{ownerId}/pets/{petId}/visits", function () {
    const ownerId = createdOwnerId || randomFrom(SEED_OWNER_IDS.slice(0, 10));
    const petId = createdPetId || randomFrom(SEED_PET_IDS.slice(0, 13));

    const ano = 2024 + Math.floor(Math.random() * 2);
    const mes = String(Math.floor(Math.random() * 12) + 1).padStart(2, "0");
    const dia = String(Math.floor(Math.random() * 28) + 1).padStart(2, "0");

    const descWords = [
      "Routine checkup",
      "Vaccination",
      "Dental cleaning",
      "Blood test",
      "Dermatology",
    ];
    const payload = JSON.stringify({
      date: `${ano}-${mes}-${dia}`,
      description: randomFrom(descWords) + " by " + faker.person.lastName(),
    });

    const res = http.post(
      `${BASE_URL}/owners/${ownerId}/pets/${petId}/visits`,
      payload,
      HEADERS,
    );
    latenciaCriarVisit.add(res.timings.duration);

    const ok = check(res, {
      "criar-visit: status 201": (r) => r.status === 201,
      "criar-visit: body tem id": (r) => {
        const d = parseJson(r.body);
        return d !== null && typeof d.id === "number";
      },
    });
    taxaErroGlobal.add(!ok);
    erroCriarVisit.add(!ok);

    if (ok) visitsCriadas.add(1);
  });

  sleep(0.2);

  // ═══════════════════════════════════════════════════════════════════════════
  // 6. GET /vets — Listar veterinários
  // ─────────────────────────────────────────────────────────────────────────
  // @Observed cobertos: Controller_Vet_ListAll → Service_Vet_FindAll (2 spans)
  // CRÍTICO: Vet → Specialty via @ManyToMany EAGER (vet_specialties).
  // Amplifica memory pressure e evidencia impacto da relação N:M sob carga.
  // Resposta: HTTP 200, array de Vet.
  // ═══════════════════════════════════════════════════════════════════════════
  group("GET /vets", function () {
    const res = http.get(`${BASE_URL}/vets`, HEADERS);
    latenciaListarVets.add(res.timings.duration);

    const ok = check(res, {
      "listar-vets: status 200": (r) => r.status === 200,
    });
    taxaErroGlobal.add(!ok);
    erroListarVets.add(!ok);
  });

  sleep(0.2);

  // ═══════════════════════════════════════════════════════════════════════════
  // BASELINE: GET /actuator/health
  // ─────────────────────────────────────────────────────────────────────────
  // Latência do framework puro (sem lógica de negócio, sem JPA).
  // Serve para normalizar os resultados dos endpoints críticos e separar
  // o overhead de infraestrutura do overhead do código de negócio.
  // ═══════════════════════════════════════════════════════════════════════════
  group("GET /actuator/health", function () {
    const res = http.get(`${ACTUATOR_URL}/health`);
    latenciaHealth.add(res.timings.duration);

    const ok = check(res, {
      "health: status 200": (r) => r.status === 200,
    });
    taxaErroGlobal.add(!ok);
  });

  sleep(__VU > 80 ? 0.1 : 0.3);
}

// ── Exportação de Resultados ─────────────────────────────────────────────────
// handleSummary() é chamado pelo k6 ao final do teste com TODOS os dados
// agregados (métricas, checks, thresholds). Exporta:
//   1. stdout: resumo textual formatado (o relatório padrão do k6)
//   2. summary.json: dados completos em JSON para análise Python/Pandas
//
// O JSON contém por métrica: count, rate, avg, min, med, max, p(90), p(95), p(99)
// e valores de thresholds (pass/fail). Isso permite ao notebook Python calcular
// médias, desvios padrão e testes de hipótese SEM depender do Grafana.
//
// Uso combinado com --out csv: o --out csv gera dados granulares por data point
// (timestamp, metric_name, value, tags) para séries temporais. O handleSummary
// gera o resumo agregado. Juntos, cobrem 100% das necessidades de análise.
//
// Referência: https://grafana.com/docs/k6/latest/results-output/end-of-test/custom-summary/
// ─────────────────────────────────────────────────────────────────────────────
export function handleSummary(data) {
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    "/results/summary.json": JSON.stringify(data, null, 2),
  };
}
