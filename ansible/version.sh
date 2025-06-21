source "../helpers/python-tags"

if [ "$1" == "latest" ]; then
  get_pypi_latest_version ansible
else
  check_git_tag $1  # Validate and return the version passed as argument
fi

check_git_tag() {
  local version=$1
  if git ls-remote --tags origin | grep -q "refs/tags/$version$"; then
    echo $version
  else
    echo "Error: Version $version does not exist upstream." >&2
    exit 1
  fi
}
