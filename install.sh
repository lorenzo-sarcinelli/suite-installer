#!/usr/bin/env bash
set -e

#==============================================================================
# INSTALLER V5.5 - "Typebot Endpoint Fix"
# Features: V5.4 + Correção do S3_ENDPOINT no Typebot.
#==============================================================================

# --- CORES & FORMATACAO ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

INSTALL_DIR="/opt/stack"

# --- VARIAVEIS GLOBAIS (Defaults) ---
ENABLE_TRAEFIK=true
ENABLE_PORTAINER=false
ENABLE_MINIO=false
ENABLE_N8N=false
ENABLE_TYPEBOT=false
ENABLE_EVOLUTION=false
ENABLE_WORDPRESS=false
ENABLE_RABBIT=false
ENABLE_PGADMIN=false
ENABLE_PMA=false

# Flags de Dependencia
NEED_POSTGRES=false
NEED_MYSQL=false
NEED_REDIS=false

# Flags de Controle
PREVIOUS_INSTALL=false

# --- FUNÇÕES AUXILIARES ---

print_header() {
    clear
    echo -e "${MAGENTA}${BOLD}"
    cat << "EOF"
████████╗██╗  ██╗███████╗    ███████╗████████╗ █████╗  ██████╗██╗  ██╗
╚══██╔══╝██║  ██║██╔════╝    ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝
   ██║   ███████║█████╗      ███████╗   ██║   ███████║██║     █████╔╝ 
   ██║   ██║  ██║██╔══╝      ╚════██║   ██║   ██╔══██║██║     ██╔═██╗ 
   ██║   ██║  ██║███████╗    ███████║   ██║   ██║  ██║╚██████╗██║  ██╗
   ╚═╝   ╚═╝  ╚═╝╚══════╝    ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝

Tracking Highend - Installer V2.0
EOF
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_input() { echo -e "${CYAN}[INPUT]${NC} $1"; }

# --- ETAPA 0: CARREGAMENTO DE ESTADO ---

load_state() {
    if [ -f "$INSTALL_DIR/.env" ]; then
        log_info "Instalação anterior detectada em $INSTALL_DIR"
        PREVIOUS_INSTALL=true
        set -a
        source "$INSTALL_DIR/.env"
        set +a
        ENABLE_MINIO=${ENABLE_MINIO:-false}
        log_info "Configurações carregadas: ${WHITE}${BASE_DOMAIN}${NC}"
    else
        log_info "Iniciando instalação limpa."
    fi
    sleep 1
}

ask_cleanup() {
    print_header
    echo -e "${CYAN}--- GESTÃO DE AMBIENTE ---${NC}"
    if [ "$PREVIOUS_INSTALL" = true ]; then
        echo -e "${YELLOW}ATENÇÃO: Instalação existente.${NC}"
        echo "1) ATUALIZAR (Recomendado - Aplica novas configs)"
        echo "2) LIMPEZA TOTAL (Apaga TUDO)"
        echo "3) Sair"
        read -p "Opção [1-3]: " -r OPT
        case $OPT in
            1) log_info "Atualizando..." ;;
            2)
                read -p "Digite 'APAGAR' para confirmar: " -r CONFIRM
                if [ "$CONFIRM" == "APAGAR" ]; then
                    log_warn "Destruindo ambiente..."
                    cd $INSTALL_DIR 2>/dev/null || true
                    docker compose down 2>/dev/null || true
                    rm -rf $INSTALL_DIR
                    PREVIOUS_INSTALL=false
                    unset BASE_DOMAIN EMAIL_SSL TRAEFIK_PASS PG_PASS_N8N
                    log_info "Ambiente limpo."
                else
                    exit 0
                fi
                ;;
            *) exit 0 ;;
        esac
    else
        mkdir -p $INSTALL_DIR
    fi
}

install_base_deps() {
    if ! command -v docker >/dev/null; then
        echo -e "\n${CYAN}--- DEPENDÊNCIAS ---${NC}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release apache2-utils openssl git
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh > /dev/null 2>&1
        rm get-docker.sh
    fi
}

# --- ETAPA 1: SELEÇÃO ---

toggle_service() {
    local SERVICE_NAME=$1
    local CURRENT_VAL=$2
    local VAR_NAME=$3
    STATUS="${RED}[DESATIVADO]${NC}"
    if [ "$CURRENT_VAL" = true ]; then STATUS="${GREEN}[ATIVADO]${NC}"; fi
    read -p "$(echo -e "${WHITE}$SERVICE_NAME${NC} está $STATUS. Mudar? [S/N]: ")" -r opt
    if [[ $opt =~ ^[Ss]$ ]]; then
        if [ "$CURRENT_VAL" = true ]; then eval "$VAR_NAME=false"; else eval "$VAR_NAME=true"; fi
    fi
}

