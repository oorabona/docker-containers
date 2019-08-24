ARG DISTRIB=ubuntu
ARG VERSION=18.04
FROM ${DISTRIB}:${VERSION}

LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

# Default Python version will be 2.7 since python 3+ is named 'python3'
ARG PYTHON_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/home/ansible/.local/bin:${PATH}" \
    ADDONSCRIPT="/addon.sh" \
    PYTHON_VERSION=${PYTHON_VERSION}

COPY autoinstall /usr/local/bin
# Update system and install prerequisites
# Then we remove what should not be necessary anymore and clean
# DEPRECATED: python -m pip is required as per this ref bug : https://github.com/pypa/pip/issues/5599
RUN set -ex \
    && chmod +x /usr/local/bin/autoinstall \
    && apt-get update -y  &&  apt-get -y dist-upgrade                          \
    && apt-get install -y --no-install-recommends --no-install-suggests        \
                        python$PYTHON_VERSION python$PYTHON_VERSION-pip        \
                        dnsutils sudo curl vim openssh-client openssl boxes    \
                        inotify-tools python$PYTHON_VERSION-setuptools         \
    && apt-get install --fix-missing                                           \
# save list of currently-installed packages so build dependencies can be cleanly removed later
    && autoinstall build-essential g++ gcc python$PYTHON_VERSION-dev \
# Make sure we really have the latest versions of every package :)
    && pip$PYTHON_VERSION install -U pyasn1 setuptools paramiko cffi \
      cryptography pycrypto ansible \
    && apt-get remove --purge --auto-remove -y  \
    && rm -rf /var/lib/apt/lists/* /tmp/* /usr/share/doc/* /usr/share/man/*   \
    && echo "==[ Adding hosts for convenience... ]=="                          \
    && mkdir -p /etc/ansible                                                   \
    && echo "localhost ansible_python_interpreter=/usr/bin/python$PYTHON_VERSION" > /etc/ansible/hosts

# Create ansible user and drop privileges as soon as we can :)
# Note, we need to create $HOME for all plugins/modules related stuff required by
# Python and Ansible. Since it *seems* pointless to enable password protection.
RUN useradd -ms /bin/bash -G sudo ansible \
    && echo "ansible ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Copy all shell scripts to /
COPY *.sh /

RUN echo "==[ Ansible Docker build complete: host information... ]==" \
    && ansible -c local -m setup all \
    && sudo chmod +x /*.sh

USER ansible
WORKDIR  /home/ansible/playbook

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["ansible", "--version"]
