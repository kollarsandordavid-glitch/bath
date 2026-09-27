FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.14.1
ARG ZIG_SHA256=24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils && rm -rf /var/lib/apt/lists/*
RUN curl --fail --location --silent --show-error https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz --output /tmp/zig.tar.xz && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum --check - && mkdir -p /opt/zig && tar --extract --xz --file /tmp/zig.tar.xz --strip-components=1 --directory /opt/zig
ENV PATH=/opt/zig:$PATH
WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseSafe && zig build test -Doptimize=ReleaseSafe

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates poppler-utils && rm -rf /var/lib/apt/lists/* && useradd --create-home --uid 10001 agent
COPY --from=build /src/zig-out/bin/long-horizon-agent /usr/local/bin/long-horizon-agent
USER agent
WORKDIR /workspace
ENTRYPOINT ["long-horizon-agent"]
CMD ["help"]
