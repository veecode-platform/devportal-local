# DevPortal Local

`devportal-local` is the VeeCode-owned local runner for evaluating DevPortal 3.x. Clone it and start the published image with Docker Compose:

```bash
git clone https://github.com/veecode-platform/devportal-local.git
cd devportal-local
docker compose up
```

Open [http://localhost:7007](http://localhost:7007). To change the published UI port or the local PostgreSQL password, copy `.env.example` to `.env` before starting. PostgreSQL is part of the default stack because the marketplace installation state is stored there.

## Guest access warning

The default `config/app-config.veecode-auth.yaml` fragment enables guest sign-in and maps every guest to the `admin` user, with administrator ownership. This is useful for a fresh evaluation, but anyone who can reach the URL can act as an administrator; do not expose this setup to real users or untrusted networks. To turn guest-admin access off locally, remove the auth fragment bind mount and its matching `--config app-config.veecode-auth.yaml` argument from the `devportal` service in `docker-compose.yml`, then configure a real provider such as GitLab or GitHub OAuth.

## Marketplace walkthrough

1. Browse [http://localhost:7007/marketplace](http://localhost:7007/marketplace) after the catalog finishes loading.
2. Open a plugin and choose **Install**. Confirm the restart-required prompt.
3. Restart the backend with `docker compose restart devportal`.
4. The plugin remains available after the restart: the shared plugin volume keeps the installed files and PostgreSQL carries the marketplace selection. For a full cold-cycle check, run `docker compose down` without `-v`, then `docker compose up`; the pre-step rebuilds the installer YAML from PostgreSQL before the installer runs.

On a brand-new database, the first pre-step may warn that the marketplace schema does not exist yet. The initial backend boot creates it; later install-step runs use PostgreSQL normally.

## Kubernetes and staging documentation

For the Kubernetes deployment path, use [devportal-chart](https://github.com/veecode-platform/devportal-chart). The [staging preview installation guide](https://docs-next.platform.vee.codes/devportal/installation-guide/v3-preview/intro/) documents the broader DevPortal 3.x evaluation path.

## Acknowledgements

This repository is independent and VeeCode-owned; it is neither a fork nor a wrapper of [redhat-developer/rhdh-local](https://github.com/redhat-developer/rhdh-local). Its Compose shape and selected operational workarounds borrow solved design ideas from that project under its [Apache-2.0 license](https://github.com/redhat-developer/rhdh-local/blob/main/LICENSE), with attribution here.

## License

Apache-2.0. See [LICENSE](LICENSE).
