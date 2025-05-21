#!/bin/bash

# MongoDB ReplicaSet Configuration Script

# Run this script on the primary server after installing MongoDB on all servers


# Function to configure MongoDB for replication
configure_mongodb_for_replication() {
    local config_file="/etc/mongod.conf"
    local needs_restart=false
    
    echo "Checking MongoDB configuration for replication settings..."
    
    # Create a backup of the original config if it doesn't exist
    if [ ! -f "${config_file}.original" ]; then
        sudo cp "$config_file" "${config_file}.original"
        echo "Created backup of original MongoDB configuration at ${config_file}.original"
    fi
    
    # Check for replication configuration
    if ! grep -q "replSetName: $REPLICA_SET_NAME" "$config_file"; then
        echo "Adding replication configuration..."
        
        # Check if replication section exists
        if grep -q "^replication:" "$config_file"; then
            # Add replSetName to existing replication section
            sudo sed -i "/^replication:/a\\  replSetName: $REPLICA_SET_NAME" "$config_file"
        else
            # Add new replication section
            echo -e "\n# replication section\nreplication:\n  replSetName: $REPLICA_SET_NAME" | sudo tee -a "$config_file" > /dev/null
        fi
        needs_restart=true
    fi
    
    # Check for network configuration - bindIp and port
    if ! grep -q "bindIp: 0.0.0.0" "$config_file"; then
        echo "Configuring bindIp setting..."
        
        if grep -q "^net:" "$config_file"; then
            # Add bindIp to existing net section
            sudo sed -i "/^net:/a\\  bindIp: 0.0.0.0" "$config_file"
        else
            # We'll add the complete net section below
            echo -e "\n# network interfaces\nnet:\n  port: $MONGO_PORT\n  bindIp: 0.0.0.0" | sudo tee -a "$config_file" > /dev/null
            needs_restart=true
            return
        fi
        needs_restart=true
    fi
    
    # Check if port needs to be configured
    if ! grep -q "port: $MONGO_PORT" "$config_file"; then
        echo "Configuring MongoDB port setting..."
        
        if grep -q "^net:" "$config_file"; then
            # Add port to existing net section
            sudo sed -i "/^net:/a\\  port: $MONGO_PORT" "$config_file"
        else
            # Add complete new net section (this should be caught by previous check)
            echo -e "\n# network interfaces\nnet:\n  port: $MONGO_PORT\n  bindIp: 0.0.0.0" | sudo tee -a "$config_file" > /dev/null
        fi
        needs_restart=true
    fi
    
    # Restart MongoDB if any changes were made
    if [ "$needs_restart" = true ]; then
        echo "Configuration changed. Restarting MongoDB service..."
        sudo systemctl restart mongod
        check_status "Failed to restart MongoDB after configuration update"
        sleep 5  # Give MongoDB time to restart
    else
        echo "MongoDB is already properly configured for replication."
    fi
}


# Load environment variables if .env file exists
if [ -f ".env" ]; then

    echo "Loading configuration from .env file..."

    # Fix: Only export non-comment lines properly

    export $(grep -v '^#' .env | xargs -0 | tr '\0' '\n')

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



echo "===== Configuring MongoDB Replica Set '$REPLICA_SET_NAME' ====="

echo "Primary server: $SERVER1:$MONGO_PORT"

echo "Secondary servers: $SERVER2:$MONGO_PORT, $SERVER3:$MONGO_PORT"



# Check if MongoDB is running

echo "Checking MongoDB service status..."

if ! pgrep mongod > /dev/null; then

    echo "MongoDB is not running. Starting service..."

    sudo systemctl start mongod

    check_status "Failed to start MongoDB service"

    sleep 5  # Give MongoDB time to start

fi

# Configure MongoDB for replication if needed
configure_mongodb_for_replication

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

    echo "For newer MongoDB versions, install 'mongosh'. For older versions, make sure 'mongo' is installed."

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




# Create admin user and application user - FIX FOR MONGOSH COMPATIBILITY

echo "Creating users and setting up authentication..."

cat > /tmp/create_users.js << EOF

// Connect to admin database


db = db.getSiblingDB('admin');



// Create admin user

db.createUser({

  user: "$ADMIN_USER",

  pwd: "$ADMIN_PASSWORD",

  roles: [

    { role: "userAdminAnyDatabase", db: "admin" },

    { role: "clusterAdmin", db: "admin" },

    { role: "root", db: "admin" }

  ]

});



// Create application database and user


db = db.getSiblingDB('$APP_DATABASE');

db.createUser({

  user: "$APP_USER",

  pwd: "$APP_PASSWORD",

  roles: [

    { role: "readWrite", db: "$APP_DATABASE" }

  ]

});



// Create a test collection

db.testCollection.insertOne({ name: "Test Document", createdAt: new Date() });

EOF



$MONGO_CLIENT --host localhost:$MONGO_PORT /tmp/create_users.js

check_status "Failed to create users"



# Enable security

echo "Enabling security in MongoDB configuration..."

# Check if the mongod.conf file exists

if [ -f "/etc/mongod.conf" ]; then

    sudo sed -i 's/#security:/security:/' /etc/mongod.conf

    sudo sed -i 's/#  authorization: "enabled"/  authorization: "enabled"/' /etc/mongod.conf



    # If the sed commands didn't make the changes, add them explicitly

    if ! grep -q "security:" /etc/mongod.conf; then

        echo -e "\n# Security configuration\nsecurity:\n  authorization: \"enabled\"" | sudo tee -a /etc/mongod.conf

    fi

else

    echo "Warning: mongod.conf not found in expected location. You may need to manually enable authentication."

fi



# Restart MongoDB

echo "Restarting MongoDB to apply security settings..."

sudo systemctl restart mongod

check_status "Failed to restart MongoDB"



# Clean up temporary files

rm -f /tmp/rs_init.js /tmp/create_users.js



echo "===== Replica Set Configuration Completed Successfully! ====="

echo ""

echo "Connection string for MongoDB clients:"

echo "mongodb://$APP_USER:$APP_PASSWORD@$SERVER1:$MONGO_PORT,$SERVER2:$MONGO_PORT,$SERVER3:$MONGO_PORT/$APP_DATABASE?replicaSet=$REPLICA_SET_NAME"

echo ""

echo "To test the replica set:"

echo "  $MONGO_CLIENT mongodb://$SERVER1:$MONGO_PORT,$SERVER2:$MONGO_PORT,$SERVER3:$MONGO_PORT/$APP_DATABASE?replicaSet=$REPLICA_SET_NAME -u $APP_USER -p $APP_PASSWORD --authenticationDatabase $APP_DATABASE"

echo ""

echo "Next step: Run generate-spring-config.sh to create Spring Boot configuration files."
