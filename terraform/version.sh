source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  docker-latest-tag hashicorp/terraform "^latest$"
else
  docker-check-tag hashicorp/terraform "^${1}$"
fi
