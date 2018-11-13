FROM ubuntu:18.04
MAINTAINER Olivier Orabona <olivier.orabona@gmail.com>

ENV DEBIAN_FRONTEND=noninteractive

# Update system and install prerequisites
# Then we remove what should not be necessary anymore and clean
# python -m pip is required as per this ref bug : https://github.com/pypa/pip/issues/5599
RUN set -ex  && \
    apt-get update -y  &&  apt-get dist-upgrade                       && \
    apt-get install -y python python-pip dnsutils sudo curl vim       \
                       openssh-client openssl                         && \
    apt-get install --fix-missing                                     && \
    python -m pip install -U pip                                      && \
    echo "==[ Adding hosts for convenience... ]=="                    && \
    mkdir -p /etc/ansible                                             && \
    echo 'localhost' > /etc/ansible/hosts

# Create ansible user and drop privileges as soon as we can :)
# Note, we need to create $HOME for all plugins/modules related stuff required by
# Python and Ansible. Since it *seems* pointless to enable "password protection"
# sudo will *not* let us gain root privileges, which is good but actually it's
# unfortunately not what we want. So we need to add an exception in the sudoers.
RUN useradd -ms /bin/bash -G sudo ansible                             && \
    echo "ansible ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers            && \
    mkdir -p /home/ansible/playbook

USER ansible
WORKDIR  /home/ansible/

ENV PATH="/home/ansible/.local/bin:${PATH}"

RUN set -ex  && \
    pip install virtualenv --user && \
    virtualenv ansible && \
    pip install --user -U pyasn1 setuptools paramiko cffi cryptography pycrypto ansible && \
    mkdir .ssh

COPY docker-entrypoint.sh /docker-entrypoint.sh

WORKDIR  /home/ansible/playbook
ONBUILD COPY  . .

# Adding extra libs from pip
ONBUILD RUN if [ -r requirements.txt ]; then \
              pip install --user -r requirements.txt; \
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