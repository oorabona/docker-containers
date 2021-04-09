#!/usr/bin/env bash
DEFAULT_FILTER="^[0-9][^r|c]*alpine$"

declare -A base_images
base_images['nginx']='nginx'
base_images['openresty']='openresty/openresty'
base_images['dnsmasq']='andyshinn/dnsmasq'
base_images['coredns']='coredns/coredns'

declare -A base_image_filter
base_image_filter['openresty']="^[0-9][^r|c]*alpine-fat$"
base_image_filter['coredns']="^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,2}$"

get_docker_latest_tags() {
  image="$1"
  filter=${2:-$DEFAULT_FILTER}
  tags=`wget -q https://registry.hub.docker.com/v1/repositories/${image}/tags -O -  | sed -e 's/[][]//g' -e 's/"//g' -e 's/ //g' | tr '}' '\n'  | awk -F: '{print $3}' | grep -E "${filter}" | sort -Vr | head -n1`

  # tags=` echo "${tags}" | grep "$2" `
  echo ${tags}
}

latest_tag=$(get_docker_latest_tags ${base_images[$1]} ${base_image_filter[$1]})
if [[ -z "$latest_tag" || -e "$latest_tag" ]]
then
  latest_tag=$(get_docker_latest_tags ${base_images[$1]} "^[0-9][^r|c]*")
fi

if [[ -z "$latest_tag" || -e "$latest_tag" ]]
then
  >&2 echo "Could not find any matching entry automagically for $1 (base image: ${base_images[$1]}). No Exiting."
  exit 1
fi

echo $latest_tag
