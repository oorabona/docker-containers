#!/usr/bin/env bash
# Shared jq validation contracts for GHCR package-version records used by the
# destructive registry pruners.  Callers deliberately choose one of the named
# contracts below; they cannot supply their own field list.

# `created_at` is only checked for RFC3339 string shape here.  #1301 owns
# timestamp parsing and ordering semantics.
# shellcheck disable=SC2034,SC2089,SC2090
VERSION_RECORD_VALIDATION_JQ='
def valid_tag:
  # jq ^ is a true start anchor; use \z rather than $ so a final newline is
  # not silently accepted as part of a whole-string check.
  if type == "string" then test("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}\\z") else false end;

def valid_id:
  if type == "number" then (tostring | test("^[1-9][0-9]*\\z"))
  elif type == "string" then test("^[1-9][0-9]*\\z")
  else false
  end;

def valid_digest:
  if type == "string" then test("^sha256:[0-9a-f]{64}\\z") else false end;

def version_base($index):
  if type != "object" then "versions[\($index)]"
  elif has("id") | not then "versions[\($index)].id is missing"
  elif (.id | valid_id | not) then "versions[\($index)].id is invalid"
  elif has("name") | not then "versions[\($index)].name is missing"
  elif (.name | type) != "string" then "versions[\($index)].name is invalid"
  elif (.name | valid_digest | not) then "versions[\($index)].name is invalid"
  elif has("metadata") | not then "versions[\($index)].metadata is missing"
  elif (.metadata | type) != "object" then "versions[\($index)].metadata is invalid"
  elif (.metadata | has("container") | not) then "versions[\($index)].metadata.container is missing"
  elif (.metadata.container | type) != "object" then "versions[\($index)].metadata.container is invalid"
  elif (.metadata.container | has("tags") | not) then "versions[\($index)].metadata.container.tags is missing"
  elif (.metadata.container.tags | type) != "array" then "versions[\($index)].metadata.container.tags is invalid"
  else
    ([range(0; (.metadata.container.tags | length)) as $tag_index
      | .metadata.container.tags[$tag_index]
      | select(valid_tag | not)
      | "versions[\($index)].metadata.container.tags[\($tag_index)] is invalid"]
     | .[0])
  end;

def version_outdated_tags_contract($index):
  version_base($index);

def version_old_versions_contract($index):
  version_base($index) //
  (if has("created_at") | not then "versions[\($index)].created_at is missing"
   elif (.created_at | type) != "string" or (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})\\z") | not) then "versions[\($index)].created_at is invalid"
   else null
   end);

# A kept version may report an index.  Only direct descriptors that declare a
# plain image manifest are accepted without walking a further level of the graph.
def named_manifest_media_type:
  type == "string" and (
    . == "application/vnd.oci.image.index.v1+json" or
    . == "application/vnd.docker.distribution.manifest.list.v2+json" or
    . == "application/vnd.oci.image.manifest.v1+json" or
    . == "application/vnd.docker.distribution.manifest.v2+json"
  );

# This validates only the metadata each direct descriptor reports; its declared
# media type is not confirmed against the document at its digest.
def manifest_child_error($index):
  if type != "object" then "child descriptor \($index) is not an object"
  elif has("mediaType") | not then "child descriptor \($index) has no mediaType"
  elif has("mediaType") and ((.mediaType | type) != "string") then "child descriptor \($index) has a non-string mediaType"
  elif has("mediaType") and (.mediaType | named_manifest_media_type | not) then "child descriptor \($index) has unsupported mediaType \(.mediaType | @json)"
  elif .mediaType == "application/vnd.oci.image.index.v1+json" then "child descriptor \($index) is a nested OCI index"
  elif .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json" then "child descriptor \($index) is a nested Docker manifest list"
  elif has("digest") | not then "child descriptor \($index) has no digest"
  elif (.digest | valid_digest | not) then "child descriptor \($index) has a malformed digest"
  else null
  end;

# `first` stops evaluating direct descriptors once the first refusal is found.
# The caller reports only that refusal, so later descriptors are not inspected.
def first_manifest_child_error:
  first(
    range(0; (.manifests | length)) as $index
    | .manifests[$index]
    | manifest_child_error($index)
    | select(. != null)
  ) // null;

