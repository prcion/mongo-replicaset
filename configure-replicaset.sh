#!/bin/bash
# MongoDB ReplicaSet Configuration Script
# This script will automatically configure and initialize a MongoDB replica set

# Load environment variables if .env file exists
if [ -f ".env" ]; then
    echo "Loading configuration from .env file..."
    # Fix: Properly handle .env file without exporting comments
    export $(grep -v '^#' .env | xargs)
else
    echo "No .env file found. Please create one or specify the required variables."
    exit 1
fi

# Verify required variables are set
REQUIRED_VARS="REPLICA_SET_NAME SERVER1 SERVER2 SERVER3 MONGO_PORT ADMIN_USER ADMIN_PASSWORD APP_USER APP_PASSWORD APP_DATABASE"
MISSING_VARS=0
for VAR in $REQUIRED_VARS; do
    if [ -z "${!VAR}" ]; then
        echo "Error: $VAR is not set. Please add it to your .env file."
        MISSING_VARS=1
    fi
done

if [ $MISSING_VARS -eq 1 ]; then
    exit 1
fi

# Function to check if command succeeded
check_status() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Function to configure MongoDB for replication on a server
configure_mongodb_replication() {
    local server=$1
    local is_local=$2

    echo "Configuring MongoDB for replication on $server..."
    
    # Command to update configuration
    CONFIG_CMD=$(cat << EOF
        if ! grep -q "replication:" /etc/mongod.conf; then
            echo "Adding replication configuration..."
            echo -e "\nreplication:\n  replSetName: $REPLICA_SET_NAME" | sudo tee -a /etc/mongod.conf
            CHANGED=1
        elif ! grep -q "replSetName: $REPLICA_SET_NAME" /etc/mongod.conf; then
            echo "Updating replSetName..."
            sudo sed -i "s/replSetName:.*/replSetName: $REPLICA_SET_NAME/" /etc/mongod.conf
            CHANGED=1
        fi

        # Ensure network settings are correct
        if ! grep -q "bindIp: 0.0.0.0" /etc/mongod.conf && ! grep -q "bindIp: $server" /etc/mongod.conf; then
            echo "Updating network settings..."
            if grep -q "bindIp:" /etc/mongod.conf; then
                sudo sed -i "s/bindIp:.*/bindIp: 0.0.0.0/" /etc/mongod.conf
            else
                echo -e "\nnet:\n  port: $MONGO_PORT\n  bindIp: 0.0.0.0" | sudo tee -a /etc/mongod.conf
            fi
            CHANGED=1
        fi

        if [ "\$CHANGED" = "1" ]; then
            echo "Restarting MongoDB to apply changes..."
            sudo systemctl restart mongod
            sleep 5
        fi
EOF
)
    
    if [ "$is_local" = "true" ]; then
        # Execute commands locally
        CHANGED=0
        eval "$CONFIG_CMD"
    else
        # Execute commands remotely via SSH
        ssh "$server" "CHANGED=0; $CONFIG_CMD"
    fi
}

echo "===== Configuring MongoDB Replica Set '$REPLICA_SET_NAME' ====="
echo "Primary server: $SERVER1:$MONGO_PORT"
echo "Secondary servers: $SERVER2:$MONGO_PORT, $SERVER3:$MONGO_PORT"

# Check local IP to determine which server we're on
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo "Local IP: $LOCAL_IP"

# Configure all servers for replication
# Local server first
configure_mongodb_replication "$LOCAL_IP" "true"

# Then remote servers
if [ "$LOCAL_IP" != "$SERVER1" ]; then
    configure_mongodb_replication "$SERVER1" "false"
fi
if [ "$LOCAL_IP" != "$SERVER2" ]; then
    configure_mongodb_replication "$SERVER2" "false"
fi
if [ "$LOCAL_IP" != "$SERVER3" ]; then
    configure_mongodb_replication "$SERVER3" "false"
fi

# Check if MongoDB is running locally
echo "Checking MongoDB service status..."
if ! pgrep mongod > /dev/null; then
    echo "MongoDB is not running. Starting service..."
    sudo systemctl start mongod
    check_status "Failed to start MongoDB service"
    sleep 5  # Give MongoDB time to start
fi

# Fix: Check for MongoDB tools
MONGO_CMD="mongo"
MONGOSH_CMD="mongosh"

if command -v mongosh &> /dev/null; then
    # New MongoDB installations use mongosh
    MONGO_CLIENT="$MONGOSH_CMD"
    echo "Using mongosh client..."
elif command -v mongo &> /dev/null; then
    # Legacy MongoDB installations use mongo
    MONGO_CLIENT="$MONGO_CMD"
    echo "Using mongo client..."
else
    echo "Error: MongoDB client not found. Please install MongoDB tools or ensure they are in your PATH."
    exit 1
fi

# Create JS file for replica set configuration
echo "Creating replica set initialization script..."
cat > /tmp/rs_init.js << EOF
// ReplicaSet configuration
rs.initiate({
  _id: "$REPLICA_SET_NAME",
  members: [
    { _id: 0, host: "$SERVER1:$MONGO_PORT", priority: 2 },
    { _id: 1, host: "$SERVER2:$MONGO_PORT", priority: 1 },
    { _id: 2, host: "$SERVER3:$MONGO_PORT", priority: 1 }
  ]
});

// Wait for the replica set to initialize
print("Waiting for replica set initialization...");
sleep(5000);

// Check replica set status
rs.status();
EOF

# Execute the configuration
echo "Initializing replica set..."
$MONGO_CLIENT --host localhost:$MONGO_PORT /tmp/rs_init.js
check_status "Failed to initialize replica set"

# Wait for primary election
echo "Waiting for primary election..."
sleep 10

# Rest of your script for creating users and setting up authentication...
# [Keep the remaining parts of your script below]
