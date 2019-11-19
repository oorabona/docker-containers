source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
  git-latest-tag yrutschle sslh
else
  git-check-tag yrutschle sslh $1
fi
