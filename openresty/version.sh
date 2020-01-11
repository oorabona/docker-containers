source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  docker-latest-tag openresty/openresty "^[0-9][^r|c]*alpine-fat$"
else
  docker-check-tag openresty/openresty "^${1}*alpine-fat$"
fi
