source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  latest-docker-tag library/postgres "^[0-9]+\.[0-9]+$"
else
  check-docker-tag library/postgres "^${1}$"
fi
