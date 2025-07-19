#!/usr/bin/env bash
source ../helpers/docker-tag

# Get only the latest 10 (8 + light/latest) versions (tags)
version_tags=$(latest-docker-tag "hashicorp/terraform" "^[0-9]+\.[0-9]+\.[0-9]+$" | head -8)
tags=$(echo -e "$version_tags\nlight\nlatest")

# For each tag found build
echo "The following tags will be built upon: $(echo $tags | tr '\n' ' ')"

for tag in $tags
do
  echo "=> ${1}ing oorabona/terraform:$tag from hashicorp/terraform:$tag"
  TERRAFORM_VERSION=$tag docker-compose $1
done
