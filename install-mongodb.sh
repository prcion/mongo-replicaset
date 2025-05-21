#!/bin/bash

# MongoDB Installation Script
# This script installs MongoDB on a server and configures it for replication

# Load environment variables if .env file exists
if [ -f ".env" ]; then
    echo "Loading configuration from .env file..."
    export $(grep -v '^#' .env | xargs)
else
    echo "No .env file found. Using default values."
    # Default values if not set in environment
    MONGO_VERSION=${MONGO_VERSION:-"6.0"}
    MONGO_PORT=${MONGO_PORT:-27017}
    REPLICA_SET_NAME=${REPLICA_SET_NAME:-"rs0"}
    DATA_DIR=${DATA_DIR:-"/var/lib/mongodb"}
    LOG_DIR=${LOG_DIR:-"/var/log/mongodb"}
fi

# Function to check if command succeeded
check_status() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot detect OS. Exiting."
    exit 1
fi

echo "===== Installing MongoDB $MONGO_VERSION on $(hostname) ====="

case $OS in
    ubuntu|debian)
        echo "Detected $OS system"
        
        # Import MongoDB public GPG key using the newer method
        wget -O /tmp/mongodb-key.asc https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc
        check_status "Failed to download MongoDB GPG key"
        
        # Add the key to the keyring directory
        sudo mkdir -p /etc/apt/keyrings
        sudo gpg --dearmor -o /etc/apt/keyrings/mongodb-$MONGO_VERSION.gpg /tmp/mongodb-key.asc
        check_status "Failed to import MongoDB GPG key"
        
        # Add MongoDB repository
        echo "deb [signed-by=/etc/apt/keyrings/mongodb-$MONGO_VERSION.gpg] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/$MONGO_VERSION multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list
        check_status "Failed to add MongoDB repository"
        
        # Update package database and install MongoDB
        sudo apt-get update
        check_status "Failed to update package database"
        
        sudo apt-get install -y mongodb-org
        check_status "Failed to install MongoDB"
        ;;
        
    rhel|centos|fedora|rocky|almalinux)
        echo "Detected $OS system"
        # Create a .repo file for MongoDB
        sudo tee /etc/yum.repos.d/mongodb-org-$MONGO_VERSION.repo << EOF
[mongodb-org-$MONGO_VERSION]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/$MONGO_VERSION/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc
EOF
        check_status "Failed to create MongoDB repository file"
        
        # Install MongoDB
        sudo yum install -y mongodb-org
        check_status "Failed to install MongoDB"
        ;;
        
    *)
        echo "Unsupported OS: $OS. Exiting."
        exit 1
        ;;
esac

# Create directories if they don't exist
sudo mkdir -p $DATA_DIR $LOG_DIR
sudo chown -R mongodb:mongodb $DATA_DIR $LOG_DIR

# Configure MongoDB for replication
echo "Configuring MongoDB for replication..."

# Backup the original config file
sudo cp /etc/mongod.conf /etc/mongod.conf.bak
check_status "Failed to backup MongoDB configuration"

# Create new configuration file
sudo tee /etc/mongod.conf << EOF
# MongoDB configuration file

# Storage configuration
storage:
  dbPath: $DATA_DIR
  journal:
    enabled: true

# Network configuration
net:
  port: $MONGO_PORT
  bindIp: 0.0.0.0

# Replication configuration
replication:
  replSetName: "$REPLICA_SET_NAME"

# Process management configuration
processManagement:
  timeZoneInfo: /usr/share/zoneinfo

# Logging configuration
systemLog:
  destination: file
  path: $LOG_DIR/mongod.log
  logAppend: true

# Security configuration - initially disabled
#security:
#  authorization: "enabled"
EOF
check_status "Failed to create MongoDB configuration file"

# Start and enable MongoDB service
sudo systemctl start mongod
check_status "Failed to start MongoDB service"

sudo systemctl enable mongod
check_status "Failed to enable MongoDB service"

echo "MongoDB installed and configured successfully on $(hostname)."
echo "===== IMPORTANT NEXT STEPS ====="
echo "1. Make sure MongoDB port $MONGO_PORT is open in your firewall:"
echo "   * For Ubuntu/Debian with UFW: sudo ufw allow $MONGO_PORT/tcp"
echo "   * For RHEL/CentOS with firewalld: sudo firewall-cmd --permanent --add-port=$MONGO_PORT/tcp && sudo firewall-cmd --reload"
echo ""
echo "2. To complete the replica set setup, run the configure-replicaset.sh script on the primary server after installing MongoDB on all servers."
