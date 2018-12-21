FROM ubuntu:18.10

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes software-properties-common \
    && add-apt-repository ppa:apt-fast/stable \
    && apt-get install --yes apt-fast \
    && add-apt-repository --yes ppa:hvr/ghc \
    && apt-fast install --yes \
    ghc-8.4.4 cabal-install-2.4 \
    build-essential \
    zlib1g-dev libtinfo-dev \
    curl
ENV PATH="/opt/ghc/bin:/opt/cabal/bin:${PATH}"

RUN useradd -ms /bin/bash galois
USER galois
RUN mkdir /home/galois/renovate
WORKDIR /home/galois/renovate

ADD --chown=galois cabal.project cabal.project
ADD --chown=galois deps deps
ADD --chown=galois refurbish/refurbish.cabal ./refurbish/refurbish.cabal
ADD --chown=galois renovate/renovate.cabal ./renovate/renovate.cabal
ADD --chown=galois renovate-x86/renovate-x86.cabal ./renovate-x86/renovate-x86.cabal
ADD --chown=galois renovate-ppc/renovate-ppc.cabal ./renovate-ppc/renovate-ppc.cabal
RUN cabal new-update
RUN cabal new-build --only-dependencies all
ADD --chown=galois . .
RUN cabal new-build renovate-x86

ENV PATH="/home/galois/.local/bin:${PATH}"
RUN cabal new-install all
