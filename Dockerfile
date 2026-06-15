FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml README.md ./
COPY src ./src
RUN pip install --no-cache-dir .
ENV BUS_HOST=0.0.0.0 \
    BUS_PORT=8765 \
    BUS_DB=/data/bus.db
VOLUME /data
EXPOSE 8765
CMD ["claude-bus-http"]
