FROM julia:1.11-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends git build-essential zlib1g-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt
RUN git clone --recurse-submodules --depth 1 https://github.com/aryan-juliahub/Facil.jl
RUN julia --project=Facil.jl -e 'using Pkg; Pkg.instantiate()' && julia --project=Facil.jl Facil.jl/deps/build.jl
WORKDIR /srv/app
COPY Project.toml server.jl ./
RUN julia --project=. -e 'using Pkg; \
    Pkg.develop([PackageSpec(path="/opt/Facil.jl/lib/HttpTypes"), PackageSpec(path="/opt/Facil.jl")]); \
    Pkg.instantiate(); Pkg.precompile()'

FROM julia:1.11-bookworm
RUN useradd --system --create-home app
COPY --from=build /opt/Facil.jl /opt/Facil.jl
COPY --from=build /srv/app /srv/app
COPY --from=build /root/.julia /home/app/.julia
RUN chown -R app:app /home/app/.julia
USER app
WORKDIR /srv/app
ENV HOST=0.0.0.0 PORT=8080 JULIA_NUM_THREADS=4 JULIA_NUM_GC_THREADS=4
EXPOSE 8080
# The exec form makes julia PID 1, so `docker stop` delivers SIGTERM to it.
ENTRYPOINT ["julia", "--project=/srv/app", "/srv/app/server.jl"]
