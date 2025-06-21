source "../helpers/docker-tags"

if [ "$1" == "latest" ]; then
  latest-docker-tag library/debian "^(bookworm|bullseye|buster)$"
else
  check-docker-tag library/debian "^${1}$"
fi
