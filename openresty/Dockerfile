ARG RESTY_IMAGE_TAG="bionic"

FROM openresty/openresty:${RESTY_IMAGE_TAG}

LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

COPY docker-entrypoint.sh /

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
# Use SIGQUIT instead of default SIGTERM to cleanly drain requests
# See https://github.com/openresty/docker-openresty/blob/master/README.md#tips--pitfalls
STOPSIGNAL SIGQUIT
