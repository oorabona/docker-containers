FROM ubuntu:18.04
MAINTAINER Olivier Orabona <olivier.orabona@gmail.com>

# This helps in detecting which Docker container version you use
ARG ANSIBLE_ENV
ARG PYTHON_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    ANSIBLE_ENV=$ANSIBLE_ENV \
    PATH="/home/ansible/.local/bin:${PATH}" \
    ADDONSCRIPT="/addon.sh"

# Update system and install prerequisites
# Then we remove what should not be necessary anymore and clean
# python -m pip is required as per this ref bug : https://github.com/pypa/pip/issues/5599
RUN set -ex  && \
    apt-get update -y  &&  apt-get -y dist-upgrade                          && \
    apt-get install -y python$PYTHON_VERSION python$PYTHON_VERSION-pip         \
                       dnsutils sudo curl vim openssh-client openssl boxes  && \
    apt-get install --fix-missing                                           && \
    python$PYTHON_VERSION -m pip install -U pip                             && \
    echo "==[ Adding hosts for convenience... ]=="                          && \
    mkdir -p /etc/ansible                                                   && \
    echo "localhost ansible_python_interpreter=/usr/bin/python$PYTHON_VERSION" > /etc/ansible/hosts

# Copy all shell scripts to /
COPY *.sh /

# Create ansible user and drop privileges as soon as we can :)
# Note, we need to create $HOME for all plugins/modules related stuff required by
# Python and Ansible. Since it *seems* pointless to enable "password protection"
# sudo will *not* let us gain root privileges, which is good but actually it's
# unfortunately not what we want. So we need to add an exception in the sudoers.
RUN useradd -ms /bin/bash -G sudo ansible                             && \
    echo "ansible ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers            && \
    chmod +x /*.sh

USER ansible
WORKDIR  /home/ansible/

RUN set -ex  && \
    pip$PYTHON_VERSION install virtualenv --user && \
    pip$PYTHON_VERSION install --user -U pyasn1 setuptools paramiko cffi cryptography pycrypto ansible && \
    mkdir .ssh playbook

WORKDIR  /home/ansible/playbook

# Copy ansible repository
ONBUILD ARG sourcePath=.
ONBUILD COPY $sourcePath .

# Adding extra libs from pip
ONBUILD RUN if [ -r requirements.txt ]; then \
              pip$PYTHON_VERSION install --user -r requirements.txt; \
            fi

# Adding extra libs from ansible-galaxy
ONBUILD RUN if [ -r requirements.yml ]; then \
              ansible-galaxy install -r requirements.yml; \
            fi

# Clean image after ONBUILD images have finished
ONBUILD RUN sudo apt-get autoremove && sudo apt-get clean              && \
            sudo rm -rf /var/lib/apt/lists/*  /tmp/*

VOLUME /home/ansible/playbook

RUN echo "==[ Ansible Docker build complete: host information... ]=="  && \
              ansible -c local -m setup all

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["ansible", "--version"]
