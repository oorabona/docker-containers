#!/usr/bin/env bash
# This is an example addon shell script
cat << eof
Hello there, this is the default addon script, you can find it useful to keep
the docker-entrypoint structure and add your extra configuration setup in here.

Possible use cases would include :
- init cloud credentials (AWS, etc.)
- init SSH keys with ssh-agent
- open a connection to a remote vault
etc.

In case you do not need any, you can easily remove either by setting an empty
ADDONSCRIPT environment variable or by simply removing the file.

Sleeping for 5 seconds so that you have a chance to read this intro :)
eof

sleep 5
