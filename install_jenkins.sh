#!/bin/bash

set -euo pipefail

ROOT_DIR="/projects/jenkins-installation"   # change this if needed
JENKINS_UID=2001
JENKINS_GID=2001

JENKINS_DIR="$ROOT_DIR/jenkins"
COMPOSE_DIR="$ROOT_DIR/docker-compose"
JENKINS_HOME="$JENKINS_DIR/jenkins_home"
SSH_HOST_DIR="$ROOT_DIR/jenkins-ssh"
SECRETS_DIR="$JENKINS_HOME/secrets"

# GIT Setup
GIT_SSH_URL=""
LIB_NAME=""
CRED_ID="git-ssh-private-key"

# AWS / Feature flags
ENABLE_SHARED_LIBS=false
ENABLE_AWS=false
AWS_BUILD_ARGS=""
AWS_ENV_VARS=""

echo "================================================================="
echo " Creating Jenkins Directory Structure"
echo "================================================================="

mkdir -p \
  "$JENKINS_DIR/casc" \
  "$COMPOSE_DIR" \
  "$JENKINS_HOME" \
  "$SSH_HOST_DIR" \
  "$SECRETS_DIR"

echo "================================================================="
echo " Creating host user jenkins:jenkins ($JENKINS_UID:$JENKINS_GID)"
echo "================================================================="

# Create group if not exists
if ! getent group jenkins >/dev/null; then
    sudo groupadd -g "$JENKINS_GID" jenkins || true
    echo "+ Group 'jenkins' created"
else
    echo "Group 'jenkins' already exists — skipping"
fi

# Create user if not exists
if ! id -u jenkins >/dev/null 2>&1; then
    sudo useradd -m -u "$JENKINS_UID" -g "$JENKINS_GID" jenkins || true
    echo "+ User 'jenkins' created"
else
    echo "User 'jenkins' already exists — skipping"
fi

echo "================================================================="
echo " Shared Library Configuration "
echo "If you leave the values empty the shared-library configuration will be skipped."
echo "================================================================="

read -rp "Enter Git SSH URL for shared library (or leave empty to skip): " GIT_SSH_URL
read -rp "Enter Shared Library Name (or leave empty to skip): " LIB_NAME

if [[ -n "${GIT_SSH_URL// /}" && -n "${LIB_NAME// /}" ]]; then
    read -rp "Enter Credential ID to use for the shared library (default: ${CRED_ID}): " tmpcred
    CRED_ID="${tmpcred:-$CRED_ID}"
    ENABLE_SHARED_LIBS=true
    echo "Shared libraries will be configured: repo=${GIT_SSH_URL}, name=${LIB_NAME}, cred=${CRED_ID}"
else
    ENABLE_SHARED_LIBS=false
    echo "Shared library config skipped — one or more fields were empty."
fi

echo "========================================================="
echo " AWS CLI Installation"
echo "========================================================="
read -rp "Enable AWS CLI and credentials inside Jenkins? (y/n): " aws_install
if [[ "$aws_install" = "y" ]]; then
  ENABLE_AWS=true
  echo "aws cli will be configured"
else
  ENABLE_AWS=false
  echo "aws cli installation will be skipped."
fi

echo "================================================================="
echo " Checking Docker Installation"
echo "================================================================="

# Function: get latest docker version available for this OS
get_latest_docker_version() {
    yum --showduplicates list docker-ce --repo=docker-ce-stable 2>/dev/null | awk '/docker-ce.x86_64/ {print $2}' | sort -V | tail -1
}

