# ==========================================
# Stage 1: Builder (编译阶段)
# ==========================================
FROM alpine:3.19 AS builder
ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache wget tar

# 下载 Zig 编译器
RUN wget -qO- https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz \
    | tar xJ -C /usr/local --strip-components=1

WORKDIR /build
COPY . .

# 编译为 musl 静态二进制（零依赖，完美适配 Alpine）
RUN /usr/local/bin/zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl

# ==========================================
# Stage 2: Runtime (运行阶段)
# ==========================================
FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app
# 仅复制编译产物，不携带源码和构建缓存
COPY --from=builder /build/zig-out/bin/jwt-antpath-forwardauth .
COPY config.json .

# 安全加固：非 root 运行
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 9090
ENTRYPOINT ["./jwt-antpath-forwardauth"]