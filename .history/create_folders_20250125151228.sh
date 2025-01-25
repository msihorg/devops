#!/bin/bash
# make executable: chmod +x script.sh

if [ -z "$1" ]; then
   echo "Usage: ./create_folders.sh domain.com"
   exit 1
fi

DOMAIN="$1"
BASE_DIR="/var/www"

# Set base ports for environments
DEV_BASE=2000
STAGE_BASE=3000
PROD_BASE=4000

# Find next available port for each environment
get_next_port() {
   local env_base=$1
   local max_port=$env_base
   for port in $(find $BASE_DIR -type d -name "*[0-9]*" | grep -oP "[0-9]+$"); do
       if (( port > max_port && port < env_base+1000 )); then
           max_port=$port
       fi
   done
   echo $((max_port+1))
}

mkdir -p "$BASE_DIR/$DOMAIN/dev$(get_next_port $DEV_BASE)"
mkdir -p "$BASE_DIR/$DOMAIN/stage$(get_next_port $STAGE_BASE)"
mkdir -p "$BASE_DIR/$DOMAIN/prod$(get_next_port $PROD_BASE)"