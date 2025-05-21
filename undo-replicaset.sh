#!/bin/bash
# MongoDB ReplicaSet Removal Script
# This script will undo a MongoDB replica set configuration

# Load environment variables if .env file exists (same as in your original script)
if [ -f ".env" ]; then
    echo "Loading configuration from .env file..."
    export $(grep -v '^#' .env | xargs -0 | tr '\0' '\n')
else
    echo "No .env file found. Using default values or prompting for input."
    # You might want to ask for values here if .env is missing
    read -p "Enter MongoDB port (default: 27017): " MONGO_PORT
    MONGO_PORT=${MONGO_PORT:-27017}
    read -p "Enter admin username: " ADMIN_USER
    read -s -p "Enter admin password: " ADMIN_PASSWORD
    echo ""
fi

# Check for MongoDB tools
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
    echo "Error: MongoDB client not found. Please install MongoDB tools."
    exit 1
fi

echo "===== Removing MongoDB Replica Set Configuration ====="

# 1. Step down the replica set (run on the primary)
echo "Stepping down replica set..."
cat > /tmp/rs_stepdown.js << EOF
try {
  rs.stepDown();
} catch (err) {
  print("Note: Step down might fail if this node is not the primary. This is okay.");
  print(err);
}
EOF

# Execute for primary authentication
if [ ! -z "$ADMIN_USER" ] && [ ! -z "$ADMIN_PASSWORD" ]; then
    AUTH_PARAMS="-u $ADMIN_USER -p $ADMIN_PASSWORD --authenticationDatabase admin"
    $MONGO_CLIENT --host localhost:$MONGO_PORT $AUTH_PARAMS /tmp/rs_stepdown.js
else
    $MONGO_CLIENT --host localhost:$MONGO_PORT /tmp/rs_stepdown.js
fi

# 2. Remove the replica set configuration
echo "Removing replica set configuration..."
cat > /tmp/rs_remove.js << EOF
// Connect to admin database
db = db.getSiblingDB('admin');

// Force removal of replica set configuration
try {
  rs.status(); // Check if we're in a replica set
  print("Removing replica set configuration...");
  cfg = rs.conf();
  if (cfg) {
    // Store the members for later
    members = cfg.members.map(m => m.host);
    print("Found replica set with members: " + JSON.stringify(members));
  }
} catch (err) {
  print("Warning: Could not retrieve replica set status. It may already be removed or this node may not be a replica set member.");
  print(err);
}
EOF

# Execute for primary
if [ ! -z "$ADMIN_USER" ] && [ ! -z "$ADMIN_PASSWORD" ]; then
    $MONGO_CLIENT --host localhost:$MONGO_PORT $AUTH_PARAMS /tmp/rs_remove.js
else
    $MONGO_CLIENT --host localhost:$MONGO_PORT /tmp/rs_remove.js
fi

# 3. Update MongoDB configuration to remove replication settings
echo "Updating MongoDB configuration..."
if [ -f "/etc/mongod.conf" ]; then
    # Back up the original config
    sudo cp /etc/mongod.conf /etc/mongod.conf.bak.$(date +%Y%m%d%H%M%S)
    
    # Remove replication section
    sudo sed -i '/^replication:/,/^[a-z]/s/^/#/' /etc/mongod.conf
    
    # If you want to disable auth as well
    if [ "$DISABLE_AUTH" = "true" ]; then
        sudo sed -i 's/^security:/# security:/' /etc/mongod.conf
        sudo sed -i 's/^  authorization: "enabled"/# authorization: "enabled"/' /etc/mongod.conf
    fi
    
    echo "MongoDB configuration updated. Original configuration backed up."
else
    echo "Warning: mongod.conf not found in expected location."
fi

# 4. Restart MongoDB to apply changes - do this for each server
echo "Restarting MongoDB..."
sudo systemctl restart mongod
if [ $? -ne 0 ]; then
    echo "Error: Failed to restart MongoDB. Please check the logs."
    exit 1
fi

# 5. Clean up
rm -f /tmp/rs_stepdown.js /tmp/rs_remove.js

echo "===== MongoDB Replica Set Removal Completed! ====="
echo ""
echo "IMPORTANT: You need to perform these steps on all servers that were part of the replica set:"
echo "1. Update the MongoDB configuration to remove replication settings"
echo "2. Restart the MongoDB service"
echo ""
echo "To manually update MongoDB configuration on each server:"
echo "- Edit /etc/mongod.conf"
echo "- Comment out or remove any 'replication:' section"
echo "- Restart MongoDB: sudo systemctl restart mongod"
echo ""
echo "If you had authentication enabled and want to disable it:"
echo "- Comment out the 'security:' section in /etc/mongod.conf"
echo "- Then restart MongoDB"
