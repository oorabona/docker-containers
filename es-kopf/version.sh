source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
  latest-git-tag lmenezes elasticsearch-kopf "v.+$"
else
  check-git-tag lmenezes elasticsearch-kopf $1
fi
