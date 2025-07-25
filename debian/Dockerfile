ARG VERSION=latest
FROM debian:${VERSION}
ARG LOCALES=en_US
ARG USER=debian
ARG GROUP=debian
ARG HOME=/home/${USER}
ARG SHELL=/bin/bash
ARG PASSWORD=debian

# Install locales and sudo
RUN apt-get update && apt-get dist-upgrade -y && apt-get install -y locales sudo aptitude ca-certificates && rm -rf /var/lib/apt/lists/*
RUN for l in ${LOCALES}; do \
    localedef -i $l -c -f UTF-8 -A /usr/share/locale/locale.alias ${l}.UTF-8; \
    done

# Use the first locale as the default
ENV LANG="${LOCALES%% *}.UTF-8"
ENV LANGUAGE="${LOCALES%% *}.UTF-8"
ENV LC_ALL="${LOCALES%% *}.UTF-8"
ENV DEBIAN_FRONTEND=noninteractive

# Check if the shell exists in the image and install it if it doesn't
RUN if [ ! -x ${SHELL} ]; then \
    apt-get update && apt-get install -y $(basename ${SHELL}) && rm -rf /var/lib/apt/lists/*; \
    fi

# Now create the user
RUN groupadd -r ${GROUP} && useradd -r -g ${GROUP} -d ${HOME} -s ${SHELL} ${USER}
RUN echo "${USER}:${PASSWORD}" | chpasswd

# Add the user to the sudoers
RUN echo "${USER} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/${USER}

# Add healthcheck to verify system is ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD whoami || exit 1

# Set the user and workdir
USER ${USER}
WORKDIR ${HOME}
