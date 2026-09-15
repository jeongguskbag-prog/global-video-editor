FROM python:3.10-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y ffmpeg git && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

# Render가 동적으로 부여하는 PORT 환경변수를 읽어서 실행
CMD sh -c "uvicorn app:app --host 0.0.0.0 --port ${PORT:-10000}"
