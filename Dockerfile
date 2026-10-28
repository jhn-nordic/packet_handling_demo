FROM alpine:3.22

ARG PB_VERSION=0.40.5
ARG TARGETARCH

RUN apk add --no-cache ca-certificates unzip wget \
 && wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${TARGETARCH:-amd64}.zip" -O /tmp/pb.zip \
 && unzip /tmp/pb.zip pocketbase -d /pb \
 && rm /tmp/pb.zip \
 && apk del unzip wget

WORKDIR /pb
COPY pocketbase/pb_migrations ./pb_migrations
COPY pocketbase/pb_hooks ./pb_hooks
COPY pocketbase/pb_public ./pb_public
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# SQLite database + uploaded files. Mount a volume here.
VOLUME /pb/pb_data
EXPOSE 8090

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["serve", "--http=0.0.0.0:8090"]
