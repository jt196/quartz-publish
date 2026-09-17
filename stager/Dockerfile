# Vendored unchanged from github.com/jagajaga/private-quartz-publish
# server-example/stager/Dockerfile, pinned to commit 3687b47a9b04ffb5ebd2740f328b8310251cc99c.

FROM denoland/deno:2.1.4

WORKDIR /app
COPY main.ts /app/main.ts
RUN deno cache main.ts

CMD ["deno", "run", "--allow-read", "--allow-write", "--allow-env", "main.ts"]
