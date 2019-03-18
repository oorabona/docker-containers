#!/bin/bash
set -euo pipefail

# We are assuming that we are in WORKDIR
HOST_UID=$(stat -c %u .)
HOST_GID=$(stat -c %g .)

# And we change wordpress UID/GID according to the host UID/GID (discard stderr)
sudo usermod -u $HOST_UID wordpress 2>/dev/null
sudo groupmod -g $HOST_GID wordpress 2>/dev/null

# Chown working directory (/var/www) to `wordpress` user
sudo chown -R wordpress. .

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
	if [ "$(id -u)" = '0' ]; then
		case "$1" in
			apache2*)
				user="${APACHE_RUN_USER:-www-data}"
				group="${APACHE_RUN_GROUP:-www-data}"

				# strip off any '#' symbol ('#1000' is valid syntax for Apache)
				pound='#'
				user="${user#$pound}"
				group="${group#$pound}"
				;;
			*) # php-fpm
				user='www-data'
				group='www-data'
				;;
		esac
	else
		user="$(id -u)"
		group="$(id -g)"
	fi
elif [[ "$1" == deploy ]]; then
	echo $@
	site=$2
	home_url="$3"
	from_home_url="$4"

	if [[ -z "$site" || -z "$home_url" || -z "$from_home_url" ]]; then
		echo "deploy <site_path> <site_url> <from_url>"
		echo "All options mandatory !"
		exit 1
	fi

	# allow any of these "Authentication Unique Keys and Salts." to be specified via
	# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
	uniqueEnvs=(
		AUTH_KEY
		SECURE_AUTH_KEY
		LOGGED_IN_KEY
		NONCE_KEY
		AUTH_SALT
		SECURE_AUTH_SALT
		LOGGED_IN_SALT
		NONCE_SALT
	)
	envs=(
		WORDPRESS_DB_HOST
		WORDPRESS_DB_USER
		# WORDPRESS_DB_PASSWORD
		# WORDPRESS_DB_NAME
		WORDPRESS_DB_CHARSET
		WORDPRESS_DB_COLLATE
		"${uniqueEnvs[@]/#/WORDPRESS_}"
		WORDPRESS_TABLE_PREFIX
		WORDPRESS_DEBUG
		WORDPRESS_CONFIG_EXTRA
	)

	for e in "${envs[@]}"; do
		file_env "$e"
	done

	# rewrite configuration
	: "${WORDPRESS_DB_HOST:=mysql}"
	: "${WORDPRESS_DB_CHARSET:=utf8}"
	: "${WORDPRESS_DB_COLLATE:=}"

	# version 4.4.1 decided to switch to windows line endings, that breaks our seds and awks
	# https://github.com/docker-library/wordpress/issues/116
	# https://github.com/WordPress/WordPress/commit/1acedc542fba2482bab88ec70d4bea4b997a92e4
	wordpressList=$(find * -maxdepth 0 -type d)
	echo "Found the following sites: ${wordpressList}"
	deployList=${deploy:-$wordpressList}
	echo "Going to deploy the following site(s): ${deployList}"

	# see http://stackoverflow.com/a/2705678/433558
	sed_escape_lhs() {
		echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
	}
	sed_escape_rhs() {
		echo "$@" | sed -e 's/[\/&]/\\&/g'
	}
	php_escape() {
		local escaped="$(php -r 'var_export(('"$2"') $argv[1]);' -- "$1")"
		if [ "$2" = 'string' ] && [ "${escaped:0:1}" = "'" ]; then
			escaped="${escaped//$'\n'/"' + \"\\n\" + '"}"
		fi
		echo "$escaped"
	}
	set_config() {
		key="$1"
		value="$2"
		var_type="${3:-string}"
		start="(['\"])$(sed_escape_lhs "$key")\2\s*,"
		end="\);"
		if [ "${key:0:1}" = '$' ]; then
			start="^(\s*)$(sed_escape_lhs "$key")\s*="
			end=";"
		fi
		sed -ri -e "s/($start\s*).*($end)$/\1$(sed_escape_rhs "$(php_escape "$value" "$var_type")")\3/" wp-config.php
	}

	getpw() {
		echo $(tr -cd '[:alnum:]' < /dev/urandom | fold -w30 | head -n1)
	}

	for wordpress in ${deployList}; do
		echo "Processing $wordpress ..."
		pushd $wordpress

		WORDPRESS_DB_USER=${wordpress}
		WORDPRESS_DB_NAME=${WORDPRESS_DB_USER}
		echo "Wordpress DB user ${WORDPRESS_DB_USER}"
		WORDPRESS_DB_PASSWORD=$(getpw)
		echo "Wordpress DB password ${WORDPRESS_DB_PASSWORD}"

		set_config 'DB_HOST' "$WORDPRESS_DB_HOST"
		set_config 'DB_PASSWORD' "$WORDPRESS_DB_PASSWORD"
		set_config 'DB_USER' "$WORDPRESS_DB_USER"
		set_config 'DB_NAME' "$WORDPRESS_DB_NAME"	# same as user
		set_config 'DB_CHARSET' "$WORDPRESS_DB_CHARSET"
		set_config 'DB_COLLATE' "$WORDPRESS_DB_COLLATE"

		for unique in "${uniqueEnvs[@]}"; do
			uniqVar="WORDPRESS_$unique"
			if [ -n "${!uniqVar}" ]; then
				set_config "$unique" "${!uniqVar}"
			else
				# if not specified, let's generate a random value
				currentVal="$(sed -rn -e "s/define\((([\'\"])$unique\2\s*,\s*)(['\"])(.*)\3\);/\4/p" wp-config.php)"
				if [ "$currentVal" = 'put your unique phrase here' ]; then
					set_config "$unique" "$(head -c1m /dev/urandom | sha1sum | cut -d' ' -f1)"
				fi
			fi
		done

		if [ "$WORDPRESS_TABLE_PREFIX" ]; then
			set_config '$table_prefix' "$WORDPRESS_TABLE_PREFIX"
		fi

		if [ "$WORDPRESS_DEBUG" ]; then
			set_config 'WP_DEBUG' 1 boolean
		fi

		# Use WP CLI to check database connection
		if ! wp db check > /dev/null; then
  		echo "Cannot connect to database, creating."
			sql="CREATE DATABASE IF NOT EXISTS ${WORDPRESS_DB_NAME}; CREATE USER IF NOT EXISTS '${WORDPRESS_DB_USER}'@'%' IDENTIFIED BY '${WORDPRESS_DB_PASSWORD}'; ALTER USER ${WORDPRESS_DB_USER} IDENTIFIED BY '${WORDPRESS_DB_PASSWORD}'; GRANT ALL PRIVILEGES ON ${WORDPRESS_DB_NAME}.* TO '${WORDPRESS_DB_USER}'@'%'; FLUSH PRIVILEGES"
			echo $sql
			mysql -uroot -p${WORDPRESS_ROOT_PASSWORD} -h${WORDPRESS_DB_HOST} -e "$sql"
		fi
		if ! wp db check > /dev/null; then
  		echo "Still not able to create user/database. Aborting"
			exit 1
		fi

		# load data from sql dump if any
		if [ -r ${wordpress}.sql ]; then
			wp db import ${wordpress}.sql
			# mysql -u${WORDPRESS_DB_USER} -p${WORDPRESS_DB_PASSWORD} -h${WORDPRESS_DB_HOST} ${WORDPRESS_DB_NAME} < ${wordpress}.sql
		fi

		# Use WP CLI to change URL
		wp option update home "${home_url}"
		wp option update siteurl "${home_url}"
		wp search-replace "${from_home_url}" "${home_url}" --skip-columns=guid
		popd
	done

	# now that we're definitely done writing configuration, let's clear out the relevant envrionment variables (so that stray "phpinfo()" calls don't leak secrets from our code)
	for e in "${envs[@]}"; do
		unset "$e"
	done
	exit 0
fi

exec "$@"
