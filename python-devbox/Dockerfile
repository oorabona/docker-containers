ARG python_version
FROM python:${python_version}
MAINTAINER Olivier Orabona <olivier.orabona@gmail.com>

# Update system and install prerequisites
# Then we remove what should not be necessary anymore and clean
# python -m pip is required as per this ref bug : https://github.com/pypa/pip/issues/5599
RUN set -ex  && \
    apt-get update -y                     && \
    apt-get install -y sudo curl          && \
    apt-get install --fix-missing

# Create app user and drop privileges as soon as we can :)
# Note, we need to create $HOME for all plugins/modules related stuff required by
# Python. Since it *seems* pointless to enable "password protection"
# sudo will *not* let us gain root privileges, which is good but actually it's
# unfortunately not what we want. So we need to add an exception in the sudoers.
RUN useradd -ms /bin/bash -G sudo app                             && \
    echo "app ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers            && \
    mkdir -p /home/app

USER app
WORKDIR  /home/app/

COPY docker-entrypoint.sh /docker-entrypoint.sh

ONBUILD COPY --chown=app . .

# Adding extra libs from pip
ONBUILD RUN if [ -r requirements.txt ]; then \
              pip install --user -r requirements.txt; \
            fi

# Clean image after ONBUILD images have finished
ONBUILD RUN sudo apt-get autoremove && sudo apt-get clean              && \
            sudo rm -rf /var/lib/apt/lists/*  /tmp/*

VOLUME /home/app

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["python", "--version"]
