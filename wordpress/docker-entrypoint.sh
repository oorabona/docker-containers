#!/bin/bash
set -euo pipefail

# Match wordpress UID/GID to host volume ownership (only when running as root)
if [ "$(id -u)" = '0' ]; then
	HOST_UID=$(stat -c %u .)
	HOST_GID=$(stat -c %g .)
	if [ "$HOST_UID" != "$(id -u wordpress)" ]; then
		usermod -u "$HOST_UID" wordpress 2>/dev/null || true
	fi
	if [ "$HOST_GID" != "$(getent group wordpress | cut -d: -f3)" ]; then
		groupmod -g "$HOST_GID" wordpress 2>/dev/null || true
	fi
	chown -R wordpress:wordpress .
fi

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

# Run wp-cli with stderr suppressed (PHP 8.5 deprecation warnings in wp-cli)
wp_cmd() {
	wp "$@" 2>/dev/null
}

# Generate security hardening PHP defines based on environment variables.
# Each constant defaults to off (permissive) when the env var is unset.
# Managed hosting platforms (e.g. khi) set these to lock down the container.
_security_defines() {
	if [ "${DISALLOW_FILE_MODS:-}" = "true" ]; then
		echo "define('DISALLOW_FILE_MODS', true);"
	fi
	if [ "${DISALLOW_FILE_EDIT:-}" = "true" ]; then
		echo "define('DISALLOW_FILE_EDIT', true);"
	fi
	if [ "${WP_AUTO_UPDATE_CORE:-}" = "false" ]; then
		echo "define('WP_AUTO_UPDATE_CORE', false);"
	fi
	if [ "${AUTOMATIC_UPDATER_DISABLED:-}" = "true" ]; then
		echo "define('AUTOMATIC_UPDATER_DISABLED', true);"
	fi
}

if [ "$1" = "php-fpm" ]; then

	# --- Phase 1: Generate wp-config.php ---
	if [ ! -f wp-config.php ]; then
		if [ "${WP_DB_TYPE:-mysql}" = "sqlite" ]; then
			# SQLite mode — no external database needed
			echo "Configuring WordPress with SQLite backend..."
			mkdir -p wp-content/database

			# Activate the SQLite drop-in (pre-installed at build time)
			if [ -f wp-content/plugins/sqlite-database-integration/db.copy ]; then
				cp wp-content/plugins/sqlite-database-integration/db.copy wp-content/db.php
			fi

			# wp config create requires db params even for SQLite; they're ignored
			{
				cat <<-'PHP'
				/* SQLite database path */
				define('DB_DIR', ABSPATH . 'wp-content/database/');
				define('DB_FILE', '.ht.sqlite');
				PHP
				_security_defines
			} | wp_cmd config create \
				--dbname=wordpress --dbuser='' --dbpass='' --dbhost='' \
				--skip-check \
				--extra-php
		elif [ -n "${WORDPRESS_DB_HOST:-}" ]; then
			# MySQL/MariaDB mode
			file_env 'WORDPRESS_DB_HOST'
			file_env 'WORDPRESS_DB_NAME' 'wordpress'
			file_env 'WORDPRESS_DB_USER' 'root'
			file_env 'WORDPRESS_DB_PASSWORD' ''

			_security_defines | wp_cmd config create \
				--dbhost="$WORDPRESS_DB_HOST" \
				--dbname="$WORDPRESS_DB_NAME" \
				--dbuser="$WORDPRESS_DB_USER" \
				--dbpass="$WORDPRESS_DB_PASSWORD" \
				--skip-check \
				--extra-php
		fi
	fi

	# --- Phase 2: Auto-install WordPress ---
	if [ "${WP_AUTO_INSTALL:-}" = "true" ] && ! wp_cmd core is-installed; then
		file_env 'WP_SITE_URL' 'http://localhost'
		file_env 'WP_SITE_TITLE' 'WordPress Site'
		file_env 'WP_ADMIN_USER' 'admin'
		file_env 'WP_ADMIN_PASSWORD'
		file_env 'WP_ADMIN_EMAIL'

		if [ -z "${WP_ADMIN_PASSWORD:-}" ] || [ -z "${WP_ADMIN_EMAIL:-}" ]; then
			echo >&2 "error: WP_AUTO_INSTALL requires WP_ADMIN_PASSWORD and WP_ADMIN_EMAIL"
			exit 1
		fi

		echo "Installing WordPress at ${WP_SITE_URL}..."
		wp_cmd core install \
			--url="${WP_SITE_URL}" \
			--title="${WP_SITE_TITLE}" \
			--admin_user="${WP_ADMIN_USER}" \
			--admin_password="${WP_ADMIN_PASSWORD}" \
			--admin_email="${WP_ADMIN_EMAIL}" \
			--skip-email

		# Locale
		if [ -n "${WP_LOCALE:-}" ]; then
			echo "Setting locale: ${WP_LOCALE}"
			wp_cmd language core install "$WP_LOCALE" --activate
		fi

		# Timezone
		if [ -n "${WP_TIMEZONE:-}" ]; then
			wp_cmd option update timezone_string "$WP_TIMEZONE"
		fi

		# SEO-friendly permalinks
		wp_cmd rewrite structure '/%postname%/'

		# Plugins (comma-separated)
		if [ -n "${WP_PLUGINS:-}" ]; then
			IFS=',' read -ra plugins <<< "$WP_PLUGINS"
			for plugin in "${plugins[@]}"; do
				plugin="${plugin## }"  # trim leading space
				plugin="${plugin%% }"  # trim trailing space
				echo "Installing plugin: ${plugin}"
				wp_cmd plugin install "$plugin" --activate || echo >&2 "warning: failed to install plugin '$plugin'"
			done
		fi

		# Disable search engine indexing until hoster is ready
		wp_cmd option update blog_public 0

		echo "WordPress installation complete."
	fi

	# Clear sensitive env vars from the runtime environment
	unset WORDPRESS_DB_PASSWORD WP_ADMIN_PASSWORD 2>/dev/null || true

elif [[ "$1" == deploy ]]; then
	echo $@
	site=$2
	new_home_url="$3"

	if [[ -z "$site" || -z "$new_home_url" ]]; then
		echo "deploy <site_path> <site_url> [from_url]"
		echo "e.g. deploy wp_pbs www.pbs.site uat.pbs.site"
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
	deployList=${site:-$wordpressList}
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

		WORDPRESS_DB_USER=${wordpress/-/_}
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
		for sqlfile in *.sql; do
			wp db import ${sqlfile}
			# mysql -u${WORDPRESS_DB_USER} -p${WORDPRESS_DB_PASSWORD} -h${WORDPRESS_DB_HOST} ${WORDPRESS_DB_NAME} < ${wordpress}.sql
		done

		# Use WP CLI to change URL
		wp_home_url=$(wp option get home)
		from_home_url=${from_home_url:-$wp_home_url}
		new_home_url="https://${wp_home_url}"
		echo "Updating site from ${from_home_url} to new ${new_home_url}"
		wp option update home "${new_home_url}"
		wp option update siteurl "${new_home_url}"
		wp search-replace "${from_home_url}" "${new_home_url}" --skip-columns=guid
		popd
	done

	# now that we're definitely done writing configuration, let's clear out the relevant envrionment variables (so that stray "phpinfo()" calls don't leak secrets from our code)
	for e in "${envs[@]}"; do
		unset "$e"
	done
	exit 0
fi

exec "$@"
