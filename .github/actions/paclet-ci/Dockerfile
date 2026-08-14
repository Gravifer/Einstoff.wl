# linux/amd64 manifest recorded from wolframresearch/wolframengine:latest on
# 2026-08-14. Update this digest deliberately when upgrading Wolfram Engine.
FROM wolframresearch/wolframengine@sha256:3ac08d6aaa33e6dccdda38d14cf8a7e5c22cc84d037a1a7562900914a487ef65

COPY main.sh /main.sh

USER root
RUN chmod +x /main.sh

ENTRYPOINT ["/main.sh"]
