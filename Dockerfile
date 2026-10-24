ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:8.0-alpine
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:8.0-alpine

FROM ${DOTNET_SDK_IMAGE} AS sdk-stage

FROM ${RUNTIME_IMAGE}
# CVE-2026-111497 (Node Brotli decoder RCE): require Node >= 24.22.1 and system Brotli >= 1.2.1, fail the build otherwise
RUN apk add --no-cache bash git curl jq "nodejs>=24.22.1-r0" "brotli-libs>=1.2.1-r0" npm \
 && node -e 'const p=s=>(s||"0.0.0").split(".").map(Number),[M,m,q]=p(process.versions.node),[a,b,c]=p(process.versions.brotli);if(M!==24||m<22||(m===22&&q<1)||a<1||(a===1&&(b<2||(b===2&&c<1)))){console.error("node "+process.versions.node+" brotli "+process.versions.brotli+" is below 24.22.1 / 1.2.1 (CVE-2026-111497)");process.exit(1)}' \
 && node --version
COPY --from=sdk-stage /usr/share/dotnet /usr/share/dotnet
ENV PATH="/usr/share/dotnet:${PATH}"
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
COPY scripts/loading-server.js scripts/loading-page.html scripts/error-page.html /runner/
WORKDIR /runner
COPY scripts/docker-entrypoint.sh ./
RUN chmod +x /runner/docker-entrypoint.sh
VOLUME /usercontent
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/runner/docker-entrypoint.sh"]