if command -v docker >/dev/null 2>&1; then
    INSTALLED_VERSION=$(docker --version | awk '{print $3}' | sed 's/,//')
    echo "Docker is already installed (version: $INSTALLED_VERSION)"

    echo "Fetching latest version from Docker CE repository..."
    sudo yum install -y yum-utils curl > /dev/null 2>&1 || true
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    LATEST_VERSION=$(get_latest_docker_version)

    if [[ -z "$LATEST_VERSION" ]]; then
        echo "Unable to determine latest Docker version. Skipping upgrade check."
        LATEST_VERSION="$INSTALLED_VERSION"
    else
        echo "Latest version available: $LATEST_VERSION"
    fi

    # Extract core version numbers (major.minor.patch)
    INSTALLED_CORE="${INSTALLED_VERSION%%-*}"
    LATEST_CORE="$(echo ${LATEST_VERSION##*:} | sed 's/-.*//')"

    if [[ "$INSTALLED_CORE" == "$LATEST_CORE" ]]; then
        echo "You already have the latest Docker version ($INSTALLED_CORE). Skipping upgrade."
        DO_UPGRADE="n"
    else
        read -p "A newer version is available. Upgrade from $INSTALLED_CORE → $LATEST_CORE? (y/n): " DO_UPGRADE
    fi

    if [[ "$DO_UPGRADE" == "y" ]]; then
        echo "Upgrading Docker to version $LATEST_VERSION..."
        sudo yum remove -y docker docker-client docker-common docker-latest docker-engine docker-buildx-plugin containerd.io containerd || true
        sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo systemctl enable --now docker
        echo "Docker upgraded to latest version ($LATEST_VERSION)."
    else
        echo "Skipping Docker upgrade."
    fi
else
    echo "Docker not installed. Installing Docker..."
    sudo yum install -y yum-utils curl
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
    echo "Docker installation complete."
fi

echo "================================================================="
echo " Docker Compose Installation"
echo "================================================================="
# Docker Compose Installation
if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose already installed: $(docker-compose --version)"
else
    echo "Installing docker-compose standalone binary..."
    sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
fi

echo "================================================================="
echo " Enter Jenkins admin username & password"
echo "================================================================="

read -rp "Enter Jenkins admin username (e.g. admin): " ADMIN_USER
read -rsp "Enter Jenkins admin password (input hidden): " ADMIN_PASSWORD
if [[ -z "$ADMIN_USER" || -z "$ADMIN_PASSWORD" ]]; then
  echo "Admin username/password required. Aborting."
  exit 1
fi

echo -n "$ADMIN_PASSWORD" | sudo tee "$SECRETS_DIR/adminPassword" >/dev/null
sudo chmod 600 "$SECRETS_DIR/adminPassword"


echo "================================================================="
echo " Enter SSH private key"
echo "================================================================="
# Detect private keys in ~/.ssh
mapfile -t FOUND_KEYS < <(find "$HOME/.ssh" -maxdepth 1 -type f \( -name 'id_*' -not -name '*.pub' \) -print 2>/dev/null || true)

KEY_PROVIDED=false
SSH_PRIVATE_KEY=""

