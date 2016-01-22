#!/usr/bin/env bash

# Change working directory
DIR_PATH="$( if [[ $( echo "${0%/*}" ) != $( echo "${0}" ) ]]; then cd "$( echo "${0%/*}" )"; fi; pwd )"
if [[ ${DIR_PATH} == */* ]] && [[ ${DIR_PATH} != $( pwd ) ]]; then
	cd ${DIR_PATH}
fi

source run.conf

have_docker_container_name ()
{
	local NAME=$1

	if [[ -z ${NAME} ]]; then
		return 1
	fi

	if [[ -n $(docker ps -a | awk -v pattern="^${NAME}$" '$NF ~ pattern { print $NF; }') ]]; then
		return 0
	fi

	return 1
}

is_docker_container_name_running ()
{
	local NAME=$1

	if [[ -z ${NAME} ]]; then
		return 1
	fi

	if [[ -n $(docker ps | awk -v pattern="^${NAME}$" '$NF ~ pattern { print $NF; }') ]]; then
		return 0
	fi

	return 1
}

remove_docker_container_name ()
{
	local NAME=$1

	if have_docker_container_name ${NAME}; then
		if is_docker_container_name_running ${NAME}; then
			echo "Stopping container ${NAME}"
			(docker stop ${NAME})
		fi
		echo "Removing container ${NAME}"
		(docker rm ${NAME})
	fi
}

# Configuration volume
if ! have_docker_container_name ${VOLUME_CONFIG_NAME}; then

	# For configuration that is specific to the running container
	CONTAINER_MOUNT_PATH_CONFIG=${MOUNT_PATH_CONFIG}/${DOCKER_NAME}

	# For configuration that is shared across a group of containers
	CONTAINER_MOUNT_PATH_CONFIG_SHARED_SSH=${MOUNT_PATH_CONFIG}/ssh.${SERVICE_UNIT_SHARED_GROUP}

	if [[ ! -d ${CONTAINER_MOUNT_PATH_CONFIG_SHARED_SSH}/ssh ]]; then
		CMD=$(mkdir -p ${CONTAINER_MOUNT_PATH_CONFIG_SHARED_SSH}/ssh)
		$CMD || sudo $CMD
	fi

	if [[ ! -d ${CONTAINER_MOUNT_PATH_CONFIG}/supervisor ]]; then
		CMD=$(mkdir -p ${CONTAINER_MOUNT_PATH_CONFIG}/supervisor)
		$CMD || sudo $CMD
	fi

	if [[ -z $(find ${CONTAINER_MOUNT_PATH_CONFIG}/supervisor -maxdepth 1 -type f) ]]; then
		CMD=$(cp -R etc/services-config/supervisor ${CONTAINER_MOUNT_PATH_CONFIG}/)
		$CMD || sudo $CMD
	fi

	if [[ ! -d ${CONTAINER_MOUNT_PATH_CONFIG}/httpd ]]; then
		CMD=$(mkdir -p ${CONTAINER_MOUNT_PATH_CONFIG}/httpd)
		$CMD || sudo $CMD
	fi

	if [[ -z $(find ${CONTAINER_MOUNT_PATH_CONFIG}/httpd -maxdepth 1 -type f) ]]; then
		CMD=$(cp -R etc/services-config/httpd ${CONTAINER_MOUNT_PATH_CONFIG}/)
		$CMD || sudo $CMD
	fi

	# SSL keys are generated by the bootstrap script so just need to ensure the directories are created
	if [[ ! -d ${CONTAINER_MOUNT_PATH_CONFIG}/ssl/certs ]] || [[ ! -d ${CONTAINER_MOUNT_PATH_CONFIG}/ssl/certs ]]; then
		CMD=$(mkdir -p ${CONTAINER_MOUNT_PATH_CONFIG}/ssl/{certs,private})
		$CMD || sudo $CMD
	fi

	(
	set -x
	docker run \
		--name ${VOLUME_CONFIG_NAME} \
		-v ${CONTAINER_MOUNT_PATH_CONFIG_SHARED_SSH}/ssh:/etc/services-config/ssh \
		-v ${CONTAINER_MOUNT_PATH_CONFIG}/supervisor:/etc/services-config/supervisor \
		-v ${CONTAINER_MOUNT_PATH_CONFIG}/httpd:/etc/services-config/httpd \
		-v ${CONTAINER_MOUNT_PATH_CONFIG}/ssl/certs:/etc/services-config/ssl/certs \
		-v ${CONTAINER_MOUNT_PATH_CONFIG}/ssl/private:/etc/services-config/ssl/private \
		busybox:latest \
		/bin/true;
	)
fi

# Force replace container of same name if found to exist
remove_docker_container_name ${DOCKER_NAME}