# This is deliberately a one-level protection contract.  It classifies a
# document from the metadata that document reports: its top-level mediaType,
# the presence and type of its manifests field, and the declared mediaType of
# each direct descriptor.  It does not fetch a child to confirm the media type
# declared by its descriptor.  A top-level subject is refused: adding only its
# digest to children would leave that subject document unfetched, so any child
# references it contains could not be classified.  The transitive walk needed
# to resolve subjects belongs to oorabona/docker-containers#1338.
def manifest_protection_contract:
  if type != "object" then error("top-level manifest is not an object")
  elif has("subject") then error("top-level manifest has an unresolved subject")
  elif has("mediaType") | not then error("top-level manifest has no mediaType")
  elif has("mediaType") and ((.mediaType | type) != "string") then error("top-level manifest has a non-string mediaType")
  elif has("mediaType") and (.mediaType | named_manifest_media_type | not) then error("top-level manifest has unsupported mediaType \(.mediaType | @json)")
  elif .mediaType == "application/vnd.oci.image.index.v1+json" then
    if has("manifests") | not then error("top-level OCI index has no manifests field")
    elif (.manifests | type) != "array" then error("top-level OCI index has a non-array manifests field")
    else first_manifest_child_error as $child_error
    | if $child_error == null then
        {children: [.manifests[].digest]}
      else error($child_error)
      end
    end
  elif .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json" then
    if has("manifests") | not then error("top-level Docker manifest list has no manifests field")
    elif (.manifests | type) != "array" then error("top-level Docker manifest list has a non-array manifests field")
    else first_manifest_child_error as $child_error
    | if $child_error == null then
        {children: [.manifests[].digest]}
      else error($child_error)
      end
    end
  elif .mediaType == "application/vnd.oci.image.manifest.v1+json" then
    if has("manifests") then error("top-level OCI image manifest has a manifests field")
    else {children: []}
    end
  elif .mediaType == "application/vnd.docker.distribution.manifest.v2+json" then
    if has("manifests") then error("top-level Docker image manifest has a manifests field")
    else {children: []}
    end
  end;

def versions_collection_contract:
  if type == "array" then null else "versions must be an array" end;

def duplicate_id_error:
  . as $versions
  | reduce range(0; length) as $index
      ({seen: {}, error: null};
        if .error != null then .
        else ($versions[$index].id | tostring) as $id
        | if .seen[$id] == null then .seen[$id] = $index
          else .error = "versions[\($index)].id duplicates an earlier value at versions[\(.seen[$id])]"
          end
        end)
  | .error;

# The package endpoint supplies a total to compare with a paginated versions
# listing.  This detects cardinality drift, not every omission: with 200
# records, deleting one from page 1 before page 2 shifts an offset so page 2
# skips a live record; the 199 collected records can then agree with a later
# package total of 199.  Duplicate IDs are checked separately.  This entry
# point is intentionally separate from validate_old_versions.
def validate_versions_listing_count($reported_count):
  versions_collection_contract as $collection_error
  | if $collection_error != null then error("validation failed: \($collection_error)")
    elif (($reported_count | type) != "number" or ($reported_count | floor) != $reported_count or $reported_count < 0 or length != $reported_count) then
      error("validation failed: package version_count is invalid or does not match the versions listing")
    else true
    end;

def validate_outdated_tags_versions:
  versions_collection_contract as $collection_error
  | if $collection_error != null then error("validation failed: \($collection_error)")
    else
      ([range(0; length) as $index | .[$index] | version_outdated_tags_contract($index)]
       | map(select(. != null)) | .[0]) as $record_error
      | ($record_error // duplicate_id_error) as $error
      | if $error == null then true else error("validation failed: \($error)") end
    end;

def validate_old_versions:
  versions_collection_contract as $collection_error
  | if $collection_error != null then error("validation failed: \($collection_error)")
    else
      ([range(0; length) as $index | .[$index] | version_old_versions_contract($index)]
       | map(select(. != null)) | .[0]) as $record_error
      | ($record_error // duplicate_id_error) as $error
      | if $error == null then true else error("validation failed: \($error)") end
    end;
'
