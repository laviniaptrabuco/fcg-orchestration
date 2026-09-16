# FCG Orchestration

Repositório de orquestração da plataforma FIAP Cloud Games. Contém a evolução em duas fases:

- **Fase 2** (tag [`fase-2`](../../tags/fase-2)): microsserviços puros, comunicação via RabbitMQ/MassTransit, SQL Server.
- **Fase 3** (branch `main`, atual): API Gateway (Kong), observabilidade (Prometheus + Grafana), persistência poliglota (SQL Server + MongoDB + Redis) e Serverless.

> Para rodar exatamente o ambiente da Fase 2 (sem Kong/observabilidade/Mongo), faça `git checkout fase-2` neste repositório e nos repositórios de cada microsserviço (todos têm a mesma tag).

---

## Fase 3 (atual)

### Arquitetura

```
┌───────────────────────────────────────────────────────────────────┐
│                         Cliente                                   │
└───────────────────────────────┬───────────────────────────────────┘
                                 │ HTTP
                                 ▼
                   ┌─────────────────────────┐
                   │   Kong API Gateway       │
                   │  proxy :8000 / admin :8001│
                   │  JWT · Rate Limit · CORS │
                   └────────┬──────┬──────────┘
                            │      │
              /api/users    │      │  /api/catalog
              /api/auth     │      │  /api/games
              /api/profiles │      │
                            ▼      ▼
                  ┌────────────┐ ┌────────────┐
                  │ UsersAPI   │ │ CatalogAPI │
                  └─┬───┬───┬──┘ └─┬───┬───┬──┘
                    │   │   │      │   │   │
        ┌───────────┘   │   └──────┘   │   └───────────┐
        ▼               ▼              ▼               ▼
  ┌──────────┐    ┌──────────┐   ┌──────────┐   ┌──────────┐
  │SQL Server│    │ MongoDB  │   │  Redis   │   │ RabbitMQ │
  │(relacional│   │(perfis,  │   │ (cache-  │   │ (eventos │
  │ core)    │    │ reviews) │   │  aside)  │   │ de compra)│
  └──────────┘    └──────────┘   └──────────┘   └────┬─────┘
                                                       │
                                        ┌──────────────┼───────────────┐
                                        ▼                              ▼
                                ┌─────────────┐              ┌──────────────────┐
                                │PaymentsAPI  │              │ Azure Function    │
                                │(worker)     │              │ (notifications -  │
                                └─────────────┘              │  repo próprio)    │
                                                              └──────────────────┘

Observabilidade: UsersAPI/CatalogAPI --/metrics--> Prometheus --> Grafana
```

