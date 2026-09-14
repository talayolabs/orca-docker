# Example per-repository image. Copy to <your-repo>/docker/Dockerfile; orca-docker builds it
# automatically (cached by content hash) whenever it launches an agent in that repo.
#
# Keep it thin: apt/system packages and global tools go here; node_modules are installed
# from the repo lockfile at container start (see image/session.sh), never baked in.
FROM ghcr.io/talayolabs/orca-docker:latest

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client redis-tools \
    && rm -rf /var/lib/apt/lists/*

# Global CLIs the project relies on
RUN npm install -g vercel@latest && npm cache clean --force

# Optional: project-specific setup that must run before the agent starts.
ENV ORCA_DOCKER_INIT="cp -n .env.example .env 2>/dev/null || true"
