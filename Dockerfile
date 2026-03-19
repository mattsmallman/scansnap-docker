FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    sane-utils \
    libsane1 \
    imagemagick \
    ghostscript \
    && rm -rf /var/lib/apt/lists/*

# Allow ImageMagick to process PDFs (disabled by default)
RUN sed -i 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' /etc/ImageMagick-6/policy.xml || true

COPY scan-loop.sh /usr/local/bin/scan-loop.sh
RUN chmod +x /usr/local/bin/scan-loop.sh

CMD ["/usr/local/bin/scan-loop.sh"]