**Persistência poliglota:** SQL Server guarda os dados centrais (usuários, catálogo). MongoDB guarda dados expandidos (perfis, reviews). Redis faz cache-aside sobre o MongoDB. Repositório da função serverless: [fcg-notifications-serverless](https://github.com/laviniaptrabuco/fcg-notifications-serverless).

### Executar com Docker Compose

```bash
docker-compose -f docker-compose.fase3.yml up -d --build

# Acessos:
# Kong Proxy:  http://localhost:8000    Kong Admin: http://localhost:8001
# Grafana:     http://localhost:3000 (admin/admin)
# Prometheus:  http://localhost:9090
# RabbitMQ:    http://localhost:15672 (guest/guest)
# MongoDB:     localhost:27017 (admin/admin)  Redis: localhost:6379
# SQL Server:  localhost:1433 (SA / FCG_Dev@2024)

bash fcg-api-gateway/setup-routes.sh
```

### Deploy no Kubernetes

Pré-requisitos: cluster local (Docker Desktop Kubernetes, Minikube ou Kind), `kubectl` configurado, imagens buildadas localmente:

```bash
docker build -t fcg-users-api:fase3    ../fcg-users-api
docker build -t fcg-catalog-api:fase3  ../fcg-catalog-api
docker build -t fcg-payments-api:fase3 ../fcg-payments-api
```

> **Minikube/Kind** rodam um daemon Docker separado do host: depois do build, carregue as imagens no cluster (`minikube image load ...` ou `kind load docker-image ...`) antes de aplicar os manifestos. **Docker Desktop Kubernetes** compartilha o daemon automaticamente.

```bash
kubectl apply -f k8s/fase3-namespace.yaml
kubectl apply -f k8s/fase3-data/
kubectl apply -f k8s/fase3-gateway/kong-migration-job.yaml
kubectl wait --for=condition=complete job/kong-migration -n fcg-fase3 --timeout=90s
kubectl apply -f k8s/fase3-gateway/kong.yaml
kubectl apply -f k8s/fase3-observability/
kubectl apply -f k8s/fase3-services/

kubectl get pods -n fcg-fase3
kubectl port-forward -n fcg-fase3 svc/kong 8000:8000 8001:8001
KONG_ADMIN="http://localhost:8001" bash fcg-api-gateway/setup-routes.sh
```

### Fluxo de teste (Fase 3)

```bash
# 1. Cadastro
curl -X POST http://localhost:8000/api/auth/register -H "Content-Type: application/json" \
  -d '{"name":"João Gamer","email":"joao@email.com","password":"Senha@123"}'

# 2. Login
curl -X POST http://localhost:8000/api/auth/login -H "Content-Type: application/json" \
  -d '{"email":"joao@email.com","password":"Senha@123"}'
# -> {"token": "eyJ...", ...}

# 3. JWT + RBAC: sem token = 401; com token comum em rota de Admin = 403
curl http://localhost:8000/api/users
curl http://localhost:8000/api/users -H "Authorization: Bearer {token}"

# 4. Perfil - MongoDB + cache Redis (1ª leitura: source=mongodb, 2ª: source=redis)
curl -X PUT http://localhost:8000/api/profiles/{userId} -H "Authorization: Bearer {token}" \
  -H "Content-Type: application/json" -d '{"displayName":"João","favoriteGenres":["RPG"]}'
curl http://localhost:8000/api/profiles/{userId} -H "Authorization: Bearer {token}"

# 5. Observabilidade
curl http://localhost:9090/api/v1/targets
curl "http://localhost:9090/api/v1/query?query=http_requests_received_total"
```

Grafana (`http://localhost:3000`, admin/admin) → dashboard **FCG - UsersAPI & CatalogAPI**: requisições por segundo, por status code HTTP, latência p95 e taxa de erro em tempo real.

### Estrutura

```
fcg-orchestration/
├── docker-compose.yml         Fase 2
├── docker-compose.fase3.yml   Fase 3
├── k8s/
│   ├── sqlserver/ rabbitmq/ users-api/ catalog-api/ payments-api/ notifications-api/   Fase 2
│   └── fase3-namespace.yaml fase3-data/ fase3-gateway/ fase3-observability/ fase3-services/  Fase 3
├── fcg-api-gateway/    setup-routes.sh (Kong)
└── fcg-observability/  prometheus.yml, alert-rules.yml, datasources e dashboards do Grafana
```

---

## Fase 2

### Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│                    FIAP Cloud Games                         │
│                                                             │
│  ┌──────────────┐    UserCreatedEvent    ┌───────────────┐  │
│  │  UsersAPI    │ ──────────────────────▶│Notifications  │  │
│  │  (porta 5001)│                        │     API       │  │
│  └──────────────┘                        └───────────────┘  │
│                                                    ▲        │
│  ┌──────────────┐  OrderPlacedEvent  ┌──────────┐  │        │
│  │  CatalogAPI  │ ─────────────────▶ │Payments  │  │        │
│  │  (porta 5002)│◀──────────────────│   API    │──┘        │
│  └──────────────┘ PaymentProcessedEv └──────────┘           │
│                                                             │
│  Broker: RabbitMQ (porta 5672 / management 15672)           │
│  Banco:  SQL Server (porta 1433)                            │
└─────────────────────────────────────────────────────────────┘
```

### Executar com Docker Compose

```bash
docker-compose up --build

# UsersAPI Swagger:   http://localhost:5001/swagger
# CatalogAPI Swagger: http://localhost:5002/swagger
# RabbitMQ Manager:  http://localhost:15672 (guest/guest)
```

### Deploy no Kubernetes

```bash
docker build -t fcg-users-api:latest ../fcg-users-api
docker build -t fcg-catalog-api:latest ../fcg-catalog-api
docker build -t fcg-payments-api:latest ../fcg-payments-api
docker build -t fcg-notifications-api:latest ../fcg-notifications-api

kubectl apply -f k8s/sqlserver/
kubectl apply -f k8s/rabbitmq/
kubectl apply -f k8s/users-api/
kubectl apply -f k8s/catalog-api/
kubectl apply -f k8s/payments-api/
kubectl apply -f k8s/notifications-api/

kubectl get pods
kubectl get services
kubectl port-forward svc/users-api-service 5001:80
kubectl port-forward svc/catalog-api-service 5002:80
```

### Fluxo de teste (Fase 2)

**1. Cadastro de usuário (fluxo boas-vindas)**
```
POST http://localhost:5001/api/auth/register
{"name": "João Gamer", "email": "joao@email.com", "password": "Senha@123"}
```
→ Logs do `notifications-api`: `[EMAIL SIMULADO] Boas-vindas enviado para: joao@email.com`

**2. Login**
```
POST http://localhost:5001/api/auth/login
{"email": "joao@email.com", "password": "Senha@123"}
```

**3. Cadastrar jogo (como admin)**
```
POST http://localhost:5002/api/games
Authorization: Bearer {token_admin}
{"title": "Elden Ring", "description": "RPG de ação", "genre": "RPG", "price": 249.90}
```

**4. Comprar jogo (fluxo de compra completo)**
```
POST http://localhost:5002/api/games/{gameId}/purchase
Authorization: Bearer {token_usuario}
```
→ Logs: `catalog-api: OrderPlacedEvent published` → `payments-api: PaymentProcessedEvent published: Status=Approved` → `catalog-api: Game {gameId} added to library` → `notifications-api: [EMAIL SIMULADO] Confirmação de compra enviado`
