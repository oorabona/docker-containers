source "../helpers/git-tags"

if [ "$1" == "latest" ]; then
  latest-git-tag openresty openresty | cut -c2-
else
  check-git-tag openresty openresty ${1} | cut -c2-
fi