if [[ ${#} -eq 0 ]]; then
	echo "Running container ${DOCKER_NAME} as a background/daemon process."
	DOCKER_OPERATOR_OPTIONS="-d"
else
	# This is useful for running commands like 'export' or 'env' to check the 
	# environment variables set by the --link docker option.
	# 
	# If you need to pipe to another command, quote the commands. e.g: 
	#   ./run.sh "env | grep APACHE | sort"
	printf "Running container %s with CMD [/bin/bash -c '%s']\n" "${DOCKER_NAME}" "${*}"
	DOCKER_OPERATOR_OPTIONS="-it --entrypoint /bin/bash --env TERM=${TERM:-xterm}"
fi

# Enable/Disable SSL support
if [[ ${APACHE_MOD_SSL_ENABLED} == true ]]; then
	DOCKER_PORT_OPTIONS="-p ${DOCKER_HOST_PORT_HTTP:-}:80 -p ${DOCKER_HOST_PORT_HTTPS:-}:443"
else
	DOCKER_PORT_OPTIONS="-p ${DOCKER_HOST_PORT_HTTP:-}:80 -p ${DOCKER_HOST_PORT_HTTPS:-}:8443"
fi

# In a sub-shell set xtrace - prints the docker command to screen for reference
(
set -x
docker run \
	${DOCKER_OPERATOR_OPTIONS} \
	--name "${DOCKER_NAME}" \
	${DOCKER_PORT_OPTIONS} \
	--env "SERVICE_UNIT_APP_GROUP=${SERVICE_UNIT_APP_GROUP}" \
	--env "SERVICE_UNIT_LOCAL_ID=${SERVICE_UNIT_LOCAL_ID}" \
	--env "SERVICE_UNIT_INSTANCE=${SERVICE_UNIT_INSTANCE}" \
	--env "APACHE_EXTENDED_STATUS_ENABLED=${APACHE_EXTENDED_STATUS_ENABLED}" \
	--env "APACHE_LOAD_MODULES=${APACHE_LOAD_MODULES}" \
	--env "APACHE_MOD_SSL_ENABLED=${APACHE_MOD_SSL_ENABLED}" \
	--env "APACHE_SERVER_ALIAS=${APACHE_SERVER_ALIAS}" \
	--env "APACHE_SERVER_NAME=${APACHE_SERVER_NAME}" \
	--env "APP_HOME_DIR=${APP_HOME_DIR}" \
	--env "DATE_TIMEZONE=${DATE_TIMEZONE}" \
	--env "HTTPD=${HTTPD}" \
	--env "SERVICE_USER=${SERVICE_USER}" \
	--env "SERVICE_USER_GROUP=${SERVICE_USER_GROUP}" \
	--env "SERVICE_USER_PASSWORD=${SERVICE_USER_PASSWORD}" \
	--env "SUEXECUSERGROUP=${SUEXECUSERGROUP}" \
	--volumes-from ${VOLUME_CONFIG_NAME} \
	-v ${MOUNT_PATH_DATA}/${SERVICE_UNIT_NAME}/${SERVICE_UNIT_APP_GROUP}:${APP_HOME_DIR} \
	${DOCKER_IMAGE_REPOSITORY_NAME}${@:+ -c }"${@}"
)

# Linked MySQL + SSH + XDebug remote debugging port + Apache rewrite module
# (
# set -x
# docker run \
# 	${DOCKER_OPERATOR_OPTIONS} \
# 	--name "${DOCKER_NAME}" \
# 	${DOCKER_PORT_OPTIONS} \
# 	-p ${DOCKER_HOST_PORT_SSH:-}:22 \
# 	-p ${DOCKER_HOST_PORT_XDEBUG:-}:9000 \
# 	--link ${DOCKER_LINK_NAME_DB_MYSQL}:${DOCKER_LINK_ID_DB_MYSQL} \
# 	--env "SERVICE_UNIT_APP_GROUP=app-1" \
# 	--env "SERVICE_UNIT_LOCAL_ID=1" \
# 	--env "SERVICE_UNIT_INSTANCE=1" \
# 	--env "APACHE_EXTENDED_STATUS_ENABLED=true"
# 	--env "APACHE_LOAD_MODULES=${APACHE_LOAD_MODULES} rewrite_module" \
# 	--env "APACHE_MOD_SSL_ENABLED=false" \
# 	--env "APACHE_SERVER_ALIAS=app-1 www.app-1 www.app-1.local" \
# 	--env "APACHE_SERVER_NAME=app-1.local" \
# 	--env "APP_HOME_DIR=/var/www/app-1" \
# 	--env "DATE_TIMEZONE=Europe/London" \
# 	--env "HTTPD=/usr/sbin/httpd.worker" \
# 	--env "SERVICE_USER=app" \
# 	--env "SERVICE_USER_GROUP=app-www" \
# 	--env "SERVICE_USER_PASSWORD=" \
# 	--env "SUEXECUSERGROUP=false" \
# 	--volumes-from ${VOLUME_CONFIG_NAME} \
# 	-v ${MOUNT_PATH_DATA}/${SERVICE_UNIT_NAME}/${SERVICE_UNIT_APP_GROUP}:/var/www/app-1 \
# 	${DOCKER_IMAGE_REPOSITORY_NAME}${@:+ -c }"${@}"
# )

if is_docker_container_name_running ${DOCKER_NAME}; then
	docker ps | awk -v pattern="${DOCKER_NAME}$" '$NF ~ pattern { print $0 ; }'
	echo " ---> Docker container running."
fi
