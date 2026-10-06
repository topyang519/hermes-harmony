FROM python:3.12-slim
WORKDIR /src
COPY bridge/pyproject.toml /src/
COPY bridge/src /src/src
RUN pip install --no-cache-dir .
USER 65532:65532
EXPOSE 8765
CMD ["hermes-harmony-relay", "--host", "0.0.0.0", "--port", "8765"]
