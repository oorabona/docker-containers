source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  latest-docker-tag library/ubuntu "^[0-9]+\.[0-9]+$"
else
  check-docker-tag library/ubuntu "^${1}$"
fi
