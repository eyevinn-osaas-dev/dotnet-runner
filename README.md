# dotnet-runner

A container runner for .NET applications on [Open Source Cloud (OSC)](https://www.osaas.io). It clones your repository, builds the .NET project, and runs it on port 8080, showing a loading page while the build is in progress.

## Supported .NET Versions

- .NET 8.0 LTS (default)

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `SOURCE_URL` | Yes | HTTPS URL to the Git repository (alias: `GITHUB_URL`). Append `#branch` to check out a specific branch. |
| `GIT_TOKEN` | No | Personal access token for private repositories (alias: `GITHUB_TOKEN`). |
| `PORT` | No | Port to listen on (default: `8080`). |
| `SUB_PATH` | No | Sub-directory within the repository to build. |
| `OSC_BUILD_CMD` | No | Override the default build command. Replaces the auto-detected `dotnet publish` invocation. |
| `OSC_ENTRY` | No | Override the entry DLL filename inside `/app/published/`. For example, `MyApp.dll`. Without this, the runner auto-detects the first `.dll` in the publish output. |
| `CONFIG_SVC` | No | Name of an OSC app-config-svc instance to load environment variables from. |
| `OSC_ACCESS_TOKEN` | No | OSC personal access token. Required when `CONFIG_SVC` is set. |
| `CONFIG_API_KEY` | No | API key for encrypted parameter store. When set alongside `OSC_ACCESS_TOKEN` and `CONFIG_SVC`, secret parameters are decrypted before being injected as environment variables. |

## Quick Start

```bash
docker run --rm \
  -e SOURCE_URL=https://github.com/your-org/your-dotnet-app \
  -e GIT_TOKEN=ghp_... \
  -p 8080:8080 \
  ghcr.io/eyevinn/dotnet-runner:latest
```

To use a specific branch:

```bash
docker run --rm \
  -e SOURCE_URL=https://github.com/your-org/your-dotnet-app#main \
  -e GIT_TOKEN=ghp_... \
  -p 8080:8080 \
  ghcr.io/eyevinn/dotnet-runner:latest
```

## Auto-Detection Strategy

The entrypoint auto-detects the project to build in this order:

1. A `*.sln` solution file (up to 2 directory levels deep)
2. A `*.csproj` project file (up to 3 directory levels deep)
3. Falls back to `dotnet publish .` in the repository root

The compiled output is placed in `/app/published/`. The runner then looks for the first `.dll` file in that directory as the entry point, excluding `.deps.dll` files.

## Using with OSC My Apps

You can deploy any public or private .NET application directly from OSC My Apps. Set:

- **Source URL**: the HTTPS clone URL of your repository (optionally with `#branch`)
- **GitHub Token**: your personal access token for private repositories

The runner will build and serve your application automatically.

## Build Status

While the application is building, a loading page is served on port 8080. If the build fails, an error page is served and `/healthz` returns HTTP 500 with `{"status":"build-failed"}`. During a successful build, `/healthz` returns HTTP 503 with body `Building`.

## License

MIT License. Copyright (c) 2024 Eyevinn Technology AB.
