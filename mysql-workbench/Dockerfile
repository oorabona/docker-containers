ARG OS_VERSION=latest

FROM ubuntu:${OS_VERSION}

LABEL maintainer="Olivier Orabona <olivier.orabona@gmail.com>"

RUN   apt-get update && apt-get dist-upgrade -y && apt-get install -y mysql-workbench

CMD ["mysql-workbench"]
