# Mysql workbench

This is a simple container with only `Mysql` client and `Mysql workbench` installed on a [Bitnami Minideb](https://github.com/bitnami/minideb) base image.

This makes the final Docker image going from roughly **596MB** (ubuntu:latest) down to **410MB**.

Could probably do better by not installing all the dependencies but this would come with some drawbacks I guess. Feel free to open an issue and/or PR if that matters to you !

## How to build

First off, git clone the repository. Then:

```sh
cd mysql-workbench
docker-compose build
```

## How to run

You can use the `docker-compose.yml` file in this directory to run the built image.

See [main README](README.md) for instructions on how to run this using shorthand `docker-compose`.

You can also run it using :

```sh
docker run --rm -e DISPLAY=unix$DISPLAY -v $HOME/.mysql-workbench:/root/.mysql/workbench -v /tmp/.X11-unix --net host --name workbench oorabona/mysql-workbench
```

Enjoy ! :heart:
