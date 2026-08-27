# linux/amd64 manifest recorded from wolframresearch/wolframengine:latest on
# 2026-08-14. Update this digest deliberately when upgrading Wolfram Engine.
FROM wolframresearch/wolframengine@sha256:3ac08d6aaa33e6dccdda38d14cf8a7e5c22cc84d037a1a7562900914a487ef65

# linux/amd64 manifest for ghcr.io/astral-sh/uv:0.11.26. Every action mode uses
# pinned uv for SPF compatibility staging; release validation additionally syncs
# the locked Python cross-validation environment.
COPY --from=ghcr.io/astral-sh/uv@sha256:663211e7509e89ff2172cc3ca098afb4ac63028dd065d2b047e4251127a7d47a /uv /uvx /bin/

COPY main.sh /main.sh

USER root
RUN chmod +x /main.sh

ENTRYPOINT ["/main.sh"]
