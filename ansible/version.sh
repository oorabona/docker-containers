source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
  git-latest-tag ansible ansible
else
  git-check-tag ansible ansible $1
fi
