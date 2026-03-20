# RunPod image: dlaub-togo shell + pixi

Docker image based on [`runpod/base:1.0.3-cuda1300-ubuntu2404`](https://hub.docker.com/r/runpod/base) with the same interactive bash setup as [d-laub/dlaub-togo](https://github.com/d-laub/dlaub-togo):

- [Oh My Bash](https://github.com/ohmybash/oh-my-bash) (`--unattended` for image builds)
- Custom **agnoster-multiline** theme from dlaub-togo
- [Pixi](https://pixi.sh) global tools: `ripgrep`, `bat`, `glow-md`, `sd`, `zoxide`, `rnr`, `fd-find`, `exa`, `prek`, `git`, `gh`
- Aliases from `aliases.sh` and `eval "$(zoxide init bash)"` in `~/.bashrc`

`PATH` includes `/root/.pixi/bin` for non-login sessions.

## Build locally

```bash
docker build -t your-registry/runpod-dlaub-togo:latest .
```

## CI (GitHub Actions)

On push to **`main`** or **`master`**, [`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml) builds and pushes to **GHCR** as `ghcr.io/<owner>/<repo>:latest` (plus branch and commit SHA tags). Pull requests run the same build without pushing.

The workflow uses the default `GITHUB_TOKEN` with `packages: write`. The first time, open the package under **GitHub → Packages → container → Package settings** and set **Change visibility** to **Public** if you want anonymous pulls.

## Use on RunPod

Push the image, then create a template/pod that references it. Mount volumes at `/workspace` if you use the default workdir.