if (( ${#FOUND_KEYS[@]} > 0 )); then
  echo "Available private keys in ~/.ssh:"
  for i in "${!FOUND_KEYS[@]}"; do
      echo "  [$((i+1))] ${FOUND_KEYS[$i]}"
  done
  echo "  [0] Paste private key now\n"
  read -rp "Select key number to copy into Jenkins host SSH directory (default 1): " sel
  sel="${sel:-1}"
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#FOUND_KEYS[@]} )); then
    KEY_PATH="${FOUND_KEYS[$((sel-1))]}"
    sudo cp "$KEY_PATH" "$SSH_HOST_DIR/id_rsa"
    KEY_PROVIDED=true
    echo "Copied $KEY_PATH -> $SSH_HOST_DIR/id_rsa"
  else
    echo "Paste your private SSH key now. Finish with EOF (Ctrl-D):"
    SSH_PRIVATE_KEY="$(cat -)"
    if [[ -n "${SSH_PRIVATE_KEY// /}" ]]; then
      echo -n "$SSH_PRIVATE_KEY" | sudo tee "$SSH_HOST_DIR/id_rsa" >/dev/null
      KEY_PROVIDED=true
      echo "Wrote SSH key to $SSH_HOST_DIR/id_rsa"
    else
      KEY_PROVIDED=false
    fi
  fi
else
  echo "No private keys found in ~/.ssh"
  echo "Paste your private SSH key now. Finish with EOF (Ctrl-D):"
  SSH_PRIVATE_KEY="$(cat -)"
  if [[ -n "${SSH_PRIVATE_KEY// /}" ]]; then
      echo -n "$SSH_PRIVATE_KEY" | sudo tee "$SSH_HOST_DIR/id_rsa" >/dev/null
      KEY_PROVIDED=true
      echo "Wrote SSH key to $SSH_HOST_DIR/id_rsa"
  else
      KEY_PROVIDED=false
  fi
fi

if [[ "$KEY_PROVIDED" != true ]]; then
  echo "No SSH key provided. Aborting."
  exit 1
fi

# Set permissions/ownership
# Ensure known_hosts contains bitbucket
ssh-keyscan bitbucket.org 2>/dev/null | sudo tee "$SSH_HOST_DIR/known_hosts" >/dev/null || true
sudo chown -R jenkins:jenkins "$SSH_HOST_DIR"
sudo chmod -R 700 "$SSH_HOST_DIR/"
sudo chmod 600 ${SSH_HOST_DIR}/id_rsa

echo "================================================================="
echo " Writing plugins.txt"
echo "================================================================="
# Writing plugins.txt
if [[ ! -f "$JENKINS_DIR/plugins.txt" ]]; then
    cat > "$JENKINS_DIR/plugins.txt" << 'EOF'
additional-metrics
amazon-ecs
ansicolor
antisamy-markup-formatter
audit-trail
authorize-project
azure-ad
build-user-vars-plugin
categorized-view
cloudbees-disk-usage-simple
configuration-as-code
credentials
credentials-binding
dark-theme
dashboard-view
docker-workflow
extended-timer-trigger
file-operations
file-parameters
generic-webhook-trigger
git
hidden-parameter
http_request
job-dsl
list-git-branches-parameter
mask-passwords
matrix-auth
parameterized-trigger
parameter-separator
pipeline-build-step
pipeline-graph-view
pipeline-groovy-lib
pipeline-input-step
pipeline-model-definition
pipeline-stage-step
pipeline-stage-view
pipeline-utility-steps
plain-credentials
rebuild
saferestart
script-security
simple-theme-plugin
slack
ssh-agent
ssh-slaves
ssh-steps
timestamper
uno-choice:2.8.8
validating-string-parameter
versioncolumn
workflow-aggregator
workflow-basic-steps
workflow-cps
workflow-job
workflow-multibranch
workflow-scm-step
ws-cleanup

EOF
    echo "+ Created plugins.txt"
else
    echo "plugins.txt already exists — skipping"
fi

echo "================================================================="
echo " Writing entrypoint.sh "
echo "================================================================="
# Create entrypoint if not exists and only when enable_aws is true
cat > "$JENKINS_DIR/entrypoint.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

MARKER="/var/jenkins_home/.aws/.initialized"

if [[ "${ENABLE_AWS:-false}" == "true" ]]; then
  if [[ ! -f "$MARKER" ]]; then
    echo "[bootstrap] Initializing AWS config"

    mkdir -p /var/jenkins_home/.aws
    cp /aws-bootstrap/config /var/jenkins_home/.aws/config

    chown -R jenkins:jenkins /var/jenkins_home/.aws
    chmod 700 /var/jenkins_home/.aws || true
    chmod 600 /var/jenkins_home/.aws/config || true

    touch "$MARKER"
    chown jenkins:jenkins "$MARKER"

    echo "[bootstrap] AWS config initialized"
  fi
fi

# Run tini as PID 1 and preserve environment variables
exec /usr/bin/tini -s -- "/usr/local/bin/jenkins.sh"

EOF
echo "+ Created entrypoint.sh"

echo "================================================================="
echo " Writing Dockerfile "
echo "================================================================="
# Create Dockerfile if not exists
if [[ ! -f "$JENKINS_DIR/Dockerfile" ]]; then
    cat > "$JENKINS_DIR/Dockerfile" << 'EOF'
FROM jenkins/jenkins:lts-jdk17

USER root

ARG JENKINS_UID=2001
ARG JENKINS_GID=2001
ARG ENABLE_AWS=false

# Combine EVERYTHING into a single RUN layer
RUN set -eux; \
    # fix jenkins user/group
    if getent group jenkins >/dev/null; then \
        groupmod -g ${JENKINS_GID} jenkins; \
    else \
        groupadd -g ${JENKINS_GID} jenkins; \
    fi; \
    if id jenkins >/dev/null 2>&1; then \
        usermod -u ${JENKINS_UID} -g ${JENKINS_GID} jenkins; \
    else \
        useradd -m -d /var/jenkins_home -u ${JENKINS_UID} -g ${JENKINS_GID} jenkins; \
    fi; \
    # install docker cli
    apt-get update; \
    apt-get install -y --no-install-recommends docker-cli curl unzip; \
    if [ "$ENABLE_AWS" = "true" ]; then \
        curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.27.45.zip -o /tmp/awscliv2.zip; \
        unzip -q /tmp/awscliv2.zip -d /tmp; \
        /tmp/aws/install; \
        rm -rf /tmp/aws /tmp/awscliv2.zip; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Copy plugins and casc files
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt; \
    rm -rf /var/jenkins_home/.cache

# Entry point that copies AWS config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
USER jenkins
EOF
    echo "+ Created Dockerfile"
else
    echo "Dockerfile already exists — skipping"
fi

echo "================================================================="
echo " Writing JCasC YAML (jenkins.yaml) - will reference admin secret file and SSH key env"
echo "================================================================="
# ADMIN_USER embedded, ADMIN_PASSWORD will be written to secret file in container by init groovy
cat > "$JENKINS_DIR/casc/jenkins.yaml" << EOF
jenkins:
  systemMessage: "Configured by Jenkins Configuration as Code (JCasC)"
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "${ADMIN_USER}"
          password: \${readFile:/var/jenkins_home/secrets/adminPassword}
  authorizationStrategy:
    globalMatrix:
      permissions:
        - "Overall/Administer:$ADMIN_USER"
        - "Overall/Read:authenticated"
  globalNodeProperties:
    - envVars:
        env:
          - key: AWS_PROFILE
            value: "default"
          - key: AWS_DEFAULT_REGION
            value: "eu-west-1"
          - key: AWS_SDK_LOAD_CONFIG
            value: "1"
          - key: AWS_PAGER
            value: ""

credentials:
  system:
    domainCredentials:
      - domain:
          name: "global"
        credentials:
          - basicSSHUserPrivateKey:
              scope: GLOBAL
              id: "${CRED_ID}"
              username: "git"
              privateKeySource:
                directEntry:
                  privateKey: \${readFile:/var/jenkins_home/.ssh/id_rsa}
              description: "Git SSH key"

unclassified:
  location:
    url: "http://localhost:8080/"
    adminAddress: "admin@example.com"
EOF
if [[ "$ENABLE_SHARED_LIBS" == true ]]; then
cat >> "$JENKINS_DIR/casc/jenkins.yaml" <<EOF
  globalLibraries:
    libraries:
      - name: "${LIB_NAME}"
        defaultVersion: "master"
        implicit: false
        retriever:
          modernSCM:
            scm:
              gitSource:
                id: "${CRED_ID}"
                remote: "${GIT_SSH_URL}"
                credentialsId: "${CRED_ID}"
EOF
fi

echo "+ Created/updated JCasC YAML (jenkins.yaml)"

echo "================================================================="
echo " Writing docker-compose.yml"
echo "================================================================="
if [[ "$ENABLE_AWS" == "true" ]]; then
  AWS_BUILD_ARGS="args:
        ENABLE_AWS: \"true\""
  AWS_ENV_VARS="- AWS_PAGER=
      - AWS_SDK_LOAD_CONFIG=1
      - AWS_PROFILE=default
      - AWS_DEFAULT_REGION=eu-west-1
      - ENABLE_AWS=true"
fi
# docker-compose.yml
if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    cat > "$COMPOSE_DIR/docker-compose.yml" <<EOF
services:
  jenkins:
    build:
      context: ${JENKINS_DIR}
      dockerfile: Dockerfile
      ${AWS_BUILD_ARGS}
    image: local-jenkins:latest
    container_name: jenkins
    ports:
      - "8080:8080"
    environment:
      - CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs/jenkins.yaml
      - JAVA_OPTS=-Djenkins.install.runSetupWizard=false
      ${AWS_ENV_VARS}
    volumes:
      - ${JENKINS_HOME}:/var/jenkins_home
      - ${JENKINS_DIR}/casc:/var/jenkins_home/casc_configs
      - ${SSH_HOST_DIR}:/var/jenkins_home/.ssh:ro
      - /root/.aws/config:/aws-bootstrap/config:ro
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
EOF
    echo "+ Created docker-compose.yml"
else
    echo "docker-compose.yml already exists — skipping"
fi

echo "================================================================="
echo " Fixing Permissions"
echo "================================================================="

sudo chown -R jenkins:jenkins "$JENKINS_DIR"

echo "================================================================="
echo " Installation Complete!"
echo "================================================================="

echo "To start Jenkins:"
echo "  cd ${COMPOSE_DIR}"
echo "  docker-compose build --no-cache"
echo "  docker-compose up -d"
echo
echo "Access Jenkins at:  http://localhost:8080"
