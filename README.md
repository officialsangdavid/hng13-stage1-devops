# Automated Deployment Script

This Bash script automates the process of deploying a Dockerized application to a remote server using SSH. It handles everything from cloning the repository to configuring Nginx as a reverse proxy.

## Overview

The script performs these steps:

1. Collects user input
2. Clones or updates the GitHub repository
3. Tests SSH connection
4. Installs Docker, Docker Compose, and Nginx on the remote server
5. Transfers project files
6. Deploys the containerized application
7. Configures Nginx reverse proxy
8. Validates the deployment

## Prerequisites

- Ubuntu system (local and remote)
- SSH access to the remote server
- Docker and Docker Compose
- Nginx (installed automatically by the script)
- GitHub repository with a Dockerfile or `docker-compose.yml`

## Example GitHub Repository

**Repository URL:**
[https://github.com/officialsangdavid/hng13-stage1-devops-app.git](https://github.com/officialsangdavid/hng13-stage1-devops-app.git)

**Application Port:**
3000

## Usage Instructions

### 1. Make the Script Executable

```bash
chmod +x deploy.sh
```

### 2. Run the Deployment Script

```bash
./deploy.sh
```

You will be prompted to enter:

- Git repository URL
- Personal Access Token (PAT)
- Branch name (default: main)
- SSH username
- Remote server IP address
- Path to SSH private key
- Internal container port (e.g., 3000)

## Detailed Steps

### Step 1: Collect User Input

The script collects and validates required deployment inputs:

```bash
read -p "Enter Git Repository URL: " REPO_URL
read -p "Enter Personal Access Token (PAT): " PAT
read -p "Enter branch name [default: main]: " BRANCH
read -p "Enter SSH username: " SSH_USER
read -p "Enter remote server IP address: " SERVER_IP
read -p "Enter path to SSH private key: " SSH_KEY_PATH
read -p "Enter application internal (container) port: " APP_PORT
```

### Step 2: Clone or Update Repository

```bash
git clone https://<PAT>@github.com/<username>/<repo>.git -b main
cd <repo>
git pull origin main
```

If the repository already exists, it updates it; otherwise, it clones a new copy.

### Step 3: Test SSH Connection

```bash
ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no user@server_ip "echo 'SSH connection successful'"
```

### Step 4: Prepare Remote Environment

Installs Docker, Docker Compose, and Nginx:

```bash
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx
sudo usermod -aG docker $(whoami)
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx
```

Verify versions:

```bash
docker --version
docker-compose --version
nginx -v
```

### Step 5: Transfer Project Files

```bash
scp -i ~/.ssh/id_rsa -r <repo> user@server_ip:~/
```

### Step 6: Deploy the Application

If using `docker-compose.yml`:

```bash
cd <repo>
sudo docker-compose down || true
sudo docker-compose up -d --build
```

If only `Dockerfile` is present:

```bash
sudo docker build -t <repo> .
sudo docker rm -f <repo> || true
sudo docker run -d -p 3000:3000 --name <repo> <repo>
```

### Step 7: Configure Nginx Reverse Proxy

Create `/etc/nginx/sites-available/<repo>`:

```bash
sudo nano /etc/nginx/sites-available/<repo>
```

Paste this configuration:

```nginx
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Enable the configuration and reload Nginx:

```bash
sudo ln -sf /etc/nginx/sites-available/<repo> /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### Step 8: Validate Deployment

Check running containers:

```bash
sudo docker ps
```

Verify application accessibility:

```bash
curl -I localhost
```

## Example Run

```bash
./deploy.sh
Enter Git Repository URL: https://github.com/officialsangdavid/hng13-stage1-devops-app.git
Enter Personal Access Token (PAT): ghp_********
Enter branch name [default: main]: main
Enter SSH username: ubuntu
Enter remote server IP address: 18.210.xxx.xxx
Enter path to SSH private key: ~/.ssh/id_rsa
Enter application internal (container) port: 3000
```

## Logs

All logs are saved in timestamped files such as:

```
deploy_20251022_153045.log
```
