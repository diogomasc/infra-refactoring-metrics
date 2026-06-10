// ─────────────────────────────────────────────────────────────────────────────
// Script de Carga — TCC: Métricas de Refatoração (Spring PetClinic REST)
// ─────────────────────────────────────────────────────────────────────────────
//
// Exercita APENAS os 6 endpoints críticos definidos no LEIAME do projeto,
// selecionados por apresentarem os maiores riscos de degradação dinâmica
// correlacionáveis com anomalias estáticas (N+1, EAGER cascata, CascadeType,
// relação N:M, write-path completo).
//
// Endpoints críticos:
//   1. GET  /api/owners              → N+1 via EAGER (Owner→Pet→Visit)
//   2. POST /api/owners              → Write-path completo
//   3. GET  /api/owners/{id}         → Consulta com grafo profundo
//   4. POST /api/owners/{id}/pets    → Cascata JPA (CascadeType.ALL)
//   5. POST /api/visits              → Inserção em tabela filha com FK
//   6. GET  /api/vets                → Relação N:M EAGER
//
// + GET /actuator/health como baseline de latência do framework.
//
// Seed data (H2, data.sql — recarregado a cada restart):
//   - 10 owners (IDs 1–10), 13 pets (IDs 1–13)
//   - 6 pet types: cat(1), dog(2), lizard(3), snake(4), bird(5), hamster(6)
//   - 6 vets (IDs 1–6), 3 specialties
//   - 4 visits (IDs 1–4)
//
// Execução:
//   docker compose -f infra/docker-compose.infra.yml \
//     --profile testing run --rm k6 run /scripts/load-test.js
//
// ⚠️  NÃO altere stages, thresholds nem payloads entre as fases
//     baseline e pós-refatoração — apenas o código Java muda.
// ─────────────────────────────────────────────────────────────────────────────

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Trend, Rate, Counter } from "k6/metrics";

// ── Métricas customizadas (metodologia RED) ──────────────────────────────────
const latenciaListarOwners   = new Trend("latencia_listar_owners",    true);
const latenciaCriarOwner     = new Trend("latencia_criar_owner",      true);
const latenciaConsultarOwner = new Trend("latencia_consultar_owner",  true);
const latenciaCriarPet       = new Trend("latencia_criar_pet",        true);
const latenciaCriarVisit     = new Trend("latencia_criar_visit",      true);
const latenciaListarVets     = new Trend("latencia_listar_vets",      true);
const latenciaHealth         = new Trend("latencia_health",           true);

const taxaErroGlobal   = new Rate("taxa_erro");
const ownersCriados    = new Counter("owners_criados_com_sucesso");
const petsCriados      = new Counter("pets_criados_com_sucesso");
const visitsCriadas    = new Counter("visits_criadas_com_sucesso");

// ── Configuração ─────────────────────────────────────────────────────────────
const BASE_URL     = "http://host.docker.internal:9966/petclinic/api";
const ACTUATOR_URL = "http://host.docker.internal:9966/petclinic/actuator";

const HEADERS = {
  headers: {
    "Content-Type": "application/json",
    "Accept": "application/json",
  },
};

// IDs do seed data (data.sql) — usados como fallback
const SEED_OWNER_IDS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
const SEED_PET_IDS   = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];

// ── Perfil de carga (NÃO ALTERAR entre fases) ───────────────────────────────
export const options = {
  stages: [
    { duration: "30s", target: 10 },  // ramp-up
    { duration: "2m",  target: 10 },  // carga sustentada
    { duration: "30s", target: 50 },  // spike
    { duration: "1m",  target: 50 },  // estresse
    { duration: "30s", target: 0  },  // ramp-down
  ],
  thresholds: {
    http_req_duration:        ["p(95)<2000"],
    taxa_erro:                ["rate<0.05"],
    latencia_listar_owners:   ["p(95)<1500"],
    latencia_criar_owner:     ["p(95)<2000"],
    latencia_consultar_owner: ["p(95)<1000"],
    latencia_criar_pet:       ["p(95)<2000"],
    latencia_criar_visit:     ["p(95)<2000"],
    latencia_listar_vets:     ["p(95)<1000"],
  },
};

// ── Helpers ──────────────────────────────────────────────────────────────────

