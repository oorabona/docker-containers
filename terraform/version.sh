source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  # docker-latest-tag hashicorp/terraform "^latest$"
  latest-docker-tag hashicorp/terraform "^[0-9]+\.[0-9]+\.[0-9]+$"
else
  check-docker-tag hashicorp/terraform "^${1}$"
fi
