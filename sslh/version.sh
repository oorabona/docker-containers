source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
  latest-git-tag yrutschle sslh "v.+$"
else
  check-git-tag yrutschle sslh $1
fi
