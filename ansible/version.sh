source "../helpers/python-tags"

if [ "$1" == "latest" ]; then
  get_pypi_latest_version ansible
else
  echo $1  # Return the version passed as argument
fi
