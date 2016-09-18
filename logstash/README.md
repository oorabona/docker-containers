# Logstash customized Dockerfile

## What for ?

To maintain human-readability and peer reviewing, one directory per configuration
is a good practice.

This image, tested at the moment only against `logstash:2.3.3` base image, will launch a single
instance of logstash per input.

This way, it ensures that no conflict will ever occur between different configurations.

For instance if a configuration file is wrong, only that logstash instance will
fail, leaving all other instances up and running.

It also starts faster as all logstash processes will be run in the background asynchronously.

## What changes ?

`WORKDIR` now set to `/etc/logstash/conf.d`.
Default `CMD` is now `-t` for testing configuration files.

There is a new environment variable `CONFD_SUBDIRS`, by default it is set to `"*"`.

So by default, `docker-entrypoint.sh` will search the default `logstash` configuration directory,
`/etc/logstash/conf.d` for all subdirectories. It will launch a new `logstash` instance for each
directory found with parameters passed as the **COMMAND**.

If you want to run specific configuration folders, separate them with spaces.

# Examples

```sh
$ docker run -it -v /srv/logstash/conf.d:/etc/logstash/conf.d -v /srv/logstash/templates:/etc/logstash/templates oorabona/logstash -w 1
```

Will run `logstash -w 1 -f <config_path>` for each path found under `/etc/logstash/conf.d`.

> All logstash command line parameters can be used. But they will be set for all configuration files!
> E.g: here every `logstash` instance will run with *one worker*.

```sh
$ docker run -it -e CONFD_SUBDIRS="ad logspout" -v /srv/logstash/conf.d:/etc/logstash/conf.d -v /srv/logstash/templates:/etc/logstash/templates oorabona/logstash -w 1
```

Will run logstash as above but only for `ad` (ActiveDirectory) and `logspout`.

Other examples, for [Rancher Catalog](/oorabona/rancher-catalog) or plain [Docker-compose](/oorabona/docker-compose) can be found on their
respective repositories.
