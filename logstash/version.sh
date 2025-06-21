source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  latest-docker-tag library/logstash "^[0-9]+\.[0-9]+$"
else
  check-docker-tag library/logstash "^${1}$"
fi
