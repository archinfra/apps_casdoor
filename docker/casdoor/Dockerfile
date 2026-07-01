ARG CASDOOR_REF=master

FROM alpine/git:2.49.1 AS SRC
ARG CASDOOR_REF
RUN git clone --depth 1 --branch "${CASDOOR_REF}" https://github.com/casdoor/casdoor.git /src

FROM --platform=$BUILDPLATFORM node:20.20.1 AS FRONT
WORKDIR /web
COPY --from=SRC /src/web/package.json /src/web/yarn.lock ./
RUN yarn install --frozen-lockfile --network-timeout 1000000
COPY --from=SRC /src/web ./
RUN NODE_OPTIONS="--max-old-space-size=4096" CI=false yarn run build

FROM --platform=$BUILDPLATFORM golang:1.25.8 AS BACK
WORKDIR /go/src/casdoor
COPY --from=SRC /src/go.mod /src/go.sum ./
RUN go mod download
COPY --from=SRC /src ./
RUN ./build.sh

FROM alpine:latest
LABEL org.opencontainers.image.title="archinfra casdoor"
LABEL org.opencontainers.image.description="Self-built Casdoor image for archinfra offline .run packages"
LABEL org.opencontainers.image.source="https://github.com/casdoor/casdoor"

ARG USER=casdoor
ARG TARGETOS
ARG TARGETARCH
ENV BUILDX_ARCH="${TARGETOS:-linux}_${TARGETARCH:-amd64}"

RUN sed -i 's/https/http/' /etc/apk/repositories \
    && apk add --no-cache sudo tzdata curl ca-certificates \
    && update-ca-certificates \
    && adduser -D "${USER}" -u 1000 \
    && echo "${USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USER}" \
    && chmod 0440 "/etc/sudoers.d/${USER}" \
    && mkdir -p /logs /conf \
    && chown -R "${USER}:${USER}" /logs /conf

USER 1000
WORKDIR /
COPY --from=BACK --chown=${USER}:${USER} /go/src/casdoor/server_${BUILDX_ARCH} ./server
COPY --from=BACK --chown=${USER}:${USER} /go/src/casdoor/swagger ./swagger
COPY --from=BACK --chown=${USER}:${USER} /go/src/casdoor/conf/app.conf ./conf/app.conf
COPY --from=FRONT --chown=${USER}:${USER} /web/build ./web/build

EXPOSE 8000
ENTRYPOINT ["/server"]