function randomFrom(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function parseJson(body) {
  try { return JSON.parse(body); }
  catch { return null; }
}

// ── Execução principal ──────────────────────────────────────────────────────

export default function () {

  let createdOwnerId = null;
  let createdPetId   = null;

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. GET /owners — Listar todos os donos
  // ─────────────────────────────────────────────────────────────────────────
  // CRÍTICO: Owner carrega Set<Pet> com FetchType.EAGER, que por sua vez
  // carrega Set<Visit> EAGER. Listar todos os owners dispara uma cascata
  // de queries N+1 proporcional ao volume de dados.
  // Risco: latência cresce com volume de dados criados durante o teste.
  // ═══════════════════════════════════════════════════════════════════════════
  group("GET /owners", function () {
    const res = http.get(`${BASE_URL}/owners`, HEADERS);
    latenciaListarOwners.add(res.timings.duration);

    const ok = check(res, {
      "listar-owners: status 200": (r) => r.status === 200,
      "listar-owners: body é array não-vazio": (r) => {
        const d = parseJson(r.body);
        return Array.isArray(d) && d.length > 0;
      },
    });
    taxaErroGlobal.add(!ok);
  });

  sleep(0.3);

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. POST /owners — Criar dono
  // ─────────────────────────────────────────────────────────────────────────
  // CRÍTICO: write-path completo: validação (@NotEmpty, @Pattern, @Digits)
  // → mapeamento MapStruct → JPA persist → flush.
  // Risco: contenção de locks no banco sob alta concorrência.
  // ═══════════════════════════════════════════════════════════════════════════
  group("POST /owners", function () {
    const payload = JSON.stringify({
      firstName: `K6VU${__VU}`,
      lastName:  `Iter${__ITER}`,
      address:   `Rua do Teste, ${__VU}`,
      city:      "Salvador",
      telephone: `71${String(__VU).padStart(3, "0")}${String(__ITER % 100000).padStart(5, "0")}`,
    });

    const res = http.post(`${BASE_URL}/owners`, payload, HEADERS);
    latenciaCriarOwner.add(res.timings.duration);

    const ok = check(res, {
      "criar-owner: status 201": (r) => r.status === 201,
      "criar-owner: body tem id": (r) => {
        const d = parseJson(r.body);
        return d !== null && d.id !== undefined;
      },
    });
    taxaErroGlobal.add(!ok);

    if (ok) {
      ownersCriados.add(1);
      const d = parseJson(res.body);
      if (d) createdOwnerId = d.id;
    }
  });

  sleep(0.3);

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. GET /owners/{id} — Consultar dono por ID
  // ─────────────────────────────────────────────────────────────────────────
  // CRÍTICO: retorna owner + pets aninhados + visits de cada pet.
  // Potencial N+1 se não otimizado.
  // Risco: latência proporcional ao número de pets/visits do owner.
  // ═══════════════════════════════════════════════════════════════════════════
  group("GET /owners/{id}", function () {
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
  });

  sleep(0.3);

  // ═══════════════════════════════════════════════════════════════════════════
  // 4. POST /owners/{id}/pets — Adicionar pet a um dono
  // ─────────────────────────────────────────────────────────────────────────
  // CRÍTICO: CascadeType.ALL no Pet.type pode causar side-effects.
  // savePet() faz lookup de PetType antes de salvar.
  // Risco: falha silenciosa se type_id inválido.
  // ═══════════════════════════════════════════════════════════════════════════
  group("POST /owners/{id}/pets", function () {
    const ownerId = createdOwnerId || randomFrom(SEED_OWNER_IDS);
    const typeId  = Math.floor(Math.random() * 6) + 1; // 1–6 (cat..hamster)

    const payload = JSON.stringify({
      name:      `Pet_${__VU}_${__ITER}`,
      birthDate: "2023-06-15",
      type:      { id: typeId },
    });

    const res = http.post(`${BASE_URL}/owners/${ownerId}/pets`, payload, HEADERS);
    latenciaCriarPet.add(res.timings.duration);

    const ok = check(res, {
      "criar-pet: status 201": (r) => r.status === 201,
    });
    taxaErroGlobal.add(!ok);

    if (ok) {
      petsCriados.add(1);
      const d = parseJson(res.body);
      if (d) createdPetId = d.id;
    }
  });

  sleep(0.3);

  // ═══════════════════════════════════════════════════════════════════════════
  // 5. POST /visits — Criar visita
  // ─────────────────────────────────────────────────────────────────────────
  // CRÍTICO: inserção em tabela filha. Criação de visit requer lookup do pet,
  // potencial lock no owner pai via foreign key.
  // Risco: deadlock sob alta concorrência.
  // Nota: usa o endpoint direto POST /visits (VisitRestController), que
  // aceita um VisitDto completo com o pet embutido.
  // ═══════════════════════════════════════════════════════════════════════════
  group("POST /visits", function () {
    const petId = createdPetId || randomFrom(SEED_PET_IDS);

    const payload = JSON.stringify({
      date:        "2024-06-10",
      description: `Consulta K6 VU${__VU} iter${__ITER}`,
      pet:         { id: petId },
    });

    const res = http.post(`${BASE_URL}/visits`, payload, HEADERS);
    latenciaCriarVisit.add(res.timings.duration);

    const ok = check(res, {
      "criar-visit: status 201": (r) => r.status === 201,
    });
    taxaErroGlobal.add(!ok);

    if (ok) visitsCriadas.add(1);
  });

  sleep(0.3);

  // ═══════════════════════════════════════════════════════════════════════════
  // 6. GET /vets — Listar veterinários
  // ─────────────────────────────────────────────────────────────────────────
  // CRÍTICO: Vet → Specialty via @ManyToMany EAGER + tabela de junção
  // vet_specialties. Grafo de objetos denso.
  // Risco: memory pressure com muitos vets.
  // ═══════════════════════════════════════════════════════════════════════════
  group("GET /vets", function () {
    const res = http.get(`${BASE_URL}/vets`, HEADERS);
    latenciaListarVets.add(res.timings.duration);

    const ok = check(res, {
      "listar-vets: status 200": (r) => r.status === 200,
      "listar-vets: body é array não-vazio": (r) => {
        const d = parseJson(r.body);
        return Array.isArray(d) && d.length > 0;
      },
    });
    taxaErroGlobal.add(!ok);
  });

  sleep(0.3);

  // ═══════════════════════════════════════════════════════════════════════════
  // BASELINE: GET /actuator/health
  // ─────────────────────────────────────────────────────────────────────────
  // Latência do framework puro (sem lógica de negócio).
  // Serve para normalizar os resultados dos endpoints críticos.
  // ═══════════════════════════════════════════════════════════════════════════
  group("GET /actuator/health", function () {
    const res = http.get(`${ACTUATOR_URL}/health`);
    latenciaHealth.add(res.timings.duration);

    const ok = check(res, {
      "health: status 200": (r) => r.status === 200,
      "health: status UP":  (r) => {
        const d = parseJson(r.body);
        return d !== null && d.status === "UP";
      },
    });
    taxaErroGlobal.add(!ok);
  });

  sleep(0.5);
}
