# Terraform

This [Docker](https://www.docker.com) image extends [Terraform](https://www.terraform.io) `.tf` with [JinJa2](http://jinja.pocoo.org/) templating engine.

This allows enhancement and reusability (also known as **D**on't **R**epeat **Y**ourself) across your Terraform definitions.

# How to use

In your Terraform registry, you just have to add `.j2` to your `.tf` files.
All `.tf.j2` will be processed using a configuration file named `config.json`.

This configuration file must reside in the root directory of your Terraform repository.

# Parameters

* The environment variable `CONFIGFILE` (*default: `config.json`*) Jinja2 configuration file holding template parameters.

# Volumes

In the container, `/data` is the base directory of your Terraform configuration.
It is actually both a **WORKDIR** and a **VOLUME**.

For instance you can put the sample `docker-compose.yml` in the same repository of your Terraform code.

If you do not want to proceed that way, `git` has also been installed in the container, allowing for in-container cloning.
