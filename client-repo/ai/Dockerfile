FROM python:3.13-slim

WORKDIR /srv

# experiments/ 와 evals/ 는 배포 이미지에 넣지 않는다.
# 학습·평가용 무거운 의존성이 서비스 이미지를 오염시키지 않도록 하기 위함이다.
COPY pyproject.toml ./
COPY app ./app

RUN pip install --no-cache-dir .

EXPOSE 8100

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8100"]
