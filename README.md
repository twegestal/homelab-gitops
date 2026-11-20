# Blankett-system POC

Minimal start: ingress + en konsument (received-steget) + multi-tenancy från grunden.

## Förutsättningar

- Java 21
- Maven 3.9+
- Docker + Docker Compose

## Köra POC:en lokalt

### 1. Starta infrastrukturen

```bash
cd infra
docker compose up -d
```

Detta startar:
- **PostgreSQL** på `localhost:5432` (user: blankett, db: blankett)
  - Två schema förkonfigurerade: `tenant_styrelse_a`, `tenant_styrelse_b`
- **RabbitMQ** på `localhost:5672`, management UI på http://localhost:15672 (blankett/blankett)
- **MinIO** på `localhost:9000`, console på http://localhost:9001 (blankett/blankettblankett)
  - Två buckets förkonfigurerade: `blankett-styrelse-a`, `blankett-styrelse-b`

### 2. Bygga och starta tjänsterna

I separata terminaler:

```bash
# Terminal 1 - Ingress
cd blankett-ingress
mvn spring-boot:run

# Terminal 2 - Orchestrator
cd blankett-orchestrator
mvn spring-boot:run
```

Vid uppstart av ingress:
- Flyway migrerar `blankett_case`-tabellen till båda tenants schema
- RabbitMQ-köer deklareras dynamiskt: 4 köer × 2 tenants × (kö + DLQ) = 16 köer

Vid uppstart av orchestrator:
- En lyssnare per tenant registreras på respektive `received`-kö

### 3. Skicka en testblankett

```bash
# Som styrelse_a
curl -X POST http://localhost:8080/api/blanketter \
  -H "Content-Type: application/xml" \
  -H "X-Tenant-Id: styrelse_a" \
  -H "X-External-Ref: TEST-001" \
  -d '<blankett><registreringsnummer>ABC123</registreringsnummer></blankett>'

# Som styrelse_b
curl -X POST http://localhost:8080/api/blanketter \
  -H "Content-Type: application/xml" \
  -H "X-Tenant-Id: styrelse_b" \
  -H "X-External-Ref: TEST-002" \
  -d '<blankett><adress>Storgatan 1</adress></blankett>'
```

Förväntat resultat:
- Ingress returnerar `202 Accepted` med caseId och status `RECEIVED`
- Rå-XML hamnar i rätt MinIO-bucket (`blankett-styrelse-a/raw/<caseId>.xml`)
- Case-rad finns i rätt schema (`tenant_styrelse_a.blankett_case`)
- Orchestrator loggar: `[styrelse_a] Behandlar received för case ...`

### 4. Verifiera dataseparation

I MinIO console (http://localhost:9001): styrelse_a:s bucket innehåller bara styrelse_a:s blanketter.

I Postgres:
```bash
docker exec -it blankett-postgres psql -U blankett -d blankett \
  -c "SELECT id, external_ref, status FROM tenant_styrelse_a.blankett_case;"
```

## Vad som ingår i den här iterationen

- ✅ Multi-tenancy från start (TenantContext, schema-per-tenant, bucket-per-tenant)
- ✅ Per-tenant-köer i RabbitMQ
- ✅ Dynamisk listener-registrering per tenant
- ✅ Defense-in-depth: tenant-validering i header + payload + kö-binding
- ✅ Idempotens via external-ref
- ✅ Postgres med Flyway-migrering per tenant
- ✅ MinIO för rå-XML

## Vad som INTE finns ännu (medvetna utelämnanden)

- ❌ XSL-transformation (kommer i nästa iteration)
- ❌ Integrationstjänst med externa API-mockar (WireMock)
- ❌ WorkZone-adapter (.NET)
- ❌ Adminsite (React + BFF)
- ❌ Riktig autentisering (Keycloak/Omada) — POC använder X-Tenant-Id-header
- ❌ Resterande pipeline-konsumenter (enriching, transforming, submitting)
- ❌ Observabilitet (OpenTelemetry, Prometheus, Grafana)

## Nästa steg

1. Resterande tre konsumenter (enriching, transforming, submitting) som vidareförmedlar mellan stegen
2. Mock av integrationstjänsten med WireMock
3. Saxon för XSL-transformation
4. .NET-mock för WorkZone
5. Adminsite

## Designprinciper som POC:en demonstrerar

**Tenant-id kommer aldrig från klient-input.** I POC:en simuleras det via header, men `TenantContextFilter` är platsen där bytet till OIDC/mTLS sker — resten av koden behöver inte ändras.

**Defense-in-depth för dataseparation.** Tre oberoende kontroller verifierar tenant: kö-binding, AMQP-header, payload-fält. Mismatch = kritisk incident.

**Köerna är fysiskt separerade per tenant.** Ingen delad kö någonstans i pipelinen.

**Schema-per-tenant.** Hibernate hämtar schema från TenantContext via SchemaTenantResolver. Ingen `WHERE tenant_id = ?` behövs någonstans i koden — fysisk separation gör det överflödigt.
