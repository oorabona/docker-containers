#!/usr/bin/env bash
# This is an example addon shell script
cat << eof
Hello there, this is the example addon script. Nothing runs it unless you point
ADDONSCRIPT at it — there is no default. Keep the docker-entrypoint structure and
put your extra configuration setup in a script of your own.

Possible use cases would include :
- init cloud credentials (AWS, etc.)
- init SSH keys with ssh-agent
- open a connection to a remote vault
etc.

To stop it running, unset ADDONSCRIPT or set it empty — which is also the state
you get if you never set it at all.

Sleeping for 5 seconds so that you have a chance to read this intro :)
eof

sleep 5
