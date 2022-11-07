ARG VARIANT=18-bullseye
# See: https://github.com/devcontainers/images/tree/main/src/base-ubuntu
FROM mcr.microsoft.com/vscode/devcontainers/typescript-node:${VARIANT}

# Install extra packages
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends bash-completion

# Enable Corepack
RUN corepack enable

# Switch to non-root user
USER 1000
# Install Foundry as non-root user (Foundry provides Blockchain tools)
RUN curl -L https://foundry.paradigm.xyz | bash && $HOME/.foundry/bin/foundryup
# Add bash-completions for Foundry
RUN mkdir -p $HOME/.local/share/bash-completion/completions && \
    $HOME/.foundry/bin/forge completions bash > $HOME/.local/share/bash-completion/completions/forge && \
    $HOME/.foundry/bin/cast completions bash > $HOME/.local/share/bash-completion/completions/cast && \
    $HOME/.foundry/bin/anvil completions bash > $HOME/.local/share/bash-completion/completions/anvil

# Add bash-completions for yarn
# Uses: https://github.com/dsifford/yarn-completion#readme
RUN mkdir -p "${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions/" && \
    curl -o "${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions/yarn" \
    https://raw.githubusercontent.com/dsifford/yarn-completion/master/yarn-completion.bash
