FROM docker:28-cli AS docker
FROM python:3.13-slim
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
WORKDIR /tool
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
ENTRYPOINT ["python", "/tool/selfhost.py"]
