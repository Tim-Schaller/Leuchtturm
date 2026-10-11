FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/leuchtturmd ./cmd/leuchtturmd \
 && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/leuchtturmd /leuchtturmd
# Pre-create the data directory owned by the nonroot user (uid 65532).
COPY --from=build --chown=65532:65532 /out/data /data
ENV LEUCHTTURM_ADDR=:8080 LEUCHTTURM_DATA_DIR=/data
EXPOSE 8080
VOLUME ["/data"]
USER nonroot:nonroot
ENTRYPOINT ["/leuchtturmd"]
