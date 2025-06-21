source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
  latest-git-tag kelseyhightower confd "v.+$"
else
  check-git-tag kelseyhightower confd $1
fi