selection_menu() {
    print_header
    echo -e "${CYAN}--- MENU ---${NC}"
    toggle_service "Portainer" "$ENABLE_PORTAINER" "ENABLE_PORTAINER"
    toggle_service "MinIO (S3 Server)" "$ENABLE_MINIO" "ENABLE_MINIO"
    toggle_service "N8N Cluster" "$ENABLE_N8N" "ENABLE_N8N"
    toggle_service "Typebot" "$ENABLE_TYPEBOT" "ENABLE_TYPEBOT"
    toggle_service "Evolution API" "$ENABLE_EVOLUTION" "ENABLE_EVOLUTION"
    toggle_service "WordPress" "$ENABLE_WORDPRESS" "ENABLE_WORDPRESS"
    echo -e "\n${YELLOW}--- TOOLS ---${NC}"
    toggle_service "RabbitMQ" "$ENABLE_RABBIT" "ENABLE_RABBIT"
    toggle_service "pgAdmin" "$ENABLE_PGADMIN" "ENABLE_PGADMIN"
    toggle_service "phpMyAdmin" "$ENABLE_PMA" "ENABLE_PMA"

    NEED_POSTGRES=false; NEED_MYSQL=false; NEED_REDIS=false
    if [ "$ENABLE_N8N" = true ] || [ "$ENABLE_TYPEBOT" = true ] || [ "$ENABLE_EVOLUTION" = true ] || [ "$ENABLE_PGADMIN" = true ]; then NEED_POSTGRES=true; fi
    if [ "$ENABLE_N8N" = true ] || [ "$ENABLE_TYPEBOT" = true ] || [ "$ENABLE_EVOLUTION" = true ]; then NEED_REDIS=true; fi
    if [ "$ENABLE_WORDPRESS" = true ] || [ "$ENABLE_PMA" = true ]; then NEED_MYSQL=true; fi
}

# --- ETAPA 2: CONFIGURAÇÃO ---

collect_info() {
    print_header
    echo -e "${CYAN}--- CONFIGURAÇÃO ---${NC}"
    if [ -n "$BASE_DOMAIN" ]; then
        read -p "Manter domínio base '${BASE_DOMAIN}'? [S/n]: " -r keep_dom
        if [[ $keep_dom =~ ^[Nn]$ ]]; then unset BASE_DOMAIN; fi
    fi
    if [ -z "$BASE_DOMAIN" ]; then
        while true; do
            echo -n "Novo Domínio Base (ex: empresa.com): "
            read -r BASE_DOMAIN
            if [[ "$BASE_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then break; fi; echo -e "${RED}Inválido.${NC}"
        done
    fi

    DOMAIN_TRAEFIK="traefik.${BASE_DOMAIN}"
    DOMAIN_PORTAINER="portainer.${BASE_DOMAIN}"
    DOMAIN_MINIO_CONSOLE="minio.${BASE_DOMAIN}"
    DOMAIN_MINIO_API="s3.${BASE_DOMAIN}"
    DOMAIN_N8N="n8n.${BASE_DOMAIN}"
    DOMAIN_N8N_WEBHOOK="webhook.${BASE_DOMAIN}"
    DOMAIN_EVOLUTION="evolution.${BASE_DOMAIN}"
    DOMAIN_TYPEBOT="typebot.${BASE_DOMAIN}"
    DOMAIN_TYPEBOT_VIEWER="bot.${BASE_DOMAIN}"
    DOMAIN_RABBIT="rabbit.${BASE_DOMAIN}"
    DOMAIN_PGADMIN="pgadmin.${BASE_DOMAIN}"
    DOMAIN_WORDPRESS="wordpress.${BASE_DOMAIN}"
    DOMAIN_PMA="pma.${BASE_DOMAIN}"

    if [ -n "$EMAIL_SSL" ]; then
        read -p "Manter Email SSL '${EMAIL_SSL}'? [S/n]: " -r keep_email
        if [[ $keep_email =~ ^[Nn]$ ]]; then unset EMAIL_SSL; fi
    fi
    if [ -z "$EMAIL_SSL" ]; then
        read -p "Email SSL: " EMAIL_SSL_VAL
        EMAIL_SSL=${EMAIL_SSL_VAL:-admin@${BASE_DOMAIN}}
    fi

    if [ "$ENABLE_TYPEBOT" = true ] || [ "$ENABLE_WORDPRESS" = true ] || [ "$ENABLE_N8N" = true ]; then
        echo -e "\n${YELLOW}SMTP Config${NC}"
        if [ -n "$SMTP_HOST" ]; then
            read -p "Manter SMTP existente? [S/n]: " -r keep_smtp
            if [[ $keep_smtp =~ ^[Nn]$ ]]; then unset SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_FROM; fi
        fi
        if [ -z "$SMTP_HOST" ]; then
            read -p "Possui SMTP? [s/n]: " -r has_smtp
            if [[ $has_smtp =~ ^[Ss]$ ]]; then
                read -p "Host: " SMTP_HOST; read -p "Port: " SMTP_PORT; read -p "User: " SMTP_USER
                read -p "Pass: " SMTP_PASS; read -p "From: " SMTP_FROM
            else
                SMTP_HOST="smtp.fake.com"; SMTP_PORT="587"; SMTP_USER="user"; SMTP_PASS="pass"; SMTP_FROM="noreply@$BASE_DOMAIN"
            fi
        fi
    fi

    log_info "Gerando credenciais..."
    TRAEFIK_PASS=${TRAEFIK_PASS:-$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)}
    TRAEFIK_HASH_RAW=$(htpasswd -nbB admin "$TRAEFIK_PASS")
    TRAEFIK_AUTH=$(echo "$TRAEFIK_HASH_RAW" | sed 's/\$/\$\$/g' | tr -d '\n')
    PG_PASS_N8N=${PG_PASS_N8N:-$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)}
    PG_PASS_EVO=${PG_PASS_EVO:-$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)}
    PG_PASS_TYPEBOT=${PG_PASS_TYPEBOT:-$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)}
    MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS:-$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)}
    WP_DB_PASS=${WP_DB_PASS:-$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)}
    REDIS_PASS=${REDIS_PASSWORD:-$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)}
    N8N_KEY=${N8N_ENCRYPTION_KEY:-$(openssl rand -base64 24)}
    EVO_API_KEY=${EVOLUTION_API_KEY:-$(openssl rand -hex 32)}
    TYPEBOT_ENC_KEY=${TYPEBOT_ENC_KEY:-$(openssl rand -base64 24)}
    RABBIT_PASS=${RABBIT_PASS:-$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)}
    PGADMIN_PASS=${PGADMIN_PASS:-$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)}
    MINIO_ROOT_USER=${MINIO_ROOT_USER:-"admin"}
    MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)}
}

