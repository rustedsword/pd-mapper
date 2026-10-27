FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    debhelper \
    devscripts \
    git \
    gnupg2 \
    lintian \
    pinentry-curses \
    ubuntu-dev-tools \
 && rm -rf /var/lib/apt/lists/*

# ubuntu-dev-tools pulls in dput-ng, which provides the dput command used for
# PPA uploads.

CMD ["bash"]
