# Ansible built from sources with support for external plugins (Galaxy & Python) 💚

A multi-platform Ansible container built from source with comprehensive plugin support and optimized builds for AMD64, ARM64, and ARM/v7 architectures.

![Docker Image Version (latest semver)](https://img.shields.io/docker/v/oorabona/ansible?sort=semver)
![Docker Pulls](https://img.shields.io/docker/pulls/oorabona/ansible)
![Docker Stars](https://img.shields.io/docker/stars/oorabona/ansible)

## Platforms

- `amd64`

![Docker Image Size AMD64 (latest semver)](https://img.shields.io/docker/image-size/oorabona/ansible?arch=amd64&sort=semver)

- `arm64`

![Docker Image Size ARM64 (latest semver)](https://img.shields.io/docker/image-size/oorabona/ansible?arch=arm64&sort=semver)

- `arm/v7`

![Docker Image Size ARM/v7 (latest semver)](https://img.shields.io/docker/image-size/oorabona/ansible?arch=arm&sort=semver)

## Features

This container contains latest version (to date) of [Ansible](https://www.ansible.com).

It is based on the latest version of Ubuntu.
Due to issues with `pip` and `setuptools` on `arm64` and `arm/v7` platforms, the container is built from sources.

All the dependencies required to build are removed from the final image.

Some additional packages are installed to allow the use of external plugins (Galaxy & Python).
Since this is based on Ubuntu you can install any package you need.

One last note, by default this container is rootless and runs as `ansible` user.
This is done to avoid issues with permissions when mounting volumes.

## Usage

### Docker

#### Version

```bash
docker run --rm -it oorabona/ansible \
    ansible --version
```

Outputs:

```shell
 __^__                                                                              __^__
( ___ )----------------------------------------------------------------------------( ___ )
 | / | Launching oorabona/ansible Docker container environment, welcome !           | \ |
 | / | Ansible version is : ansible [core 2.13.6]                                   | \ |
 | / | Running   python version = 3.10.6 (main, Nov  2 2022, 18:53:38) [GCC 11.3.0] | \ |
 | / |   jinja version = 3.1.2                                                      | \ |
 |___|                                                                              |___|
(_____)----------------------------------------------------------------------------(_____)
Setting up watches.
Couldn't watch requirements.txt: No such file or directory
Setting up watches.
Couldn't watch requirements.yml: No such file or directory
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
ansible [core 2.13.6]
  config file = None
  configured module search path = ['/home/ansible/.ansible/plugins/modules', '/usr/share/ansible/plugins/modules']
  ansible python module location = /usr/local/lib/python3.10/dist-packages/ansible
  ansible collection location = /home/ansible/.ansible/collections:/usr/share/ansible/collections
  executable location = /usr/local/bin/ansible
  python version = 3.10.6 (main, Nov  2 2022, 18:53:38) [GCC 11.3.0]
  jinja version = 3.1.2
  libyaml = True
```

### Docker Compose

```yaml
version: '3.7'
```

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

Among others `rust`, `gcc` and the `gcc` suite are installed _temporarily_. Once installation is complete, these packages will be removed automatically.

Although subject to various opinions, decision has been made from the very beginning to install `Ansible` under its own user and not as `root`. Not only for security reasons but also because of _bind mounting hell_ where temporary files from inside the containers created with `root` user could lead to some issues outside the container, on the host.

Last but not least, this container builds `Ansible` for use with `Python 3.x`.
No backward compatibility work will be done. Deal with that, _Python 2.x is dead_ :wink:

## Security

### Base Security
- **Non-root by default**: Runs as `ansible` user
- **Multi-stage build**: Build dependencies removed from final image
- **Ubuntu-based**: Regular security updates

### Runtime Hardening (Recommended)

```bash
# Secure runtime configuration
docker run --rm \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /run \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -v ./playbooks:/playbooks:ro \
  -v ~/.ssh:/home/ansible/.ssh:ro \
  oorabona/ansible ansible-playbook /playbooks/site.yml
```

### Docker Compose Security Template

```yaml
services:
  ansible:
    image: ghcr.io/oorabona/ansible:latest
    read_only: true
    tmpfs:
      - /tmp
      - /run
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - ./playbooks:/playbooks:ro
      - ./inventory:/inventory:ro
      - ~/.ssh:/home/ansible/.ssh:ro
```

### SSH Key Security
- Mount SSH keys as read-only (`:ro`)
- Use SSH agent forwarding when possible
- Never store SSH private keys in images

## Last words

Feel free to contribute, open issues or submit PR, they are all welcome ! :beer:
