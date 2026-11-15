# FCG Fase 4 — Cloud-Native: Kubernetes gerenciado, CI/CD, NoSQL, Cache e Busca

Evolução da plataforma **FIAP Cloud Games**: cluster **AKS** na Azure com registry privado **ACR**, pipeline
**GitHub Actions** (build → testes → imagem versionada → scan → push → deploy com Rolling Update),
persistência poliglota (**SQL Server + MongoDB**), cache **Redis**, busca avançada com **Elasticsearch** e
gestão de segredos com **Azure Key Vault** (zero credenciais no código).

> Guia central da entrega. Repositórios (um por componente):
> `fcg-orchestration` (este) · `fcg-users-api` · `fcg-catalog-api` · `fcg-payments-api`

## Arquitetura

```
                    Internet
                       │
            ┌──────────▼───────────┐        GitHub Actions (OIDC, sem senhas)
            │  Azure Load Balancer │        ┌────────────────────────────────────┐
            └──────────┬───────────┘        │ push main → test → docker build    │
                       │                    │ → Trivy → push ACR → kubectl apply │
            ┌──────────▼───────────┐        └───────────────┬────────────────────┘
            │  Ingress NGINX (AKS) │                        │
            └───┬──────────────┬───┘            ┌───────────▼───────────┐
   /api/auth    │              │ /api/games     │  ACR (registry priv.) │
   /api/users   │              │ (+ /search)    └───────────────────────┘
   /api/profiles│              │
         ┌──────▼─────┐   ┌────▼───────┐   RabbitMQ   ┌──────────────┐
         │ users-api  │   │ catalog-api├─────────────►│ payments-api │
         │ (2 pods)   │   │ (2 pods)   │◄─────────────┤  (worker)    │
         └─┬────┬───┬─┘   └─┬───┬───┬──┴┐             └──────┬───────┘
           │    │   │       │   │   │   │                    │
   SQL Server  MongoDB  Redis  │  Elasticsearch              MongoDB
   (usuários) (perfis)  (cache)│  (busca fuzzy)             (pagamentos)
                               └─ SQL Server (catálogo = fonte da verdade)

   Key Vault ──(pipeline infra)──► Secret "fcg-secrets" ──► env vars dos pods
   Prometheus + Grafana (port-forward) ◄── /metrics dos serviços
```

## Atendimento ao enunciado

| Requisito (TC Fase 4) | Onde está |
|---|---|
| Kubernetes **gerenciado** em nuvem (AKS) | `terraform/main.tf` → `azurerm_kubernetes_cluster` |
| Registry privado nativo (ACR) | `terraform/main.tf` → `azurerm_container_registry` (admin desabilitado; pull pela identidade do kubelet) |
| Exposição via Ingress/LB | `k8s/ingress/ingress.yaml` + Ingress NGINX (helm, no workflow `infra`) |
| **NoSQL obrigatório** (MongoDB + driver oficial) | Perfis (Users), avaliações (Catalog), pagamentos (Payments) — `MongoDB.Driver` |
| **Cache obrigatório** (Redis) | Perfis, `GET /api/games` e `/search` — `IDistributedCache` / StackExchange.Redis |
| **Elasticsearch**: índice sincronizado + `/search` fuzzy por relevância | `fcg-catalog-api` → `Search/ElasticsearchGameSearchIndex.cs`, `GamesController.Search` |
| CI/CD GitHub Actions (≥ Users e Catalog) | `.github/workflows/ci-cd.yml` em users, catalog **e** payments |
| Build & Test | `dotnet build` + `dotnet test` (24 testes Users, 34 Catalog) |
| Containerização com **tags versionadas** | `1.0.<run_number>`, `sha-<commit>`, `latest` |
| Security scan (desejável) | Trivy (`TRIVY_BLOCK=true` torna bloqueante) |
| Push no registry da cloud | `az acr login` + `docker push` (login OIDC) |
| Deploy **Rolling Update** sem downtime | `strategy.rollingUpdate: maxUnavailable 0, maxSurge 1`, 2 réplicas, readinessProbe, PDB, rollback automático |
| **Zero hardcoded credentials** | sem senha em código/YAML/compose; ver "Segredos" abaixo; job `validate` bloqueia regressões |
| Injeção de secrets | Secret `fcg-secrets` ← Azure Key Vault; pods usam `secretKeyRef` |

## Estrutura deste repositório

