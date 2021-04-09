source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
  git-latest-tag openresty openresty | cut -c2-
else
  git-check-tag openresty openresty ${1} | cut -c2-
fi
