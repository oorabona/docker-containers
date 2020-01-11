#!/usr/bin/env bash
if [[ -r /opm-requirements.txt ]]; then
  cat opm-requirements.txt | xargs opm install
fi

if [[ -r /luarocks-requirements.txt ]]; then
  {
    while read req; do
      luarocks install $req
    done
  } < /luarocks-requirements.txt
fi

exec "$@"