```
fcg-orchestration/
├── .github/workflows/infra.yml     validate (fmt, kubeconform, anti-segredo) + provision (terraform → cluster)
├── terraform/                      RG, ACR, AKS, Key Vault + segredos gerados (random_password)
├── k8s/
│   ├── 00-namespace.yaml  01-config.yaml        namespace e ConfigMap (não sensível)
│   ├── data/                       SQL Server, MongoDB, Redis, RabbitMQ, Elasticsearch (StatefulSets + PVC)
│   ├── observability/              Prometheus + Grafana (dashboard provisionado)
│   └── ingress/ingress.yaml
└── scripts/
    ├── bootstrap-azure.sh          1x: estado do Terraform + identidade OIDC do GitHub Actions
    ├── sync-secrets.sh             Key Vault → Secret do Kubernetes (pipeline)
    ├── local-secret-from-env.sh    mesmo Secret em cluster local
    └── set-github-vars.sh          cadastra ACR/AKS como variables nos repos dos serviços
```

Os manifestos de cada serviço ficam no próprio repositório (`k8s/deployment.yaml`), junto da pipeline que os aplica.

## Segredos e gestão de credenciais

- **Nada sensível no Git**: `appsettings*.json`, manifestos, `docker-compose.yml` e scripts não têm senha, chave ou connection string com credencial. O `.env` local é gerado por `scripts/generate-local-env.sh` e está no `.gitignore`.
- **Origem**: o Terraform gera as senhas (`random_password`) e grava no **Azure Key Vault** (RBAC). Ninguém digita nem vê esses valores.
- **Injeção**: a pipeline `infra` lê o Key Vault (identidade OIDC com *Key Vault Secrets User*) e cria o **Secret `fcg-secrets`** no namespace `fcg`. Os pods referenciam as chaves por `secretKeyRef` e montam as connection strings com `$(VAR)` do Kubernetes, então o YAML só guarda *referências*.
- **Falha segura**: as APIs não têm valor padrão com senha; sem `Jwt__Secret`, MongoDB, Redis ou RabbitMQ configurados, **recusam subir**.
- **Pipeline sem senhas**: GitHub → Azure via **OIDC (federated credentials)**; não há *client secret* armazenado.
- **Rotação**: altere o valor no Key Vault, rode `sync-secrets.sh` (ou o workflow) e `kubectl rollout restart`.

## Passo a passo — subir tudo na Azure

Pré-requisitos: assinatura Azure, `az`, `gh`, repositórios criados no GitHub.

```bash
# 1) UMA vez: estado do Terraform + identidade OIDC do GitHub Actions
az login
GITHUB_OWNER=laviniaptrabuco bash scripts/bootstrap-azure.sh
#    → imprime AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID (secrets)
#      e TFSTATE_RG / TFSTATE_SA / DEPLOYER_OBJECT_ID (variables). Cadastre-os no GitHub.

# 2) Provisionar: dispare o workflow "infra" (Actions → infra → Run workflow) ou faça push na main.
#    Cria RG + ACR + AKS + Key Vault, instala o Ingress, sincroniza o Secret e sobe os dados.

# 3) Cadastrar o ACR/AKS nos repos dos serviços (valores no resumo do workflow infra)
GITHUB_OWNER=laviniaptrabuco bash scripts/set-github-vars.sh <acr_name> <aks_name> <resource_group>

# 4) Primeiro deploy: push na main de cada serviço (ou "Run workflow"). A partir daí,
#    todo push na main = build → test → imagem → scan → push → deploy.

# 5) Obter o IP público
az aks get-credentials -g <resource_group> -n <aks_name>
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

> **Custo**: 2 nós `Standard_D2s_v6` + ACR Standard + Key Vault. Destrua ao terminar: `terraform destroy`
> (ou `az group delete -n rg-fcg-prod`).

## Roteiro de teste (substitua `$IP` pelo IP do Ingress)

```bash
# Cadastro e login
curl -X POST http://$IP/api/auth/register -H "Content-Type: application/json" \
  -d '{"name":"Joao Gamer","email":"joao@email.com","password":"Senha@123"}'
curl -X POST http://$IP/api/auth/login -H "Content-Type: application/json" \
  -d '{"email":"joao@email.com","password":"Senha@123"}'

# NoSQL + cache de perfil: 1ª leitura source=mongodb, 2ª source=redis
curl -X PUT http://$IP/api/profiles/{userId} -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"displayName":"Joao","bio":"Gamer","favoriteGenres":["RPG"]}'
curl http://$IP/api/profiles/{userId} -H "Authorization: Bearer $TOKEN"

