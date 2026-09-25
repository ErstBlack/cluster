FROM ghcr.io/opentofu/opentofu:minimal AS tofu

FROM docker.io/rockylinux/rockylinux:10-minimal
RUN microdnf -y install openssh-clients && microdnf clean all
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu
ENTRYPOINT ["/usr/local/bin/tofu"]