# --- ETAPA 3: GERAÇÃO DE ARQUIVOS ---

generate_files() {
    print_header
    echo -e "${CYAN}--- GERAÇÃO DOCKER COMPOSE ---${NC}"
    mkdir -p $INSTALL_DIR/traefik
    touch $INSTALL_DIR/traefik/acme.json && chmod 600 $INSTALL_DIR/traefik/acme.json

    cat > $INSTALL_DIR/.env <<EOF
BASE_DOMAIN=${BASE_DOMAIN}
EMAIL_SSL=${EMAIL_SSL}
ENABLE_TRAEFIK=${ENABLE_TRAEFIK}
ENABLE_PORTAINER=${ENABLE_PORTAINER}
ENABLE_MINIO=${ENABLE_MINIO}
ENABLE_N8N=${ENABLE_N8N}
ENABLE_TYPEBOT=${ENABLE_TYPEBOT}
ENABLE_EVOLUTION=${ENABLE_EVOLUTION}
ENABLE_WORDPRESS=${ENABLE_WORDPRESS}
ENABLE_RABBIT=${ENABLE_RABBIT}
ENABLE_PGADMIN=${ENABLE_PGADMIN}
ENABLE_PMA=${ENABLE_PMA}
TRAEFIK_PASS=${TRAEFIK_PASS}
TRAEFIK_AUTH=${TRAEFIK_AUTH}
PG_PASS_N8N=${PG_PASS_N8N}
PG_PASS_EVO=${PG_PASS_EVO}
PG_PASS_TYPEBOT=${PG_PASS_TYPEBOT}
MYSQL_ROOT_PASS=${MYSQL_ROOT_PASS}
WP_DB_PASS=${WP_DB_PASS}
REDIS_PASSWORD=${REDIS_PASS}
N8N_ENCRYPTION_KEY=${N8N_KEY}
EVOLUTION_API_KEY=${EVO_API_KEY}
TYPEBOT_ENC_KEY=${TYPEBOT_ENC_KEY}
RABBIT_PASS=${RABBIT_PASS}
PGADMIN_PASS=${PGADMIN_PASS}
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_FROM=${SMTP_FROM}
WP_SMTP_HOST=${SMTP_HOST}
WP_SMTP_PORT=${SMTP_PORT}
WP_SMTP_USER=${SMTP_USER}
WP_SMTP_PASS=${SMTP_PASS}
WP_SMTP_FROM=${SMTP_FROM}
N8N_SMTP_HOST=${SMTP_HOST}
N8N_SMTP_PORT=${SMTP_PORT}
N8N_SMTP_USER=${SMTP_USER}
N8N_SMTP_PASS=${SMTP_PASS}
N8N_SMTP_SENDER=${SMTP_FROM}
DOMAIN_TRAEFIK=${DOMAIN_TRAEFIK}
DOMAIN_PORTAINER=${DOMAIN_PORTAINER}
DOMAIN_MINIO_CONSOLE=${DOMAIN_MINIO_CONSOLE}
DOMAIN_MINIO_API=${DOMAIN_MINIO_API}
DOMAIN_N8N=${DOMAIN_N8N}
DOMAIN_N8N_WEBHOOK=${DOMAIN_N8N_WEBHOOK}
DOMAIN_EVOLUTION=${DOMAIN_EVOLUTION}
DOMAIN_TYPEBOT=${DOMAIN_TYPEBOT}
DOMAIN_TYPEBOT_VIEWER=${DOMAIN_TYPEBOT_VIEWER}
DOMAIN_RABBIT=${DOMAIN_RABBIT}
DOMAIN_PGADMIN=${DOMAIN_PGADMIN}
DOMAIN_WORDPRESS=${DOMAIN_WORDPRESS}
DOMAIN_PMA=${DOMAIN_PMA}
EOF

    (
    cat <<EOF
x-n8n-shared: &n8n-shared
  image: n8nio/n8n:2.0.0
  restart: unless-stopped
  depends_on:
    n8n_postgres: { condition: service_healthy }
    redis_cache: { condition: service_started }
  environment:
    - DB_TYPE=postgresdb
    - DB_POSTGRESDB_HOST=n8n_postgres
    - DB_POSTGRESDB_PORT=5432
    - DB_POSTGRESDB_DATABASE=n8n
    - DB_POSTGRESDB_USER=n8n_user
    - DB_POSTGRESDB_PASSWORD=\${PG_PASS_N8N}
    - WEBHOOK_URL=https://\${DOMAIN_N8N_WEBHOOK}
    - N8N_EDITOR_BASE_URL=https://\${DOMAIN_N8N}
    - EXECUTIONS_MODE=queue
    - N8N_PROXY_HOPS=1
    - N8N_TRUST_PROXY=true
    - QUEUE_BULL_REDIS_HOST=redis_cache
    - QUEUE_BULL_REDIS_PORT=6379
    - QUEUE_BULL_REDIS_PASSWORD=\${REDIS_PASSWORD}
    - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
    - N8N_ENABLE_CLUSTER_MODE=true
    - GENERIC_TIMEZONE=America/Sao_Paulo
    - N8N_EMAIL_MODE=smtp
    - N8N_SMTP_HOST=\${N8N_SMTP_HOST}
    - N8N_SMTP_PORT=\${N8N_SMTP_PORT}
    - N8N_SMTP_USER=\${N8N_SMTP_USER}
    - N8N_SMTP_PASS=\${N8N_SMTP_PASS}
    - N8N_SMTP_SSL=true
    - N8N_SMTP_SENDER=\${N8N_SMTP_SENDER}
  networks: [ traefik-net ]
  extra_hosts: [ 'host.docker.internal:host-gateway' ]

services:
  traefik:
    image: 'traefik:latest'
    container_name: 'traefik'
    restart: unless-stopped
    ports: [ '80:80', '443:443' ]
    environment:
      - DOCKER_CLIENT_API_VERSION=1.44
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=traefik-net
      - --entrypoints.web.address=:80
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --entrypoints.websecure.address=:443
      - --api.dashboard=true
      - --certificatesresolvers.letsencryptresolver.acme.email=\${EMAIL_SSL}
      - --certificatesresolvers.letsencryptresolver.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencryptresolver.acme.httpchallenge=true
      - --certificatesresolvers.letsencryptresolver.acme.httpchallenge.entrypoint=web
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
      - './traefik/acme.json:/letsencrypt/acme.json'
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.traefik.rule=Host(\`\${DOMAIN_TRAEFIK}\`)'
      - 'traefik.http.routers.traefik.service=api@internal'
      - 'traefik.http.routers.traefik.middlewares=auth'
      - 'traefik.http.middlewares.auth.basicauth.users=\${TRAEFIK_AUTH}' 
      - 'traefik.http.routers.traefik.tls.certresolver=letsencryptresolver'

EOF

    if [ "$NEED_POSTGRES" = true ]; then
        cat <<EOF
  n8n_postgres:
    image: postgres:16
    container_name: 'n8n_postgres'
    restart: unless-stopped
    environment:
      - POSTGRES_DB=n8n
      - POSTGRES_USER=n8n_user
      - POSTGRES_PASSWORD=\${PG_PASS_N8N}
    volumes: [ 'postgres_data:/var/lib/postgresql/data' ]
    networks: [ traefik-net ]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n_user -d n8n || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5

EOF
    fi

    if [ "$NEED_REDIS" = true ]; then
        cat <<EOF
  redis_cache:
    image: redis:7-alpine
    container_name: 'redis_cache'
    restart: unless-stopped
    command: redis-server --requirepass \${REDIS_PASSWORD}
    volumes: [ 'redis_data:/data' ]
    networks: [ traefik-net ]

EOF
    fi

    if [ "$NEED_MYSQL" = true ]; then
        cat <<EOF
  mysql_db:
    image: mysql:8.0
    container_name: 'mysql_db'
    restart: unless-stopped
    environment:
      - MYSQL_DATABASE=wordpress
      - MYSQL_USER=wordpress
      - MYSQL_PASSWORD=\${WP_DB_PASS}
      - MYSQL_ROOT_PASSWORD=\${MYSQL_ROOT_PASS}
    volumes: [ 'mysql_data:/var/lib/mysql' ]
    networks: [ traefik-net ]

EOF
    fi

    if [ "$ENABLE_MINIO" = true ]; then
        cat <<EOF
  minio:
    image: minio/minio:latest
    container_name: minio
    restart: always
    command: server /data --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=\${MINIO_ROOT_USER}
      - MINIO_ROOT_PASSWORD=\${MINIO_ROOT_PASSWORD}
      - MINIO_SERVER_URL=https://\${DOMAIN_MINIO_API}
      - MINIO_BROWSER_REDIRECT_URL=https://\${DOMAIN_MINIO_CONSOLE}
      - MINIO_API_CORS_ALLOW_ORIGIN=*
    volumes:
      - minio_data:/data
    networks: [ traefik-net ]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.minio-api.rule=Host(\`\${DOMAIN_MINIO_API}\`)"
      - "traefik.http.routers.minio-api.service=minio-api"
      - "traefik.http.routers.minio-api.tls.certresolver=letsencryptresolver"
      - "traefik.http.services.minio-api.loadbalancer.server.port=9000"
      - "traefik.http.routers.minio-console.rule=Host(\`\${DOMAIN_MINIO_CONSOLE}\`)"
      - "traefik.http.routers.minio-console.service=minio-console"
      - "traefik.http.routers.minio-console.tls.certresolver=letsencryptresolver"
      - "traefik.http.services.minio-console.loadbalancer.server.port=9001"

  minio_init:
    image: minio/mc
    depends_on: [ minio ]
    networks: [ traefik-net ]
    entrypoint: >
      /bin/sh -c "
      until (mc alias set myminio http://minio:9000 \${MINIO_ROOT_USER} \${MINIO_ROOT_PASSWORD}); do echo 'Aguardando MinIO...'; sleep 5; done;
      mc mb --ignore-existing myminio/typebot;
      mc mb --ignore-existing myminio/evolution;
      mc mb --ignore-existing myminio/n8n;
      mc anonymous set download myminio/typebot;
      mc anonymous set download myminio/evolution;
      exit 0;
      "
EOF
    fi

    if [ "$ENABLE_N8N" = true ]; then
        cat <<EOF
  n8n_editor:
    <<: *n8n-shared
    container_name: 'n8n_editor'
    command: start
    ports: ["5678:5678"]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.n8n.rule=Host(\`\${DOMAIN_N8N}\`)'
      - 'traefik.http.routers.n8n.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.n8n.loadbalancer.server.port=5678'
  n8n_webhook:
    <<: *n8n-shared
    container_name: 'n8n_webhook'
    command: webhook
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.n8n-webhook.rule=Host(\`\${DOMAIN_N8N_WEBHOOK}\`)'
      - 'traefik.http.routers.n8n-webhook.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.n8n-webhook.loadbalancer.server.port=5678'
  n8n_worker:
    <<: *n8n-shared
    container_name: 'n8n_worker'
    command: worker --concurrency=10

EOF
    fi

    if [ "$ENABLE_EVOLUTION" = true ]; then
        S3_EVO_CONFIG=""
        if [ "$ENABLE_MINIO" = true ]; then
            S3_EVO_CONFIG="
      - STORE_TYPE=s3
      - S3_ENABLED=true
      - S3_ACCESS_KEY=\${MINIO_ROOT_USER}
      - S3_SECRET_KEY=\${MINIO_ROOT_PASSWORD}
      - S3_BUCKET=evolution
      - S3_PORT=443
      - S3_ENDPOINT=\${DOMAIN_MINIO_API}
      - S3_USE_SSL=true
      - S3_REGION=us-east-1"
        fi
        cat <<EOF
  evolutionAPI:
    image: 'evoapicloud/evolution-api:v2.3.7'
    container_name: 'evolutionAPI'
    restart: always
    environment:
      - SERVER_URL=https://\${DOMAIN_EVOLUTION}
      - AUTHENTICATION_API_KEY=\${EVOLUTION_API_KEY}
      - DATABASE_PROVIDER=postgresql
      - DATABASE_CONNECTION_URI=postgresql://evolution:\${PG_PASS_EVO}@n8n_postgres:5432/evolution
      - DATABASE_CLIENT_NAME=evolution_exchange
      - CACHE_REDIS_ENABLED=true
      - CACHE_REDIS_URI=redis://:\${REDIS_PASSWORD}@redis_cache:6379/1
      - CACHE_REDIS_PREFIX_KEY=evolution
      $S3_EVO_CONFIG
    depends_on:
      redis_cache: { condition: service_started }
      n8n_postgres: { condition: service_healthy }
    volumes:
      - 'evolution_store:/evolution/store'
      - 'evolution_instances:/evolution/instances'
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.evolutionAPI.rule=Host(\`\${DOMAIN_EVOLUTION}\`)'
      - 'traefik.http.routers.evolutionAPI.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.evolutionAPI.loadbalancer.server.port=8080'

EOF
    fi

    if [ "$ENABLE_TYPEBOT" = true ]; then
        S3_TB_CONFIG=""
        if [ "$ENABLE_MINIO" = true ]; then
            # CORREÇÃO CRÍTICA AQUI: S3_ENDPOINT sem HTTPS para Typebot (Fix V5.5)
            S3_TB_CONFIG="
      - S3_ENDPOINT=\${DOMAIN_MINIO_API}
      - S3_ACCESS_KEY=\${MINIO_ROOT_USER}
      - S3_SECRET_KEY=\${MINIO_ROOT_PASSWORD}
      - S3_BUCKET=typebot
      - S3_PORT=443
      - S3_SSL=true
      - S3_REGION=us-east-1
      - S3_FORCE_PATH_STYLE=true"
        fi
        cat <<EOF
  typebot_builder:
    image: baptistearno/typebot-builder:latest
    container_name: typebot_builder
    restart: always
    environment:
      - DATABASE_URL=postgresql://typebot:\${PG_PASS_TYPEBOT}@n8n_postgres:5432/typebot
      - NEXTAUTH_URL=https://\${DOMAIN_TYPEBOT}
      - NEXT_PUBLIC_VIEWER_URL=https://\${DOMAIN_TYPEBOT_VIEWER}
      - ENCRYPTION_SECRET=\${TYPEBOT_ENC_KEY}
      - ADMIN_EMAIL=\${EMAIL_SSL}
      - SMTP_HOST=\${SMTP_HOST}
      - SMTP_PORT=\${SMTP_PORT}
      - SMTP_USERNAME=\${SMTP_USER}
      - SMTP_PASSWORD=\${SMTP_PASS}
      - NEXT_PUBLIC_SMTP_FROM=\${SMTP_FROM}
      $S3_TB_CONFIG
    depends_on:
      n8n_postgres: { condition: service_healthy }
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.typebot-builder.rule=Host(\`\${DOMAIN_TYPEBOT}\`)'
      - 'traefik.http.routers.typebot-builder.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.typebot-builder.loadbalancer.server.port=3000'
  typebot_viewer:
    image: baptistearno/typebot-viewer:latest
    container_name: typebot_viewer
    restart: always
    environment:
      - DATABASE_URL=postgresql://typebot:\${PG_PASS_TYPEBOT}@n8n_postgres:5432/typebot
      - NEXT_PUBLIC_VIEWER_URL=https://\${DOMAIN_TYPEBOT_VIEWER}
      - NEXTAUTH_URL=https://\${DOMAIN_TYPEBOT}
      - ENCRYPTION_SECRET=\${TYPEBOT_ENC_KEY}
      $S3_TB_CONFIG
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.typebot-viewer.rule=Host(\`\${DOMAIN_TYPEBOT_VIEWER}\`)'
      - 'traefik.http.routers.typebot-viewer.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.typebot-viewer.loadbalancer.server.port=3000'

EOF
    fi

    if [ "$ENABLE_WORDPRESS" = true ]; then
        cat <<EOF
  wordpress:
    image: wordpress:latest
    container_name: wordpress
    restart: always
    depends_on: [ mysql_db ]
    environment:
      - WORDPRESS_DB_HOST=mysql_db:3306
      - WORDPRESS_DB_USER=wordpress
      - WORDPRESS_DB_PASSWORD=\${WP_DB_PASS}
      - WORDPRESS_DB_NAME=wordpress
      - SMTP_HOST=\${WP_SMTP_HOST}
      - SMTP_PORT=\${WP_SMTP_PORT}
      - SMTP_USER=\${WP_SMTP_USER}
      - SMTP_PASS=\${WP_SMTP_PASS}
      - SMTP_FROM=\${WP_SMTP_FROM}
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.wordpress.rule=Host(\`\${DOMAIN_WORDPRESS}\`)'
      - 'traefik.http.routers.wordpress.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.wordpress.loadbalancer.server.port=80'

EOF
    fi

    if [ "$ENABLE_PORTAINER" = true ]; then
        cat <<EOF
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock'
      - 'portainer_data:/data'
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.portainer.rule=Host(\`\${DOMAIN_PORTAINER}\`)'
      - 'traefik.http.routers.portainer.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.portainer.loadbalancer.server.port=9000'

EOF
    fi

    if [ "$ENABLE_RABBIT" = true ]; then
        cat <<EOF
  rabbitmq:
    image: rabbitmq:3-management
    container_name: rabbitmq
    restart: always
    environment:
      - RABBITMQ_DEFAULT_USER=admin
      - RABBITMQ_DEFAULT_PASS=\${RABBIT_PASS}
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.rabbitmq.rule=Host(\`\${DOMAIN_RABBIT}\`)'
      - 'traefik.http.routers.rabbitmq.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.rabbitmq.loadbalancer.server.port=15672'

EOF
    fi

    if [ "$ENABLE_PGADMIN" = true ]; then
        cat <<EOF
  pgadmin:
    image: dpage/pgadmin4
    container_name: pgadmin
    restart: always
    environment:
      - PGADMIN_DEFAULT_EMAIL=\${EMAIL_SSL}
      - PGADMIN_DEFAULT_PASSWORD=\${PGADMIN_PASS}
      - PGADMIN_LISTEN_ADDRESS=0.0.0.0
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.pgadmin.rule=Host(\`\${DOMAIN_PGADMIN}\`)'
      - 'traefik.http.routers.pgadmin.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.pgadmin.loadbalancer.server.port=80'

EOF
    fi

    if [ "$ENABLE_PMA" = true ]; then
        cat <<EOF
  phpmyadmin:
    image: phpmyadmin/phpmyadmin:latest
    container_name: 'phpmyadmin'
    depends_on: [ mysql_db ]
    environment:
      - PMA_HOST=mysql_db
      - PMA_ARBITRARY=0
    networks: [ traefik-net ]
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.pma.rule=Host(\`\${DOMAIN_PMA}\`)'
      - 'traefik.http.routers.pma.tls.certresolver=letsencryptresolver'
      - 'traefik.http.services.pma.loadbalancer.server.port=80'

EOF
    fi

    cat <<EOF
networks:
  traefik-net:
    driver: bridge
volumes:
  portainer_data:
  redis_data:
  postgres_data:
  n8n_data:
  mysql_data:
  evolution_store:
  evolution_instances:
  minio_data:
EOF
    ) | tr -d '\r' > "$INSTALL_DIR/docker-compose.yml"
}

# --- ETAPA 4: DEPLOY ---

deploy_stack() {
    print_header
    echo -e "${CYAN}--- DEPLOY ---${NC}"
    cd $INSTALL_DIR
    set -a; source .env; set +a
    docker compose pull

    if [ "$NEED_POSTGRES" = true ] || [ "$NEED_MYSQL" = true ]; then
        log_info "Subindo Bancos & MinIO..."
        SERVICES=""
        [ "$NEED_POSTGRES" = true ] && SERVICES="$SERVICES n8n_postgres"
        [ "$NEED_MYSQL" = true ] && SERVICES="$SERVICES mysql_db"
        [ "$ENABLE_MINIO" = true ] && SERVICES="$SERVICES minio minio_init"
        docker compose up -d $SERVICES
    fi

    if [ "$NEED_POSTGRES" = true ]; then
        log_info "Aguardando Postgres..."
        until docker exec n8n_postgres pg_isready -U n8n_user -d n8n > /dev/null 2>&1; do sleep 2; done
        create_pg_db() {
            local DB=$1; local USER=$2; local PASS=$3
            docker exec n8n_postgres psql -U n8n_user -d n8n -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$USER') THEN CREATE USER $USER WITH PASSWORD '$PASS'; END IF; END \$\$;" >/dev/null 2>&1
            if ! docker exec n8n_postgres psql -U n8n_user -d n8n -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1; then
                 docker exec n8n_postgres psql -U n8n_user -d n8n -c "CREATE DATABASE $DB OWNER $USER;" >/dev/null 2>&1
            fi
            docker exec n8n_postgres psql -U n8n_user -d n8n -c "GRANT ALL PRIVILEGES ON DATABASE $DB TO $USER;" >/dev/null 2>&1
            docker exec n8n_postgres psql -U n8n_user -d $DB -c "GRANT ALL ON SCHEMA public TO $USER;" >/dev/null 2>&1
        }
        [ "$ENABLE_EVOLUTION" = true ] && create_pg_db "evolution" "evolution" "${PG_PASS_EVO}"
        [ "$ENABLE_TYPEBOT" = true ] && create_pg_db "typebot" "typebot" "${PG_PASS_TYPEBOT}"
    fi

    log_info "Subindo restante..."
    docker compose up -d
}

# --- ETAPA 5: RELATÓRIO ---

generate_report() {
    clear
    C_BORDER=$BLUE
    C_LABEL=$WHITE
    C_VAL=$CYAN
    C_TITLE=$MAGENTA

    draw_line() { printf "${C_BORDER} +%s+ ${NC}\n" "$(printf "%-70s" | tr ' ' '-')"; }
    draw_row() { printf "${C_BORDER} | ${C_LABEL}%-20s ${C_BORDER}| ${C_VAL}%-46s ${C_BORDER}| ${NC}\n" "$1" "$2"; }
    draw_title() { printf "${C_BORDER} | ${C_TITLE}%-68s ${C_BORDER}| ${NC}\n" "$1"; }

    echo ""
    draw_line
    draw_title "DNS CHECKLIST"
    draw_line
    echo -e "${YELLOW} Aponte para o IP deste servidor:${NC}"
    [ "$ENABLE_TRAEFIK" = true ] && echo -e " -> ${WHITE}${DOMAIN_TRAEFIK}${NC}"
    [ "$ENABLE_PORTAINER" = true ] && echo -e " -> ${WHITE}${DOMAIN_PORTAINER}${NC}"
    [ "$ENABLE_MINIO" = true ] && echo -e " -> ${WHITE}${DOMAIN_MINIO_CONSOLE}${NC} e ${WHITE}${DOMAIN_MINIO_API}${NC}"
    [ "$ENABLE_N8N" = true ] && echo -e " -> ${WHITE}${DOMAIN_N8N}${NC}"
    [ "$ENABLE_N8N" = true ] && echo -e " -> ${WHITE}${DOMAIN_N8N_WEBHOOK}${NC}"
    [ "$ENABLE_TYPEBOT" = true ] && echo -e " -> ${WHITE}${DOMAIN_TYPEBOT}${NC}"
    [ "$ENABLE_TYPEBOT" = true ] && echo -e " -> ${WHITE}${DOMAIN_TYPEBOT_VIEWER}${NC}"
    [ "$ENABLE_EVOLUTION" = true ] && echo -e " -> ${WHITE}${DOMAIN_EVOLUTION}${NC}"
    [ "$ENABLE_WORDPRESS" = true ] && echo -e " -> ${WHITE}${DOMAIN_WORDPRESS}${NC}"
    [ "$ENABLE_RABBIT" = true ] && echo -e " -> ${WHITE}${DOMAIN_RABBIT}${NC}"
    [ "$ENABLE_PGADMIN" = true ] && echo -e " -> ${WHITE}${DOMAIN_PGADMIN}${NC}"
    [ "$ENABLE_PMA" = true ] && echo -e " -> ${WHITE}${DOMAIN_PMA}${NC}"
    echo ""
    draw_line

    draw_title "CREDENCIAIS"
    draw_line
    draw_row "Traefik" "admin / ${TRAEFIK_PASS}"
    if [ "$ENABLE_MINIO" = true ]; then
        draw_row "MinIO Console" "https://${DOMAIN_MINIO_CONSOLE}"
        draw_row "MinIO API" "https://${DOMAIN_MINIO_API}"
        draw_row "User/Pass" "${MINIO_ROOT_USER} / ${MINIO_ROOT_PASSWORD}"
    fi
    if [ "$ENABLE_PORTAINER" = true ]; then draw_row "Portainer" "https://${DOMAIN_PORTAINER}"; fi
    if [ "$ENABLE_N8N" = true ]; then draw_row "N8N" "https://${DOMAIN_N8N}"; fi
    if [ "$ENABLE_TYPEBOT" = true ]; then draw_row "Typebot" "https://${DOMAIN_TYPEBOT}"; fi
    if [ "$ENABLE_EVOLUTION" = true ]; then draw_row "Evolution" "https://${DOMAIN_EVOLUTION}"; fi
    if [ "$ENABLE_WORDPRESS" = true ]; then draw_row "WordPress" "https://${DOMAIN_WORDPRESS}"; fi
    if [ "$ENABLE_PGADMIN" = true ]; then draw_row "pgAdmin" "https://${DOMAIN_PGADMIN}"; draw_row "User/Pass" "${EMAIL_SSL} / ${PGADMIN_PASS}"; fi
    if [ "$ENABLE_PMA" = true ]; then draw_row "phpMyAdmin" "https://${DOMAIN_PMA}"; fi
    if [ "$ENABLE_RABBIT" = true ]; then draw_row "RabbitMQ" "https://${DOMAIN_RABBIT}"; draw_row "User/Pass" "admin / ${RABBIT_PASS}"; fi
    
    draw_line
    if [ "$NEED_POSTGRES" = true ]; then
        draw_title "POSTGRESQL (Host: n8n_postgres)"
        if [ "$ENABLE_N8N" = true ]; then draw_row "N8N User/Pass" "n8n_user / ${PG_PASS_N8N}"; fi
        if [ "$ENABLE_EVOLUTION" = true ]; then draw_row "Evolution Pass" "evolution / ${PG_PASS_EVO}"; fi
        if [ "$ENABLE_TYPEBOT" = true ]; then draw_row "Typebot Pass" "typebot / ${PG_PASS_TYPEBOT}"; fi
        draw_line
    fi

    if [ "$NEED_REDIS" = true ]; then
        draw_title "REDIS CACHE/QUEUE"
        draw_row "Host Docker" "redis_cache:6379"
        draw_row "Password" "${REDIS_PASS}"
        draw_line
    fi

    draw_title "SEGREDOS & CHAVES"
    if [ "$ENABLE_TYPEBOT" = true ]; then draw_row "Typebot Enc Key" "${TYPEBOT_ENC_KEY}"; fi
    if [ "$ENABLE_N8N" = true ]; then draw_row "N8N Enc Key" "${N8N_KEY}"; fi
    if [ "$NEED_REDIS" = true ]; then draw_row "Redis Pass" "${REDIS_PASS}"; fi
    if [ "$ENABLE_EVOLUTION" = true ]; then draw_row "Evolution API Key" "${EVO_API_KEY}"; fi
    draw_line
    echo -e "${WHITE} Configs em: ${BOLD}${INSTALL_DIR}/.env${NC}\n"
}

main() {
    load_state
    ask_cleanup
    install_base_deps
    selection_menu
    collect_info
    generate_files
    deploy_stack
    generate_report
}

main