# Busca avançada (Elasticsearch): fuzzy tolera erro de digitação; ordenada por relevância
curl -i "http://$IP/api/games/search?q=wiitcher"        # acha "The Witcher 3" mesmo com o typo
curl -i "http://$IP/api/games/search?q=zeldda&genre=Aventura"

# Impacto do cache: compare X-Cache e X-Elapsed-Ms (MISS = banco/Elasticsearch, HIT = Redis)
curl -si http://$IP/api/games | grep -iE "x-cache|x-elapsed"
curl -si http://$IP/api/games | grep -iE "x-cache|x-elapsed"
```

Criar/editar um jogo (Admin) reindexa no Elasticsearch **e** invalida o cache: a busca seguinte já reflete a mudança.

## Live Deploy (demonstração do pitch)

1. Altere algo visível no `fcg-catalog-api` (ex.: texto de uma mensagem ou um novo campo na resposta).
2. `git commit` + `git push` na `main`.
3. Em **Actions**: `Build & Test` → `Docker image, scan & push` (nova tag `1.0.N`) → `Deploy no AKS`.
4. `kubectl get pods -n fcg -w`: pods novos sobem, só então os antigos saem (`maxUnavailable: 0`) — **sem downtime**.
5. Reexecute o `curl` e mostre a mudança em produção. `kubectl rollout history deployment/catalog-api -n fcg` mostra a revisão.

## Observabilidade

```bash
kubectl port-forward -n fcg svc/grafana 3000:3000      # usuário admin; senha no Key Vault (grafana-admin-password)
kubectl port-forward -n fcg svc/prometheus 9090:9090
```

Dashboard **FCG - UsersAPI & CatalogAPI**: requisições/s, por status HTTP, latência p95 e taxa de erro.

## Ambiente local (Docker Compose)

```bash
bash scripts/generate-local-env.sh         # (na raiz do workspace) gera .env com senhas aleatórias
docker compose up -d --build
# users-api  → http://localhost:8081/swagger   catalog-api → http://localhost:8082/swagger
# Grafana    → http://localhost:3000            Prometheus  → http://localhost:9090
```

## Evidências (validado localmente com Docker Compose)

| Teste | Resultado |
|---|---|
| `dotnet test` Users / Catalog | 24 / 34 testes passando |
| `terraform fmt` + `validate` | OK |
| `kubeconform -strict` nos manifestos | 31 recursos válidos, 0 inválidos |
| Login do Admin inicial (bootstrap por Secret) e criação de 3 jogos | 201 + indexação no Elasticsearch |
| `/search?q=wiitcher` (typo) | acha *The Witcher 3* (score 2.63) |
| `/search?q=zeldda` (typo) | acha *Zelda Breath of the Wild* |
| `/search?q=cyber` (prefixo) | acha *Cyberpunk 2077* |
| Busca repetida | `X-Cache: MISS` 261 ms → `HIT` 3 ms |
| `GET /api/games` | `MISS` 10 ms → `HIT` 1,7 ms |
| `/search` sem `q` | 400 |

Não executado aqui: `terraform apply`, pipelines no GitHub e deploy no AKS (dependem da sua conta Azure/GitHub).

## Decisões e limites (honestidade técnica)

- **Elasticsearch no cluster** (StatefulSet com basic auth) para controlar custo na disciplina. O enunciado cita serviço
  gerenciado (Elastic Cloud/OpenSearch): o código já suporta `Elasticsearch__ApiKey` ou usuário/senha, então migrar é
  trocar `Elasticsearch__Uri` no `01-config.yaml` e o segredo no Key Vault — sem alterar código.
- **Bancos em StatefulSets** (SQL Server, MongoDB, Redis, RabbitMQ) com disco gerenciado (PVC). Em produção real o ideal
  é Azure SQL/Cosmos DB (API Mongo)/Azure Cache for Redis; mantive o mesmo modelo da Fase 3 para portabilidade.
- **Kong (Fase 3)** foi substituído pelo **Ingress NGINX** na nuvem (roteamento por path + rate limit). O Kong pode ser
  reimplantado atrás do Ingress se a nota da Fase 3 exigir gateway dedicado.
- **TLS/host**: o Ingress responde por IP público em HTTP; para HTTPS adicione cert-manager + domínio.
- A conta Azure, o `terraform apply` e o primeiro deploy dependem das credenciais do aluno e **precisam ser executados por você**
  (o repositório entrega toda a automação, mas a execução na nuvem não foi feita neste ambiente).
