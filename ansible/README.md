# Docker container for Ansible

This container contains latest version (to date) of [Ansible](https://www.ansible.com).

## What it has inside

Everything needed to run playbooks, with a `docker-entrypoint` which has the following capabilities:

- run playbooks
- add extra `Ansible` packages, through the use of the  `requirements.yml` file
- wait for keypress when in `DEBUG` mode

> The latest is useful when you want to debug what is happening in the container before it goes into stopped/destroyed state.

When building this container, it adds all of your current `Ansible` configuration into `/tmp` directory.

It also provides a `VOLUME /tmp`, allowing you to use it as a development container too using `bind` mounting.

## Building notes

TODO

## Running notes

TODO

# Last words

Feel free to contribute, open issues or submit PR, they are all welcomed ! :beer:
