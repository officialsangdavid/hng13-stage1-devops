#!/bin/bash

# SAFETY SETTINGS & LOGGING

set -e  # Exit immediately if any command fails
set -o pipefail  # To fail if any part of the pipeline fails

# The timestamped log file for all output and errors 
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1 

echo " STARTING THE DEPLOYMENT PROCESS "
echo "Logs will be saved to: $LOG_FILE"

# STEP 1: Collecting all arguments from the user

read -p "Enter Git Repository URL: " REPO_URL
read -p "Enter Personal Access Token (PAT): " PAT
read -p "Enter branch name [default: main]: " BRANCH
read -p "Enter SSH username: " SSH_USER
read -p "Enter remote server IP address: " SERVER_IP
read -p "Enter path to SSH private key: " SSH_KEY_PATH
read -p "Enter application internal (container) port: " APP_PORT

BRANCH=${BRANCH:-main} #set the branch to main automatically if the user does not provide a branch

# Validating the provided arguments
if [[ -z "$REPO_URL" || -z "$PAT" || -z "$SSH_USER" || -z "$SERVER_IP" || -z "$SSH_KEY_PATH" || -z "$APP_PORT" ]]; then
  echo "⚠️  Missing input. Please fill all required fields."
  exit 1
fi

# STEP 2: Clone the repository

echo " CLONING REPOSITORY "
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

# Confirm if there is a Dockerfile or Docker-compose.yml file
if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
  echo "⚠️  Error: No Dockerfile or docker-compose.yml found."
  exit 1
fi
echo "✅ Docker required files detected."

cd ..

# STEP 3: Test the SSH Connection

echo " TESTING SSH CONNECTION TO $SERVER_IP "
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo '✅ SSH connection successful.'"

# STEP 4: Preparing the remote environment

echo " PREPARING REMOTE ENVIRONMENT "
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << 'EOF'
  set -e
  echo "Updating all system packages..."
  sudo apt update -y

  echo "Installing Docker, Docker Compose, and Nginx..."
  sudo apt install -y docker.io docker-compose nginx

  echo "Adding the user to the Docker group..."
  sudo usermod -aG docker $(whoami)

  echo "Enabling and starting all installed services..."
  sudo systemctl enable docker
  sudo systemctl start docker
  sudo systemctl enable nginx
  sudo systemctl start nginx

  echo "Checking versions of services installed..."
  docker --version
  docker-compose --version
  nginx -v
  echo "✅ Remote environment ready."
EOF

# STEP 5: Cop Repository to Remote server

echo " COPY CLONED REPO FILES TO THE REMOTE SERVER "
scp -i "$SSH_KEY_PATH" -r "$REPO_NAME" "$SSH_USER@$SERVER_IP":~/

# STEP 6: Deploy the Repo on the server

echo " DEPLOYING APPLICATION ON THE REMOTE SERVER "
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << EOF
  set -e
  cd "$REPO_NAME"

  if [ -f "docker-compose.yml" ]; then
    echo "Using docker-compose for deployment..."
    sudo docker-compose down || true
    sudo docker-compose up -d --build
  else
    echo "Using Dockerfile for manual deployment..."
    sudo docker build -t "$REPO_NAME" .
    sudo docker rm -f "$REPO_NAME" || true
    sudo docker run -d -p "$APP_PORT:$APP_PORT" --name "$REPO_NAME" "$REPO_NAME"
  fi

  echo "✅ Containers deployed successfully."
EOF

# STEP 7: Configure the NGINX proxy

echo " CONFIGURING NGINX PROXY "

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
  echo "Writing Nginx configuration..."
  echo '$NGINX_CONF' | sudo tee /etc/nginx/sites-available/$REPO_NAME > /dev/null

  echo "Enabling site..."
  sudo ln -sf /etc/nginx/sites-available/$REPO_NAME /etc/nginx/sites-enabled/

  echo "Testing Nginx configuration..."
  sudo nginx -t

  echo "Reloading Nginx..."
  sudo systemctl reload nginx

  echo "✅ Nginx configuration completed."
EOF

# STEP 8: Validate the Deployment to ensure success

echo " VALIDATING DEPLOYMENT ..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << EOF
  set -e
  echo "Checking running containers..."
  sudo docker ps

  echo "Testing application accessibility..."
  curl -I localhost || true

   if [ "\$STATUS_CODE" -eq 200 ]; then
    echo "✅ Server is accessible (HTTP 200)."
  else
    echo "❌ Server not responding properly (HTTP \$STATUS_CODE)."
    exit 1
  fi
EOF

echo "✅ Deployment successful! Your application should now be live."
echo "Logs stored in: $LOG_FILE"

# Clean, Clean, Clean

if [[ "$1" == "--cleanup" ]]; then
  echo " CLEANING THE REMOTE HOST "

  read -p "Enter SSH username: " SSH_USER
  read -p "Enter remote server IP address: " SERVER_IP
  read -p "Enter path to SSH private key: " SSH_KEY_PATH
  read -p "Enter repository name (folder name on server): " REPO_NAME

  if [[ -z "$SSH_USER" || -z "$SERVER_IP" || -z "$SSH_KEY_PATH" || -z "$REPO_NAME" ]]; then
    echo "⚠️  Missing required parameters for cleanup."
    exit 1
  fi

  ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << EOF
    set -e
    echo "Stopping and removing containers..."
    sudo docker stop \$(sudo docker ps -aq) 2>/dev/null || true
    sudo docker rm \$(sudo docker ps -aq) 2>/dev/null || true

    echo "Removing application directory..."
    sudo rm -rf ~/$REPO_NAME

    echo "Removing Nginx configuration..."
    sudo rm -f /etc/nginx/sites-available/$REPO_NAME
    sudo rm -f /etc/nginx/sites-enabled/$REPO_NAME
    sudo nginx -t && sudo systemctl reload nginx

    echo "✅ CleanING completed successfully."
EOF

  echo "✅ Exiting..."
  exit 0
fi
