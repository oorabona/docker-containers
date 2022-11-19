# Ansible built from sources with support for external plugins (Galaxy & Python) 💚

This container contains latest version (to date) of [Ansible](https://www.ansible.com).

## What it has inside

Everything needed to run playbooks, with a `docker-entrypoint` shell script which has the following capabilities:

- run playbooks
- add extra `Ansible` packages, through the use of the  `requirements.yml` file
- add extra `Python` packages, using the `requirements.txt` file
- wait for keypress when `WAIT_BEFORE_EXIT` environment variable is set

> `WAIT_BEFORE_EXIT` is useful mostly when doing debug or at least when you are
in tty-enabled shell. Unacceptable behaviors can otherwise happen.

By using bind mounting, this Docker container can be reused in all your `Ansible` configurations.

It may be useful to rebuild it when doing some customization, like adding packages (e.g `awscli`) or loading ssh keys ...

## Build notes

You can use this Dockerfile to install whichever `Ansible` version you want, but by default it is the latest.

Among others `gcc` and the `gcc` suite are installed _temporarily_. Means that once installation is complete, these packages will be removed automatically.

Although subject to various opinions, decision has been made from the very beginning to install `Ansible` under its own user and not as `root`. Not only for security reasons but also because of _bind mounting hell_ where temporary files from inside the containers created with `root` user could lead to some issues outside the container, on the host.

Last but not least, this container builds `Ansible` for use with `Python 3.x`.
No backward compatibility work will be done. Deal with that, _Python 2.x is dead_ :wink:

## Last words

Feel free to contribute, open issues or submit PR, they are all welcome ! :beer:
