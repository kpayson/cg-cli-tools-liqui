#!/bin/bash

# set -e

VERSION="(development version)"

parse_yaml() {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

status_of() {
	local space=$(cat ~/.cf/config.json | jq -r '.SpaceFields.GUID')
	if [[ -z $space ]]; then
		echo 2>&1 "no space targeted."
		exit 1
	fi
	local guid=$(cf curl /v2/spaces/$space/service_instances | jq -r '.resources[] | select(.entity.name == "'$1'") | .metadata.guid')
	if [[ -z $guid ]]; then
		echo 2>&1 "service $1 not found."
		exit 1
	fi
	local state=$(cf curl /v2/service_instances/$guid | jq -r '.entity.last_operation.state')
	if [[ -z $state ]]; then
		echo 2>&1 "failed to get status of service $1."
		exit 1
	fi
	echo $state
}


wait_for_service() {
	SERVICE=${1:-}
	if [[ -z $SERVICE ]]; then
		echo >&2 "USAGE: $0 NAME"
		exit 1
	fi

	while true; do
		STATE=$(status_of $SERVICE)
		case $STATE in
		(succeeded)
			echo "Service $SERVICE finished provisioning succesfully."
			return 1
			;;
		(*progress)
			echo >&2 "Service $SERVICE is now in '$STATE' state."
			sleep 5
			;;
		(*)
			echo >&2 "Service $SERVICE is now in '$STATE' state."
			echo "Service $SERVICE is now in '$STATE' state."
			return 0
		esac
	done
}


create_service() {
	SERVICE_CONFIG_JSON=$1

	local CF_SERVICE=$(jq -r '.service' <<< $1)
	local CF_SERVICE_PLAN=$(jq -r '.service_plan' <<< $1)
	CF_SERVICE_INSTANCE=$(jq -r '.service_instance' <<< $1)
	local CF_SERVICE_CONFIG=$(jq -r '.service_config' <<< $1)

	CF_SERVICE_CONFIG="$(echo $CF_SERVICE_CONFIG)"

	echo >&2 "$CF_SERVICE_CONFIG"

	local err=$(cf create-service  $CF_SERVICE \
    $CF_SERVICE_PLAN \
    $CF_SERVICE_INSTANCE \
    -c "$CF_SERVICE_CONFIG" 2>&1)   

	if [ "$err" != *"is taken"* ] && [ "$err" == *"FAILED"* ]; then
		echo >&2 "Error: [$err]"
  		exit 1
	fi

	echo $CF_SERVICE_INSTANCE
}

deploy_app_from_config() {
	local CONFIG_FILE_NAME=$1
	local APP_NAME=$(yq -o=json  ${INPUT_CF_VARS_FILE} | jq -r ".APP_NAME")
	
	eval $(parse_yaml "./$CONFIG_FILE_NAME" "liquibase_config")

	# If they specified a vars file, use it  
	if [[ -r "$INPUT_CF_VARS_FILE" ]]; then 
	  echo "Pushing with vars file: $INPUT_CF_VARS_FILE"
	  CF_DOCKER_PASSWORD=$INPUT_CF_DOCKER_PASSWORD cf push --no-start --no-route --vars-file "$INPUT_CF_VARS_FILE" -f ./${CONFIG_FILE_NAME}
	else 
	  echo "Pushing with manifest file: $MANIFEST"
	  CF_DOCKER_PASSWORD=$INPUT_CF_DOCKER_PASSWORD cf push --no-start --no-route  -f ./${CONFIG_FILE_NAME}
	fi
	
	local PACKAGE_GUID=$(cf packages $APP_NAME | awk -F " " 'NR==4 {print $1}') 
	cf stage $APP_NAME  --package-guid $PACKAGE_GUID 
	local DROPLET_GUID=$(cf droplets $APP_NAME | awk -F " " 'NR==4 {print $1}') 
	cf set-droplet  $APP_NAME  $DROPLET_GUID
}

liquibase_migrate() {
  LIQUIBASE_DOCKER_COMMAND_JSON=$1

  local CF_APP=$(jq -r '.app_instance' <<< $1)
  local CF_SERVICE=$(jq -r '.service_instance' <<< $1)
  echo 2>&1 "$CF_SERVICE"

  cf install-plugin https://github.com/AlexF4Dev/cf-run-and-wait/releases/download/0.3/cf-run-and-wait_0.3_linux_amd64 -f

  LIQUIBASE_ENTRY_COMMAND="sed -i 's/labshare/${INPUT_DATABASE_NAME:=labshare}-test1/g' /liquibase/liquibase.properties && "
  LIQUIBASE_ENTRY_COMMAND+='credentials=$(echo "$VCAP_SERVICES" | jq ".[] | .[] | select(.instance_name==\"'
  LIQUIBASE_ENTRY_COMMAND+=$CF_SERVICE
  LIQUIBASE_ENTRY_COMMAND+='\") | .credentials") && \
export DB_HOST=$(echo $credentials | jq -r ".host") && \
export DB_DATABASE_NAME=$(echo $credentials | jq -r ".db_name") && \
export DB_USER=$(echo $credentials | jq -r ".username") && \
export DB_PASSWORD=$(echo $credentials | jq -r ".password") && \
export DB_PORT=$(echo $credentials | jq -r ".port") && \
liquibase --url=jdbc:mysql://${DB_HOST}:${DB_PORT}/'

LIQUIBASE_ENTRY_COMMAND+=${INPUT_DATABASE_NAME}
LIQUIBASE_ENTRY_COMMAND+='_liqui1?createDatabaseIfNotExist=true --username=${DB_USER} --password=${DB_PASSWORD} --changeLogFile="/liquibase/changelog/changelog.xml" update'

echo INPUT_DATABASE_NAME=$INPUT_DATABASE_NAME
echo LIQUIBASE_ENTRY_COMMAND=$LIQUIBASE_ENTRY_COMMAND
eval "echo evaluated_command=$LIQUIBASE_ENTRY_COMMAND"
cf run-and-wait $CF_APP   "$LIQUIBASE_ENTRY_COMMAND"

}

CF_API=${INPUT_CF_API:-api.fr.cloud.gov}
# Authenticate and target CF org and space.
cf api "$CF_API"
cf auth "$INPUT_CF_USERNAME" "$INPUT_CF_PASSWORD"
cf target -o "$INPUT_CF_ORG" -s "$INPUT_CF_SPACE"

if [[ -n "$INPUT_LIQUIBASE_DOCKER_COMMAND" ]]; then
  echo "Running command: $INPUT_LIQUIBASE_DOCKER_COMMAND"
  
  liquibase_migrate "$INPUT_LIQUIBASE_DOCKER_COMMAND"
  
  exit 0
fi

if [[ -n "$INPUT_DEPLOY_APP_FROM_CONFIG_COMMAND" ]]; then
  echo "Running command: $INPUT_DEPLOY_APP_FROM_CONFIG_COMMAND"
  deploy_app_from_config "$INPUT_DEPLOY_APP_FROM_CONFIG_COMMAND" 
  exit 0
fi

if [[ -n "$INPUT_SERVICE_COMMAND" ]]; then
  echo "Running command: $INPUT_SERVICE_COMMAND"
  CF_SERVICE_INSTANCE=""
  create_service "$INPUT_SERVICE_COMMAND"
  wait_for_service "$CF_SERVICE_INSTANCE"
  exit 0
fi

if [[ -n "$INPUT_USER_SERVICE_COMMAND" ]]; then
  echo "Running command: $INPUT_USER_SERVICE_COMMAND"

  cf delete-service "${INPUT_USER_SERVICE_NAME}" -f

  cf cups "${INPUT_USER_SERVICE_NAME}" -p "$(cat ${INPUT_USER_SERVICE_COMMAND})"
  
  exit 0
fi

# If they specified a cf CLI subcommand, run it
if [[ -n "$INPUT_CF_COMMAND" ]]; then
  echo "Running command: $INPUT_CF_COMMAND"
  eval cf $INPUT_CF_COMMAND
  exit
fi

# Otherwise, assume they want to do a cf push.

# If they didn't specify and don't have a default-named manifest.yml, then the
# push will fail with a pretty accurate message: "Incorrect Usage: The specified
# path 'manifest.yml' does not exist."
MANIFEST=${INPUT_CF_MANIFEST:-manifest.yml}

# If they specified a vars file, use it  
if [[ -r "$INPUT_CF_VARS_FILE" ]]; then 
  echo "Pushing with vars file: $INPUT_CF_VARS_FILE"
  cf push -f "$MANIFEST" --vars-file "$INPUT_CF_VARS_FILE" --strategy rolling
else 
  echo "Pushing with manifest file: $MANIFEST"
  cf push -f "$MANIFEST" --strategy rolling
fi