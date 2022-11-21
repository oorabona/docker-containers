ARG OS_VERSION=latest
FROM ubuntu:${OS_VERSION}

ARG VERSION=latest
LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/home/ansible/.local/bin:${PATH}" \
    ADDONSCRIPT="/addon.sh"

# Update system and install prerequisites
# Then we remove what should not be necessary anymore and clean
# DEPRECATED: python -m pip is required as per this ref bug : https://github.com/pypa/pip/issues/5599
RUN --mount=type=tmpfs,target=/root/.cargo                              set -ex \
    && apt-get update -y  &&  apt-get -y dist-upgrade                           \
    && apt-get install -y --no-install-recommends --no-install-suggests         \
                        python3 python3-pip inotify-tools python3-setuptools    \
                        dnsutils sudo curl vim openssh-client openssl boxes     \
                        libsodium23 \
    && apt-get install --fix-missing                                            \
# save list of currently-installed packages so build dependencies can be
# cleanly removed later
    && export BUILD_PACKAGES="build-essential g++ gcc python3-dev libffi-dev rustc cargo libsodium-dev" \
	&& export EXISTING_PACKAGES="$(mktemp)" && apt-mark showauto | sort > $EXISTING_PACKAGES \
	&& apt-get update && apt-get install -y --no-install-recommends $BUILD_PACKAGES \
	&& export NEW_PACKAGES="$(mktemp)" && apt-mark showauto | sort > $NEW_PACKAGES \
	&& export PACKAGES_TO_REMOVE="$(comm -23 $NEW_PACKAGES $EXISTING_PACKAGES)" \
# Make sure we really have the latest versions of every package,
# and for Ansible, the package version of our build ARG defined on top.
    && pip3 install --upgrade pip setuptools wheel \
# https://github.com/pyca/pynacl/issues/553
    && SODIUM_INSTALL=system pip3 install pynacl \
    && pip3 install -U pyasn1 paramiko cffi cryptography pycrypto ansible==${VERSION#?} \
    && apt-get remove --purge -y $BUILD_PACKAGES $PACKAGES_TO_REMOVE \
    && rm -rf /var/lib/apt/lists/* /tmp/* /usr/share/doc/* /usr/share/man/*   \
    && echo "==[ Adding hosts for convenience... ]=="                          \
    && mkdir -p /etc/ansible                                                   \
    && echo "localhost ansible_python_interpreter=/usr/bin/python3" > /etc/ansible/hosts

# Create ansible user and drop privileges as soon as we can :)
# Note, we need to create $HOME for all plugins/modules related stuff required by Python and Ansible.
# It *seems* pointless to enable password protection.
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
