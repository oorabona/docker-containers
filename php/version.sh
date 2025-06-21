source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  latest-docker-tag library/php "^[0-9]+\.[0-9]+\.[0-9]+-fpm-alpine$"
else
  check-docker-tag library/php "^${1}$"
fi