
#!/bin/bash

# Source the configuration file
source replica-config.conf

# Prompt the user for the number of replicas
read -p "Please enter the number of replicas to set up: " NUM_REPLICAS

# Validate the number of replicas
if ! [[ "$NUM_REPLICAS" =~ ^[0-9]+$ ]] || [ "$NUM_REPLICAS" -lt 1 ]; then
    echo "Error: Please enter a valid number of replicas (greater than 0)."
    exit 1
fi

# Initialize an array to store replica hosts
declare -a REPLICA_HOSTS

# Loop through each replica to collect host details
for ((i=1; i<=NUM_REPLICAS; i++)); do
    read -p "Enter hostname for replica $i (namespace ${NAMESPACES[$i-1]}): " REPLICA_HOST
    REPLICA_HOSTS[$i-1]="$REPLICA_HOST"
done

# Patch secrets for each namespace
for ((i=1; i<=NUM_REPLICAS; i++)); do
    NAMESPACE=${NAMESPACES[$i-1]}

    echo "Patching secret for namespace: $NAMESPACE"

    # Patch the Kubernetes secret to update the replica-password
    kubectl patch secret $SECRET_NAME -n $NAMESPACE --patch='{"data": {"replica-password": "'$(echo -n "$REPLICATION_PASSWORD
" | base64 -w 0)'"}}'

    if [ $? -ne 0 ]; then
        echo "Error: Failed to patch secret in namespace $NAMESPACE. Exiting."
        exit 1
    else
        echo "Successfully patched secret for namespace: $NAMESPACE"
    fi
done

# Loop through each replica to set up bidirectional replication
for ((i=1; i<=NUM_REPLICAS; i++)); do
    REPLICA_HOST="${REPLICA_HOSTS[$i-1]}"
    PUB_NAME="pub_${NAMESPACES[$i-1]}"

    echo "Setting up publication for replica $i with host: $REPLICA_HOST"

    # Fetch the PostgreSQL password for the database user from the Kubernetes secret
    POSTGRES_PASSWORD=$(kubectl get secret $SECRET_NAME -n ${NAMESPACES[$i-1]} -o jsonpath='{.data.postgresql-password}' | ba
se64 --decode)
    REPLICATION_PASSWORD=$(kubectl get secret $SECRET_NAME -n ${NAMESPACES[$i-1]} -o jsonpath='{.data.replica-password}' | ba
se64 --decode)

    if [ -z "$POSTGRES_PASSWORD" ]; then
        echo "Error: Unable to retrieve PostgreSQL password for replica $i (namespace ${NAMESPACES[$i-1]}). Exiting."
        exit 1
    fi

    # Use the predefined DB_POD_NAME from replica_config.sh
    echo "Using pod: $DB_POD_NAME in namespace: ${NAMESPACES[$i-1]}"

    # Check if the publication already exists
    if ! kubectl exec -n ${NAMESPACES[$i-1]} ${DB_POD_NAME} -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -d $DB_NAME -U $DB
_USER -t -c \"SELECT 1 FROM pg_publication WHERE pubname = '$PUB_NAME';\" | grep -q 1"; then
        # Create publication if it doesn't exist
        kubectl exec -n ${NAMESPACES[$i-1]} ${DB_POD_NAME} -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -d $DB_NAME -U $DB_
USER -c \"CREATE PUBLICATION $PUB_NAME FOR ALL TABLES;\""

        if [ $? -ne 0 ]; then
            echo "Error: Failed to create publication for replica $i (namespace ${NAMESPACES[$i-1]}). Exiting."
            exit 1
        fi
    else
        echo "Publication '$PUB_NAME' already exists. Skipping creation."
    fi

    # Set up subscriptions with all other replicas
    for ((j=1; j<=NUM_REPLICAS; j++)); do
        if [ $i -ne $j ]; then
            PEER_HOST="${REPLICA_HOSTS[$j-1]}"
            PEER_PUB_NAME="pub_${NAMESPACES[$j-1]}"  # Correct publication name from the peer
            SUB_NAME="replica${i}_to_replica${j}_sub"

            echo "Setting up subscription on replica $i to connect to replica $j (host: $PEER_HOST)"

            # Check if the subscription already exists
            if ! kubectl exec -n ${NAMESPACES[$i-1]} ${DB_POD_NAME} -- bash -c "PGPASSWORD=$POSTGRES_PASSWORD psql -d $DB_NAM
E -U $DB_USER -t -c \"SELECT 1 FROM pg_subscription WHERE subname = '$SUB_NAME';\" | grep -q 1"; then
                # Create subscription if it doesn't exist
                kubectl exec -n ${NAMESPACES[$i-1]} ${DB_POD_NAME} -- bash -c "PGPASSWORD=$REPLICATION_PASSWORD psql -d $DB_N
AME -U $REPLICATION_USER -c \"CREATE SUBSCRIPTION $SUB_NAME CONNECTION 'host=$PEER_HOST port=$DB_PORT user=$REPLICATION_USER
password=$REPLICATION_PASSWORD dbname=$DB_NAME' PUBLICATION $PEER_PUB_NAME WITH (copy_data = false, origin = none);\""

                if [ $? -ne 0 ]; then
                    echo "Error: Failed to create subscription for replica $i to replica $j. Exiting."
                    exit 1
                fi
            else
                echo "Subscription '$SUB_NAME' already exists between replica $i and replica $j. Skipping creation."
            fi
        fi
    done

    echo "--------------------------------------------------------"
done

echo "Bidirectional replication setup completed successfully."

