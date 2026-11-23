# GitBucket on Railway: the official image, pinned by version and digest,
# plus a start script that wires PostgreSQL, sets the admin password before
# the public port opens, sizes the JVM and turns on SSH when a TCP proxy exists.
FROM ghcr.io/gitbucket/gitbucket:4.48.0@sha256:4383274e7b3bc089633d2626167f3365d16e90d00b49d9c60dce2948a9aab230

# psql/pg_isready: wait for the database and replace the built-in root/root password.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends postgresql-client \
 && rm -r /var/lib/apt/lists/*

COPY start.sh /usr/local/bin/gitbucket-railway-start
RUN chmod 0755 /usr/local/bin/gitbucket-railway-start

ENV GITBUCKET_HOME=/gitbucket
EXPOSE 8080 29418

# Keep the base image's ENTRYPOINT (Temurin CA-certificate shim); it execs CMD.
CMD ["/usr/local/bin/gitbucket-railway-start"]
