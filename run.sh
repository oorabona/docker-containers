#!/usr/bin/env bash
set -e
SERVICES_YML=${2:-services.yml}

# Kudos goes to https://gist.github.com/ziwon/9b6acf2dc09849729efc97d50d253f9e
parse_yaml() {
    local prefix=$2
    local s
    local w
    local fs
    s='[[:space:]]*'
    w='[a-zA-Z0-9_\-]*'
    fs="$(echo @|tr @ '\034')"
    sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s[:-]$s\(.*\)$s\$|\1$fs\2$fs\3|p" "$1" |
    awk -F"$fs" '{
    indent = length($1)/2;
    vname[indent] = $2;
    for (i in vname) {if (i > indent) {delete vname[i]}}
        if (length($3) > 0) {
            vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
            printf("%s%s%s=(\"%s\")\n", "'"$prefix"'",vn, $2, $3);
        }
    }' | sed 's/_=/+=/g'
}

# read yaml file
available_services=$(parse_yaml ${SERVICES_YML} | grep services |
{
  while read l
  do
    echo "$l"|cut -d'_' -f2
  done
} | uniq )

if [ "$#" -eq 0 ]; then
  echo "Usage: $(basename $0) <service|app> [services.yml]"
  echo "Where <service|app> is one of the following:"
  echo "---"
  echo ${available_services}|tr ' ' '\n'
  echo "---"
  echo "If you want to override the default services.yml file you can change the second paramater (you know what you are doing !)"
  exit 0
fi

docker-compose -f ${SERVICES_YML} up $1
