#!/bin/bash
# Configura servicos, rotas e plugins no Kong.
# Idempotente: pode rodar novamente sem duplicar objetos.

set -e

KONG_ADMIN="${KONG_ADMIN:-http://localhost:8001}"
CONSUMER_NAME="fcg-user"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ok] $1${NC}"; }
err()  { echo -e "${RED}[erro] $1${NC}"; }
info() { echo -e "${YELLOW}[..] $1${NC}"; }

info "Testando conexao com Kong em $KONG_ADMIN..."
if ! curl -sf "$KONG_ADMIN/status" > /dev/null; then
    err "Kong nao esta respondendo em $KONG_ADMIN"
    exit 1
fi
ok "Kong online"

upsert_service() {
    curl -sf -X PUT "$KONG_ADMIN/services/$1" -d "url=$2" > /dev/null \
        && ok "servico $1 -> $2" || err "falha no servico $1"
}

upsert_route() {
    curl -sf -X PUT "$KONG_ADMIN/routes/$1" \
        -d "service.name=$2" \
        -d "paths[]=$3" \
        -d "strip_path=false" > /dev/null \
        && ok "rota $3 -> $2" || err "falha na rota $1"
}

echo ""
echo "=========== SERVICOS ==========="
# Apenas servicos com API HTTP.
# payments-api e um Worker Service (consome RabbitMQ) e nao expoe HTTP,
# por isso nao recebe rota no gateway.
upsert_service "users-api"   "http://users-api:8080"
upsert_service "catalog-api" "http://catalog-api:8080"

echo ""
echo "=========== ROTAS ==========="
upsert_route "users-route"    "users-api"   "/api/users"
upsert_route "auth-route"     "users-api"   "/api/auth"
upsert_route "profiles-route" "users-api"   "/api/profiles"
upsert_route "catalog-route"  "catalog-api" "/api/catalog"
upsert_route "games-route"    "catalog-api" "/api/games"

# GET /api/users/{id}/library vive no catalog-api (biblioteca de jogos), mas o
# prefixo /api/users acima aponta para o users-api. Uma rota regex mais
# especifica (regex_priority maior) manda so esse caminho para o catalog-api.
curl -sf -X PUT "$KONG_ADMIN/routes/library-route" \
  --data-urlencode "service.name=catalog-api" \
  --data-urlencode "strip_path=false" \
  --data-urlencode "regex_priority=10" \
  --data-urlencode 'paths[]=~/api/users/[^/]*/library$' > /dev/null \
  && ok "rota /api/users/{id}/library -> catalog-api" || err "falha na rota library-route"

echo ""
echo "=========== PLUGINS ==========="

# Cria um plugin e diferencia os desfechos: 201 = criado, 409 = ja existia
# (idempotencia), qualquer outro status = ERRO real (nao esconder falhas).
# Uso: post_plugin <descricao> <url-do-escopo> <args-curl...>
post_plugin() {
  local desc="$1" url="$2"; shift 2
  local out code
  out=$(curl -s -o /tmp/kong-plugin.out -w "%{http_code}" -X POST "$url" "$@")
  code="$out"
  case "$code" in
    201) ok "$desc" ;;
    409) info "$desc (ja configurado)" ;;
    *)   err "$desc - HTTP $code: $(head -c 300 /tmp/kong-plugin.out)" ;;
  esac
}

post_plugin "rate-limiting: 100 req/min em users-api" "$KONG_ADMIN/services/users-api/plugins" \
  -d "name=rate-limiting" -d "config.minute=100" -d "config.policy=local"

# Campos de lista do Kong (methods/headers/origins) exigem um parametro por item
# (campo[]=valor) - passar "GET,POST,..." num valor so e rejeitado com HTTP 400.
post_plugin "CORS global" "$KONG_ADMIN/plugins" \
  -d "name=cors" \
  -d "config.origins[]=*" \
  -d "config.methods[]=GET"  -d "config.methods[]=POST"    -d "config.methods[]=PUT" \
  -d "config.methods[]=DELETE" -d "config.methods[]=OPTIONS" -d "config.methods[]=PATCH" \
  -d "config.headers[]=Content-Type" -d "config.headers[]=Authorization"

# JWT apenas na rota protegida, NAO no servico inteiro: aplicar no servico
# bloquearia /api/auth (login) e criaria um impasse - sem login nao ha
# token, e sem token nao se faz login.
post_plugin "JWT exigido em /api/users (login em /api/auth segue aberto)" "$KONG_ADMIN/routes/users-route/plugins" \
  -d "name=jwt"

echo ""
echo "=========== CONSUMER ==========="
curl -sf -X PUT "$KONG_ADMIN/consumers/$CONSUMER_NAME" > /dev/null 2>&1 \
  && ok "consumer '$CONSUMER_NAME'" || info "consumer ja existe"

# O plugin JWT do Kong usa o claim "iss" do token para achar a credencial
# a validar. O users-api gera tokens com iss=FiapCloudGames (appsettings.json),
# entao a credencial precisa usar exatamente esse valor como "key" e o
# MESMO secret usado pela API para assinar - assim o Kong valida os tokens
# reais emitidos pelo /api/auth/login, em vez de exigir um token proprio do Kong.
JWT_ISSUER="FiapCloudGames"
JWT_APP_SECRET="FCG_SUPER_SECRET_KEY_CHANGE_IN_PRODUCTION_32CHARS!"

curl -sf -X POST "$KONG_ADMIN/consumers/$CONSUMER_NAME/jwt" \
  -d "key=$JWT_ISSUER" \
  -d "algorithm=HS256" \
  -d "secret=$JWT_APP_SECRET" > /dev/null 2>&1 \
  && ok "credencial JWT criada (key=$JWT_ISSUER, mesmo secret da API)" \
  || info "credencial JWT ja configurada para $JWT_ISSUER"

echo ""
echo "=========== VERIFICACAO ==========="
echo "Servicos : $(curl -s "$KONG_ADMIN/services" | grep -o '"name"' | wc -l)"
echo "Rotas    : $(curl -s "$KONG_ADMIN/routes"   | grep -o '"paths"' | wc -l)"
echo ""
ok "Kong configurado."
echo ""
echo "Testes:"
echo "  curl http://localhost:8000/api/catalog/games   # aberto"
echo "  curl http://localhost:8000/api/users           # exige JWT (401 sem token)"
