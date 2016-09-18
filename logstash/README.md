# Logstash customized Dockerfile

## What for ?

To maintain human-readability and peer reviewing, one directory per configuration (input/filter/output) is a good practice.

This image, tested at the moment only against `logstash:2.3.3` base image, will launch a single
instance of logstash per input.

This way, it ensures that no conflict will ever occur between different configurations.

For instance if a configuration file is wrong, only that logstash instance will
fail, leaving all other instances up and running.

It also starts faster as all logstash processes will be run in the background, asynchronously.

## What changes ?

`WORKDIR` is now set to `/etc/logstash/conf.d`.
Default `CMD` is now `-t` for testing configuration files with `logstash -t`.

There is also a new environment variable `CONFD_SUBDIRS`, which is by default set to `"*"`.

So by default, `docker-entrypoint.sh` will search the default `logstash` configuration directory,
`/etc/logstash/conf.d` for all subdirectories. It will launch a new `logstash` instance for each
directory found with parameters passed by the **COMMAND** parameter.

If you want to run specific configuration folders, separate them with spaces, as in:
`CONFD_SUBDIRS="foo bar baz"`.

# Examples

```sh
$ docker run -it -v /srv/logstash/conf.d:/etc/logstash/conf.d -v /srv/logstash/templates:/etc/logstash/templates oorabona/logstash -w 1
```

Will run `logstash -w 1 -f <config_path>` for each path found under `/etc/logstash/conf.d`.

> All logstash command line parameters can be used. But they will be set for all configuration files!
> I.e: in this example every `logstash` instance will run with *one worker*.

```sh
$ docker run -it -e CONFD_SUBDIRS="ad logspout" -v /srv/logstash/conf.d:/etc/logstash/conf.d -v /srv/logstash/templates:/etc/logstash/templates oorabona/logstash -w 1
```

Will run logstash as above but only for `ad` (ActiveDirectory) and `logspout`.

Other examples, for [Rancher Catalog](https://github.com/oorabona/rancher-catalog/blob/master/templates/logstash/0/docker-compose.yml) or plain [Docker-compose](https://github.com/oorabona/docker-compose) can be found on their
respective repositories.
