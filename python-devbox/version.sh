source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  latest-docker-tag library/python "^[0-9]+\.[0-9]+\.[0-9]+-slim$"
else
  check-docker-tag library/python "^${1}$"
fi
