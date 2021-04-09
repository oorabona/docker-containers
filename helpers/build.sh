#!/usr/bin/env bash
source ../helpers/docker-tags

# Get only the latest 10 (8 + light/latest) versions (tags)
version_tags=$(docker-tags "hashicorp/terraform" | jq --raw-output '.tags[]' | grep -v '[beta|rc]' | sort -t. -k 1,1n -k 2,2n -k 3,3n | tail -n8)
tags=$(echo -e "$version_tags\nlight\nlatest")

# For each tag found build
echo "The following tags will be built upon: $(echo $tags | tr '\n' ' ')"

for tag in $tags
do
  echo "=> ${1}ing oorabona/terraform:$tag from hashicorp/terraform:$tag"
  TERRAFORM_VERSION=$tag docker-compose $1
done
