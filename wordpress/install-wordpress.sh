#!/usr/bin/env bash
set -ex
wp core download --locale=fr_FR --force --skip-content
wp core version
passgen=`head -c 10 /dev/random | base64`
password=${passgen:0:10}
wp user update admin --user_pass=$password
