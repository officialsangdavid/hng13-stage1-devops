#!/bin/bash

# ------------------------------
# SAFETY SETTINGS & LOGGING
# ------------------------------

set -e  # Exit immediately if a command fails
set -o pipefail  # Fail if any part of a pipeline fails

# Create timestamped log file
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1  # Log all output and errors

echo "=== Starting deployment process ==="
echo "Logs will be saved to: $LOG_FILE"

# ------------------------------
# STEP 1: Collect user input
# ------------------------------

read -p "Enter Git Repository URL: " REPO_URL
read -p "Enter Personal Access Token (PAT): " PAT
read -p "Enter branch name [default: main]: " BRANCH
read -p "Enter SSH username: " SSH_USER
read -p "Enter remote server IP address: " SERVER_IP
read -p "Enter path to SSH private key: " SSH_KEY_PATH
read -p "Enter application internal (container) port: " APP_PORT

BRANCH=${BRANCH:-main}

# Validate input
if [[ -z "$REPO_URL" || -z "$PAT" || -z "$SSH_USER" || -z "$SERVER_IP" || -z "$SSH_KEY_PATH" || -z "$APP_PORT" ]]; then
  echo "❌ Missing input. Please fill all required fields."
  exit 1
fi

# ------------------------------
# STEP 2: Clone or update repo
# ------------------------------

echo "=== Cloning repository ==="
REPO_NAME=$(basename "$REPO_URL" .git)

if [ -d "$REPO_NAME" ]; then
  echo "Repository exists. Pulling latest changes..."
  cd "$REPO_NAME"
  git fetch origin "$BRANCH"
  git checkout "$BRANCH"
  git pull origin "$BRANCH"
else
  echo "Cloning new repository..."
  git clone "https://${PAT}@${REPO_URL#https://}" -b "$BRANCH"
  cd "$REPO_NAME"
fi

# Check for Docker configuration
if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
  echo "❌ Error: No Dockerfile or docker-compose.yml found."
  exit 1
fi
echo "✅ Docker configuration detected."

cd ..

# ------------------------------
# STEP 3: Test SSH connection
# ------------------------------

echo "=== Testing SSH connection to $SERVER_IP ==="
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo '✅ SSH connection successful.'"

# ------------------------------
# STEP 4: Prepare remote environment
# ------------------------------

echo "=== Preparing remote environment ==="
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << 'EOF'
  set -e
  echo "🔧 Updating system packages..."
  sudo apt update -y

  echo "📦 Installing Docker, Docker Compose, and Nginx..."
  sudo apt install -y docker.io docker-compose nginx

  echo "👥 Adding user to Docker group..."
  sudo usermod -aG docker $(whoami)

  echo "🔄 Enabling and starting services..."
  sudo systemctl enable docker
  sudo systemctl start docker
  sudo systemctl enable nginx
  sudo systemctl start nginx

  echo "🧩 Checking versions..."
  docker --version
  docker-compose --version
  nginx -v
  echo "✅ Remote environment ready."
EOF

# ------------------------------
# STEP 5: Transfer project files
# ------------------------------

echo "=== Transferring project files to remote server ==="
scp -i "$SSH_KEY_PATH" -r "$REPO_NAME" "$SSH_USER@$SERVER_IP":~/

# ------------------------------
# STEP 6: Deploy Dockerized application
# ------------------------------

echo "=== Deploying application on remote server ==="
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << EOF
  set -e
  cd "$REPO_NAME"

  if [ -f "docker-compose.yml" ]; then
    echo "🧱 Using docker-compose for deployment..."
    sudo docker-compose down || true
    sudo docker-compose up -d --build
  else
    echo "🐳 Using Dockerfile for manual deployment..."
    sudo docker build -t "$REPO_NAME" .
    sudo docker rm -f "$REPO_NAME" || true
    sudo docker run -d -p "$APP_PORT:$APP_PORT" --name "$REPO_NAME" "$REPO_NAME"
  fi

  echo "✅ Application containers deployed successfully."
EOF

# ------------------------------
# STEP 7: Configure Nginx reverse proxy
# ------------------------------

echo "=== Configuring Nginx reverse proxy ==="

NGINX_CONF="
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
"

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << EOF
  set -e
  echo "📝 Writing Nginx configuration..."
  echo '$NGINX_CONF' | sudo tee /etc/nginx/sites-available/$REPO_NAME > /dev/null

  echo "🔗 Enabling site..."
  sudo ln -sf /etc/nginx/sites-available/$REPO_NAME /etc/nginx/sites-enabled/

  echo "🧪 Testing Nginx configuration..."
  sudo nginx -t

  echo "🔁 Reloading Nginx..."
  sudo systemctl reload nginx

  echo "✅ Nginx configuration completed."
EOF

# ------------------------------
# STEP 8: Validate deployment
# ------------------------------

echo "=== Validating deployment ==="
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << EOF
  set -e
  echo "🔍 Checking running containers..."
  sudo docker ps

  echo "🌍 Testing application accessibility..."
  curl -I localhost || true
EOF

echo "✅ Deployment successful! Your application should now be live."
echo "🗒️ Logs stored in: $LOG_FILE"
