#!/bin/sh
# This script finalize installation of wordpress
# It is called by the main script (Cloudrly)

# Show some debug info
set -x

# Source the .env file if it exists
ENVFILE=$HOME/.env
if [ -f $ENVFILE ]; then
    . $ENVFILE
fi

# Wordpress installation URL
URL=$(echo https://$WEB_SERVICE_IP/${WP_ADMIN_PATH}/install.php?step=2)

echo "Finalizing installation of wordpress..."
echo "Home directory for wordpress is $HOME"

# Check that HOME directory exists
if [ ! -d $HOME ]; then
    echo "Fatal: $HOME does not exist" >&2
    exit 1
fi
cd $HOME

# Check that composer.json.template exists
if [ -f composer.json.template ]; then
    echo "File composer.json.template exists, initializing Wordpress installation..."
    echo ""
    echo "Provisionning Wordpress v${VERSION}..."
    envsubst '$VERSION' < composer.json.template > composer.json 
    cat composer.json 
    composer install
    echo -n "Cleaning up... "
    rm -rf composer.json.template ${APP_BASE_PATH}/wordpress/*.txt ${APP_BASE_PATH}/wordpress/*.html ${APP_BASE_PATH}/wordpress/wp-config-sample.php
    echo "done."

    echo ""
    echo -n "Installing config keys... "
    curl -q https://api.wordpress.org/secret-key/1.1/salt/ > $HOME/app/wp-config-keys.php
    echo "done."

    echo -n "Finalizing Wordpress installation... "
    curl -k -d "weblog_title=$WP_TITLE&user_name=$WP_ADMIN_USER&admin_password=$WP_ADMIN_PASSWORD&admin_password2=$WP_ADMIN_PASSWORD&admin_email=$WP_ADMIN_EMAIL" -H "Host: $WP_SITE_URL" $URL
    echo "done."
fi

echo "Wordpress installation completed."

# Checking existing installation of wordpress and wp-content
if [ -d $HOME/app/wordpress/wp-content ]; then
    echo "Removing existing wp-content directory."
    rm -rf $HOME/app/wordpress/wp-content
fi

# Processing requires json file with jq to install plugins and themes with composer require
if [ -f $HOME/install-requires.json ]; then
    cd $HOME
    echo "Installing plugins and themes..."
    jq -r  '.require | to_entries[] | .key + ":" + .value' $HOME/install-requires.json | xargs -I {} composer require {}
    jq -r '."require-dev" | to_entries[] | .key + ":" + .value' $HOME/install-requires.json | xargs -I {} composer require {} --dev
fi

echo "Installation completed."