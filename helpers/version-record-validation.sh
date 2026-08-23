#!/usr/bin/env bash
# Shared jq validation contracts for GHCR package-version records used by the
# destructive registry pruners.  Callers deliberately choose one of the two
# named contracts below; they cannot supply their own field list.

# `created_at` is only checked for RFC3339 string shape here.  #1301 owns
# timestamp parsing and ordering semantics.
# shellcheck disable=SC2089
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

def version_base($index):
  if type != "object" then "versions[\($index)]"
  elif has("id") | not then "versions[\($index)].id is missing"
  elif (.id | valid_id | not) then "versions[\($index)].id is invalid"
  elif has("name") | not then "versions[\($index)].name is missing"
  elif (.name | type) != "string" then "versions[\($index)].name is invalid"
  elif (.name | test("^sha256:[0-9a-f]{64}\\z") | not) then "versions[\($index)].name is invalid"
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
# shellcheck disable=SC2090
export VERSION_RECORD_VALIDATION_JQ
