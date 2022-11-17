# docker-containers

This is my own Docker repository for `Dockerfile`s and their corresponding `docker-compose` files for easy launch/build.

Idea behind this is to allow easy maintenance of all packages I found useful to containerize.

---

Each directory with a Dockerfile relates to a container and will have repository of the same name in Docker Hub.

## How to build

To build, enjoy the simplicity of:

```sh
./make build <target>
```

To push, just:

```sh
./make push <target>
```

To run, with `docker-compose run --rm`:

```sh
./make run <target>
```

To view available target list:

```sh
./make list
```

## Feedback

Feel free to pull request if you want to contribute ! :beer:
