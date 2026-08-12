# Build the Sather compiler in one stage, then copy the finished tree into a
# slim runtime image.
#
# sacomp is GNU Sather 1.2.2 with the fixes needed to build and run correctly
# on a modern 64-bit host, and to emit ANSI C. See BUILDING.md in that repo.
FROM ubuntu:24.04 AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        gcc \
        git \
        libc6-dev \
        libgc-dev \
        make && \
    rm -rf /var/lib/apt/lists/*

ARG SACOMP_REPO=https://github.com/keiravillekode/sacomp
ARG SACOMP_REF=main

RUN git clone --depth 1 --branch "${SACOMP_REF}" "${SACOMP_REPO}" /opt/sather

# 'make full' rather than 'make small': the latter installs the pre-generated
# 2005 bootstrap compiler, which still emits the old non-ANSI C. Only the
# self-compiled compiler is built from the sources in the tree.
WORKDIR /opt/sather
# `sacomp -version' prints the version and then goes on to compile, so with
# no source to compile it exits non-zero. Check the output rather than the
# exit status.
RUN SATHER_HOME=/opt/sather make full && \
    SATHER_HOME=/opt/sather ./Bin/sacomp -version 2>&1 \
        | grep -q 'Sather compiler version'

# Drop what only the build needed. The compiler emits C and shells out to
# make, so the runtime image keeps gcc, make and the GC.
RUN rm -rf /opt/sather/.git /opt/sather/Doc /opt/sather/Emacs \
           /opt/sather/Browser /opt/sather/Test /opt/sather/debian

FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gawk \
        gcc \
        jq \
        libc6-dev \
        libgc-dev \
        make && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/sather /opt/sather

ENV SATHER_HOME=/opt/sather
ENV PATH="/opt/sather/Bin:${PATH}"

WORKDIR /opt/test-runner
COPY . .

# The harness ships with each exercise as an editor file; this copy is the
# fallback for solutions that do not carry one.
RUN mkdir -p /opt/exercism && \
    cp bin/parse-records.awk /opt/exercism/parse-records.awk && \
    cp harness/exercism_test.sa /opt/exercism/exercism_test.sa && \
    chmod +x bin/run.sh

ENTRYPOINT ["/opt/test-runner/bin/run.sh"]
