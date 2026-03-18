# FOSSology Worker — SSH-accessible agent execution node
# Extends the standard fossology image with openssh-server so the
# fo_scheduler can dispatch agents to this pod over SSH (as user fossy).
FROM fossology/fossology:latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends openssh-server && \
    rm -rf /var/lib/apt/lists/* && \
    # Runtime directory for sshd
    mkdir -p /var/run/sshd && \
    # Harden: pubkey only, no password, relax StrictModes so K8s-mounted
    # authorized_keys (owned by root) are accepted
    echo 'PubkeyAuthentication yes'   >> /etc/ssh/sshd_config && \
    echo 'PasswordAuthentication no'  >> /etc/ssh/sshd_config && \
    echo 'StrictModes no'             >> /etc/ssh/sshd_config && \
    # Pre-generate host keys so each pod doesn't regenerate on every start
    ssh-keygen -A && \
    # Prepare fossy's .ssh dir (authorized_keys is volume-mounted at runtime)
    mkdir -p /home/fossy/.ssh && \
    chown fossy:fossy /home/fossy/.ssh && \
    chmod 700 /home/fossy/.ssh

# Db.conf and fossology.conf are volume-mounted at runtime via ConfigMap.
# sshd runs in the foreground; -e sends logs to stderr (visible via kubectl logs)
# Clear the base image's docker-entrypoint.sh — it tries to rewrite Db.conf
# (read-only in K8s ConfigMap mounts) and to start PostgreSQL locally.
# For the worker role we only need sshd; Db.conf is mounted via ConfigMap.
ENTRYPOINT []
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
