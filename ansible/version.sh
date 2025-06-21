source "../helpers/python-tags"

if [ "$1" == "latest" ]; then
  get_pypi_latest_version ansible
else
  git-check-tag ansible ansible $1
fi
