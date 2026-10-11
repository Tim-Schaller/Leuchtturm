FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tandemd ./cmd/tandemd

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/tandemd /tandemd
ENV TANDEM_ADDR=:8080 TANDEM_DATA_DIR=/data
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/tandemd"]
